// Roamly offline — «почта».
// Телефоны хранят данные сами; сервер только держит зашифрованные записи поездок,
// пока получатель не в сети, и пересылает их. Прочитать записи сервер не может:
// поездка известна ему только по хешу, содержимое зашифровано ключом поездки из QR.
//
// WebSocket /ws (JSON):
//   → {k:"hello", dev, v}                     кто я
//   → {k:"sub", trips:{<hash>: <cursor>}}     на какие поездки подписан и что уже получил
//   ← {k:"ev", t:<hash>, e:[{s, b}]}          записи после cursor (s — номер на сервере, b — шифр)
//   → {k:"put", e:[{t, id, b}]}               новые записи с телефона
//   ← {k:"ack", ids:[...]}                    сохранено
//   → {k:"push", token}                       push-токен FCM этого телефона
// HTTP:
//   GET  /health
//   POST /call-token {t, room, id, name}  →  {url, token}   пропуск в звонок LiveKit
import { createServer } from 'node:http';
import { createHmac, createSign } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT || 8080);
const DATA = process.env.DATA_DIR || './data';
const LK_URL = process.env.LIVEKIT_URL || '';
const LK_KEY = process.env.LIVEKIT_API_KEY || '';
const LK_SECRET = process.env.LIVEKIT_API_SECRET || '';
const FCM_FILE = process.env.FCM_SERVICE_ACCOUNT || ''; // путь к JSON сервисного аккаунта Firebase
const MAX_BLOB = 64 * 1024;
const HASH_RE = /^[0-9a-f]{24}$/;

mkdirSync(DATA, { recursive: true });
const db = new DatabaseSync(`${DATA}/post.db`);
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS events (s INTEGER PRIMARY KEY AUTOINCREMENT, trip TEXT NOT NULL, id TEXT NOT NULL UNIQUE, b TEXT NOT NULL, ts INTEGER NOT NULL);
  CREATE INDEX IF NOT EXISTS events_trip ON events (trip, s);
  CREATE TABLE IF NOT EXISTS devices (dev TEXT PRIMARY KEY, token TEXT, seen INTEGER);
  CREATE TABLE IF NOT EXISTS device_trips (dev TEXT, trip TEXT, PRIMARY KEY (dev, trip));
`);
const q = {
  insert: db.prepare('INSERT OR IGNORE INTO events (trip, id, b, ts) VALUES (?, ?, ?, ?)'),
  after: db.prepare('SELECT s, b FROM events WHERE trip = ? AND s > ? ORDER BY s LIMIT 500'),
  seen: db.prepare('INSERT INTO devices (dev, seen) VALUES (?, ?) ON CONFLICT(dev) DO UPDATE SET seen = excluded.seen'),
  token: db.prepare('INSERT INTO devices (dev, token, seen) VALUES (?, ?, ?) ON CONFLICT(dev) DO UPDATE SET token = excluded.token, seen = excluded.seen'),
  subDel: db.prepare('DELETE FROM device_trips WHERE dev = ?'),
  subAdd: db.prepare('INSERT OR IGNORE INTO device_trips (dev, trip) VALUES (?, ?)'),
  tokensFor: db.prepare('SELECT d.dev, d.token FROM device_trips t JOIN devices d ON d.dev = t.dev WHERE t.trip = ? AND d.token IS NOT NULL'),
  dropToken: db.prepare('UPDATE devices SET token = NULL WHERE token = ?'),
};

/** Подключения по поездкам: hash → Set<ws>. */
const rooms = new Map();
const online = new Map(); // dev → ws

function send(ws, msg) {
  if (ws.readyState === 1) ws.send(JSON.stringify(msg));
}

function sendBacklog(ws, trip, cursor) {
  for (;;) {
    const rows = q.after.all(trip, cursor);
    if (rows.length === 0) return;
    send(ws, { k: 'ev', t: trip, e: rows });
    cursor = rows[rows.length - 1].s;
    if (rows.length < 500) return;
  }
}

function onMessage(ws, raw) {
  let m;
  try {
    m = JSON.parse(raw);
  } catch {
    return;
  }
  switch (m.k) {
    case 'hello': {
      if (typeof m.dev !== 'string' || m.dev.length > 64) return;
      ws.dev = m.dev;
      online.set(m.dev, ws);
      q.seen.run(m.dev, Date.now());
      return;
    }
    case 'sub': {
      const trips = m.trips && typeof m.trips === 'object' ? m.trips : {};
      for (const t of ws.trips) rooms.get(t)?.delete(ws);
      ws.trips = new Set();
      if (ws.dev) q.subDel.run(ws.dev);
      for (const [t, cur] of Object.entries(trips)) {
        if (!HASH_RE.test(t)) continue;
        ws.trips.add(t);
        if (!rooms.has(t)) rooms.set(t, new Set());
        rooms.get(t).add(ws);
        if (ws.dev) q.subAdd.run(ws.dev, t);
        sendBacklog(ws, t, Number(cur) || 0);
      }
      return;
    }
    case 'put': {
      const list = Array.isArray(m.e) ? m.e.slice(0, 500) : [];
      const ids = [];
      const fresh = new Map(); // trip → [{s,b}]
      const calls = new Set(); // поездки, где начался звонок
      for (const e of list) {
        if (!e || !HASH_RE.test(e.t) || typeof e.id !== 'string' || e.id.length > 64) continue;
        if (typeof e.b !== 'string' || e.b.length > MAX_BLOB) continue;
        const r = q.insert.run(e.t, e.id, e.b, Date.now());
        ids.push(e.id);
        if (r.changes > 0) {
          if (!fresh.has(e.t)) fresh.set(e.t, []);
          fresh.get(e.t).push({ s: Number(r.lastInsertRowid), b: e.b });
          if (e.n === 'call') calls.add(e.t);
        }
      }
      send(ws, { k: 'ack', ids });
      for (const [t, rows] of fresh) {
        for (const other of rooms.get(t) ?? []) if (other !== ws) send(other, { k: 'ev', t, e: rows });
        notifyOffline(t, ws.dev, calls.has(t));
      }
      return;
    }
    case 'push': {
      if (ws.dev && typeof m.token === 'string' && m.token.length < 4096) q.token.run(ws.dev, m.token, Date.now());
      return;
    }
  }
}

// ---------------- push (Firebase Cloud Messaging, HTTP v1) ----------------
// В push нет содержимого: только «есть новое в поездке <hash>» — телефон просыпается и забирает сам.

let fcm = null;
if (FCM_FILE) {
  try {
    fcm = JSON.parse(readFileSync(FCM_FILE, 'utf8'));
    console.log('push: FCM включён, проект', fcm.project_id);
  } catch (e) {
    console.log('push: не удалось прочитать', FCM_FILE, e.message);
  }
}
let fcmToken = { value: '', exp: 0 };
const b64u = (x) => Buffer.from(x).toString('base64url');

async function fcmAccessToken() {
  const now = Math.floor(Date.now() / 1000);
  if (fcmToken.value && fcmToken.exp > now + 60) return fcmToken.value;
  const head = b64u(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const body = b64u(JSON.stringify({
    iss: fcm.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));
  const sig = createSign('RSA-SHA256').update(`${head}.${body}`).sign(fcm.private_key, 'base64url');
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${body}.${sig}` }),
  });
  const j = await r.json();
  fcmToken = { value: j.access_token, exp: now + (j.expires_in || 3600) };
  return fcmToken.value;
}

const lastPush = new Map(); // dev → ms, не чаще раза в 20 с
async function notifyOffline(trip, fromDev, isCall = false) {
  if (!fcm) return;
  const rows = q.tokensFor.all(trip);
  for (const { dev, token } of rows) {
    if (dev === fromDev || online.has(dev)) continue;
    const now = Date.now();
    if (!isCall && now - (lastPush.get(dev) || 0) < 20000) continue;
    lastPush.set(dev, now);
    const message = {
      token,
      notification: isCall
        ? { title: 'Roamly offline: входящий звонок', body: 'Вам звонят из поездки — откройте приложение' }
        : { title: 'Roamly offline', body: 'Новое в поездке' },
      data: { t: trip, call: isCall ? '1' : '0' },
      android: { priority: 'high', collapse_key: trip, notification: { tag: isCall ? `call-${trip}` : trip } },
    };
    try {
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${fcm.project_id}/messages:send`, {
        method: 'POST',
        headers: { authorization: `Bearer ${await fcmAccessToken()}`, 'content-type': 'application/json' },
        body: JSON.stringify({ message }),
      });
      if (!r.ok) console.log('push:', r.status, (await r.text()).slice(0, 200));
      if (r.status === 404 || r.status === 400) q.dropToken.run(token);
    } catch (e) {
      console.log('push: ошибка', e.message);
    }
  }
}

// ---------------- звонки: пропуск в комнату LiveKit ----------------

function livekitToken({ room, id, name }) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64u(JSON.stringify({
    iss: LK_KEY,
    sub: id,
    name,
    nbf: now - 10,
    exp: now + 6 * 3600,
    video: { room, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: true },
  }));
  const sig = createHmac('sha256', LK_SECRET).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}

function readJson(req) {
  return new Promise((resolve) => {
    let s = '';
    req.on('data', (c) => {
      s += c;
      if (s.length > 4096) req.destroy();
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(s));
      } catch {
        resolve(null);
      }
    });
  });
}

const http = createServer(async (req, res) => {
  const json = (code, obj) => {
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'GET' && req.url === '/health') {
    return json(200, { ok: true, calls: Boolean(LK_KEY && LK_SECRET), push: Boolean(fcm), online: online.size });
  }
  if (req.method === 'POST' && req.url === '/call-token') {
    if (!LK_KEY || !LK_SECRET || !LK_URL) return json(503, { error: 'calls not configured' });
    const b = await readJson(req);
    if (!b || !HASH_RE.test(b.t) || typeof b.room !== 'string' || !/^[A-Za-z0-9-]{1,64}$/.test(b.room)) return json(400, { error: 'bad request' });
    if (typeof b.id !== 'string' || b.id.length > 64) return json(400, { error: 'bad id' });
    const name = typeof b.name === 'string' ? b.name.slice(0, 60) : '';
    // Комната всегда привязана к поездке: чужую комнату по хешу другой поездки не открыть.
    return json(200, { url: LK_URL, token: livekitToken({ room: `${b.t}-${b.room}`, id: b.id, name }) });
  }
  json(404, { error: 'not found' });
});

const wss = new WebSocketServer({ server: http, path: '/ws', maxPayload: 4 * 1024 * 1024 });
wss.on('connection', (ws) => {
  ws.trips = new Set();
  ws.alive = true;
  ws.on('pong', () => (ws.alive = true));
  ws.on('message', (raw) => onMessage(ws, raw.toString()));
  ws.on('close', () => {
    for (const t of ws.trips) rooms.get(t)?.delete(ws);
    if (ws.dev && online.get(ws.dev) === ws) online.delete(ws.dev);
  });
});
// Пинг раз в 30 с: мёртвые соединения (телефон уснул, сменил сеть) закрываются.
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.alive) {
      ws.terminate();
      continue;
    }
    ws.alive = false;
    ws.ping();
  }
}, 30000);

http.listen(PORT, () => console.log(`roamly-post слушает :${PORT}; звонки: ${LK_KEY ? 'да' : 'нет'}; push: ${fcm ? 'да' : 'нет'}`));
