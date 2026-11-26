// Локальное хранилище Roamly offline: всё лежит на телефоне (SQLite).
// Каждое изменение — запись в журнале (таблица events). Телефоны обмениваются записями,
// которых нет у другого (sync/nearby_sync.dart), и применяют их через Repo._apply.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

enum TripType { hike, car, yacht }

extension TripTypeX on TripType {
  String get label => switch (this) {
        TripType.hike => 'Пешком',
        TripType.car => 'На машинах',
        TripType.yacht => 'Яхта',
      };
}

class Trip {
  final String id;
  String name;
  TripType type;
  DateTime start;
  DateTime end;
  String currency;
  int childPercent;
  bool archived;
  String? meetingText;
  String? meetingTime;
  double? meetingLat;
  double? meetingLng;
  final DateTime created;

  /// 0 — поездка, 1 — личный чат на двоих.
  final int kind;
  bool get isDirect => kind == 1;

  Trip({
    required this.id,
    required this.name,
    required this.type,
    required this.start,
    required this.end,
    this.currency = 'EUR',
    this.childPercent = 50,
    this.archived = false,
    this.meetingText,
    this.meetingTime,
    this.meetingLat,
    this.meetingLng,
    required this.created,
    this.kind = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'type': type.index,
        'start_ms': start.millisecondsSinceEpoch,
        'end_ms': end.millisecondsSinceEpoch,
        'currency': currency,
        'child_percent': childPercent,
        'archived': archived ? 1 : 0,
        'meeting_text': meetingText,
        'meeting_time': meetingTime,
        'meeting_lat': meetingLat,
        'meeting_lng': meetingLng,
        'created': created.millisecondsSinceEpoch,
        'kind': kind,
      };

  static Trip fromMap(Map<String, Object?> m) => Trip(
        id: m['id'] as String,
        name: m['name'] as String,
        type: TripType.values[m['type'] as int],
        start: DateTime.fromMillisecondsSinceEpoch(m['start_ms'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(m['end_ms'] as int),
        currency: m['currency'] as String,
        childPercent: m['child_percent'] as int,
        archived: (m['archived'] as int) == 1,
        meetingText: m['meeting_text'] as String?,
        meetingTime: m['meeting_time'] as String?,
        meetingLat: (m['meeting_lat'] as num?)?.toDouble(),
        meetingLng: (m['meeting_lng'] as num?)?.toDouble(),
        created: DateTime.fromMillisecondsSinceEpoch(m['created'] as int),
        kind: (m['kind'] as int?) ?? 0,
      );

  /// active / upcoming / past
  String get phase {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (archived) return 'archive';
    if (end.isBefore(today)) return 'past';
    if (start.isAfter(today)) return 'upcoming';
    return 'active';
  }
}

class Wallet {
  final String id;
  final String tripId;
  String name;
  Wallet({required this.id, required this.tripId, required this.name});
  Map<String, Object?> toMap() => {'id': id, 'trip_id': tripId, 'name': name};
  static Wallet fromMap(Map<String, Object?> m) =>
      Wallet(id: m['id'] as String, tripId: m['trip_id'] as String, name: m['name'] as String);
}

class Member {
  final String id;
  final String tripId;
  String name;
  bool isChild;
  String walletId;
  bool isMe;

  /// Телефон участника (его ключ) и открытый ключ X25519 для личных сообщений — когда известны.
  String? device;
  String? pub;
  Member({
    required this.id,
    required this.tripId,
    required this.name,
    required this.isChild,
    required this.walletId,
    this.isMe = false,
    this.device,
    this.pub,
  });
  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'name': name,
        'is_child': isChild ? 1 : 0,
        'wallet_id': walletId,
        'is_me': isMe ? 1 : 0,
        'device': device,
        'pub': pub,
      };
  static Member fromMap(Map<String, Object?> m) => Member(
        id: m['id'] as String,
        tripId: m['trip_id'] as String,
        name: m['name'] as String,
        isChild: (m['is_child'] as int) == 1,
        walletId: m['wallet_id'] as String,
        isMe: (m['is_me'] as int) == 1,
        device: m['device'] as String?,
        pub: m['pub'] as String?,
      );
}

enum MsgKind { text, expense, meeting, system }

class Message {
  final String id;
  final String tripId;
  final String? authorId;
  final MsgKind kind;
  final String text;
  final String? refId;
  final DateTime created;

  /// 0 — «Чат» (общий), 1 — «Важное».
  final int channel;

  /// Ответ на сообщение (id) и время последней правки (0 — не правили).
  final String? replyTo;
  final int edited;
  Message({
    required this.id,
    required this.tripId,
    this.authorId,
    required this.kind,
    required this.text,
    this.refId,
    required this.created,
    this.channel = 0,
    this.replyTo,
    this.edited = 0,
  });
  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'author_id': authorId,
        'kind': kind.index,
        'text': text,
        'ref_id': refId,
        'created': created.millisecondsSinceEpoch,
        'channel': channel,
        if (replyTo != null) 'reply_to': replyTo,
      };
  static Message fromMap(Map<String, Object?> m) => Message(
        id: m['id'] as String,
        tripId: m['trip_id'] as String,
        authorId: m['author_id'] as String?,
        kind: MsgKind.values[m['kind'] as int],
        text: m['text'] as String,
        refId: m['ref_id'] as String?,
        created: DateTime.fromMillisecondsSinceEpoch(m['created'] as int),
        channel: (m['channel'] as int?) ?? 0,
        replyTo: m['reply_to'] as String?,
        edited: (m['edited'] as int?) ?? 0,
      );
}

/// Опрос в чате.
class Poll {
  final String id;
  final String tripId;
  final String? authorId;
  final String question;
  final List<String> options;
  final bool multi;
  final DateTime created;
  Poll(this.id, this.tripId, this.authorId, this.question, this.options, this.multi, this.created);
}

/// Отметка «получено / прочитано» от одного телефона в беседе.
class Receipt {
  final String device;
  final String? memberId;
  final int delivered;
  final int read;
  Receipt(this.device, this.memberId, this.delivered, this.read);
}

/// Человек, которому можно написать лично (известен по общим беседам).
class Contact {
  final String? device; // null — телефон этого человека ещё не известен
  final String name;
  final String? pub;
  final String? viaTripId; // беседа, через которую можно отправить приглашение в личный чат
  final String? viaMemberId;
  final String? directTripId; // уже есть личный чат
  Contact(this.device, this.name, this.pub, this.viaTripId, this.viaMemberId, this.directTripId);
}

enum SplitMode { rules, equal, manual }

class Expense {
  final String id;
  final String tripId;
  String title;
  String category;
  int amountCents; // в валюте оплаты
  String currency;
  double rate; // 1 единица валюты оплаты = rate валюты поездки
  int tripCents; // в валюте поездки
  String payerId;
  SplitMode mode;
  final DateTime created;
  Map<String, int> parts; // walletId -> доля в центах валюты поездки

  Expense({
    required this.id,
    required this.tripId,
    required this.title,
    required this.category,
    required this.amountCents,
    required this.currency,
    required this.rate,
    required this.tripCents,
    required this.payerId,
    required this.mode,
    required this.created,
    required this.parts,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'title': title,
        'category': category,
        'amount_cents': amountCents,
        'currency': currency,
        'rate': rate,
        'trip_cents': tripCents,
        'payer_id': payerId,
        'mode': mode.index,
        'created': created.millisecondsSinceEpoch,
      };

  static Expense fromMap(Map<String, Object?> m, Map<String, int> parts) => Expense(
        id: m['id'] as String,
        tripId: m['trip_id'] as String,
        title: m['title'] as String,
        category: m['category'] as String,
        amountCents: m['amount_cents'] as int,
        currency: m['currency'] as String,
        rate: (m['rate'] as num).toDouble(),
        tripCents: m['trip_cents'] as int,
        payerId: m['payer_id'] as String,
        mode: SplitMode.values[m['mode'] as int],
        created: DateTime.fromMillisecondsSinceEpoch(m['created'] as int),
        parts: parts,
      );
}

class Transfer {
  final String id;
  final String tripId;
  final String fromWallet;
  final String toWallet;
  final int cents;
  final DateTime created;
  Transfer({
    required this.id,
    required this.tripId,
    required this.fromWallet,
    required this.toWallet,
    required this.cents,
    required this.created,
  });
  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'from_wallet': fromWallet,
        'to_wallet': toWallet,
        'cents': cents,
        'created': created.millisecondsSinceEpoch,
      };
  static Transfer fromMap(Map<String, Object?> m) => Transfer(
        id: m['id'] as String,
        tripId: m['trip_id'] as String,
        fromWallet: m['from_wallet'] as String,
        toWallet: m['to_wallet'] as String,
        cents: m['cents'] as int,
        created: DateTime.fromMillisecondsSinceEpoch(m['created'] as int),
      );
}

class PlanItem {
  final String id;
  final String tripId;
  final DateTime day;
  final String time;
  final String title;
  bool done;
  PlanItem({
    required this.id,
    required this.tripId,
    required this.day,
    required this.time,
    required this.title,
    this.done = false,
  });
  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'day': day.millisecondsSinceEpoch,
        'time': time,
        'title': title,
        'done': done ? 1 : 0,
      };
  static PlanItem fromMap(Map<String, Object?> m) => PlanItem(
        id: m['id'] as String,
        tripId: m['trip_id'] as String,
        day: DateTime.fromMillisecondsSinceEpoch(m['day'] as int),
        time: m['time'] as String,
        title: m['title'] as String,
        done: (m['done'] as int) == 1,
      );
}

/// Всё о поездке разом — удобно для экранов.
class TripBundle {
  final Trip trip;
  final List<Wallet> wallets;
  final List<Member> members;
  TripBundle(this.trip, this.wallets, this.members);

  Member? get me => members.where((m) => m.isMe).firstOrNull;
  Member? member(String? id) => members.where((m) => m.id == id).firstOrNull;
  Wallet? wallet(String? id) => wallets.where((w) => w.id == id).firstOrNull;
  List<Member> membersOf(String walletId) => members.where((m) => m.walletId == walletId).toList();
  int get adults => members.where((m) => !m.isChild).length;
  int get children => members.where((m) => m.isChild).length;
}

// ---------- вложения (0.6) ----------

enum MediaKind { photo, video, note, voice, file }

/// Часть вложения: p — просмотр фото, o — оригинал фото, v — видео/кружок, a — голосовое, f — файл.
class MediaPart {
  final int size;
  final String hash; // sha256 содержимого
  const MediaPart(this.size, this.hash);
  Map<String, Object?> toJson() => {'s': size, 'h': hash};
  static MediaPart fromJson(Map m) => MediaPart((m['s'] as num).toInt(), m['h'] as String);
}

/// Вложение: фото, видео, кружок, голосовое или файл. Миниатюра едет в журнале,
/// сами части — отдельно (рядом по Wi‑Fi или через сервер), см. media/media_service.dart.
class Media {
  final String id;
  final String tripId;
  final String? authorId;
  final MediaKind kind;
  final DateTime created;
  final String? name;
  final String? mime;
  final int w;
  final int h;
  final int durMs;
  final String? thumb; // base64 JPEG, ~5–10 КБ
  final Map<String, MediaPart> parts;
  final int channel;
  final String? caption;

  Media({
    required this.id,
    required this.tripId,
    this.authorId,
    required this.kind,
    required this.created,
    this.name,
    this.mime,
    this.w = 0,
    this.h = 0,
    this.durMs = 0,
    this.thumb,
    required this.parts,
    this.channel = 0,
    this.caption,
  });

  /// Главная часть — то, что показываем/играем.
  String get main => switch (kind) {
        MediaKind.photo => 'p',
        MediaKind.video || MediaKind.note => 'v',
        MediaKind.voice => 'a',
        MediaKind.file => 'f',
      };

  int get mainSize => parts[main]?.size ?? 0;

  String get label => switch (kind) {
        MediaKind.photo => '📷 Фото',
        MediaKind.video => '🎬 Видео',
        MediaKind.note => '⏺ Видеосообщение',
        MediaKind.voice => '🎤 Голосовое',
        MediaKind.file => '📎 ${name ?? 'Файл'}',
      };

  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'author_id': authorId,
        'kind': kind.index,
        'created': created.millisecondsSinceEpoch,
        'name': name,
        'mime': mime,
        'w': w,
        'h': h,
        'dur': durMs,
        'thumb': thumb,
        'parts': jsonEncode({for (final e in parts.entries) e.key: e.value.toJson()}),
        'channel': channel,
        'caption': caption,
      };

  static Media fromMap(Map<String, Object?> m) {
    final raw = m['parts'];
    final pm = raw is String ? (jsonDecode(raw) as Map) : (raw as Map? ?? {});
    final k = (m['kind'] as num).toInt();
    return Media(
      id: m['id'] as String,
      tripId: m['trip_id'] as String,
      authorId: m['author_id'] as String?,
      kind: k < MediaKind.values.length ? MediaKind.values[k] : MediaKind.file,
      created: DateTime.fromMillisecondsSinceEpoch((m['created'] as num).toInt()),
      name: m['name'] as String?,
      mime: m['mime'] as String?,
      w: (m['w'] as num?)?.toInt() ?? 0,
      h: (m['h'] as num?)?.toInt() ?? 0,
      durMs: (m['dur'] as num?)?.toInt() ?? 0,
      thumb: m['thumb'] as String?,
      parts: {for (final e in pm.entries) e.key as String: MediaPart.fromJson(e.value as Map)},
      channel: (m['channel'] as num?)?.toInt() ?? 0,
      caption: m['caption'] as String?,
    );
  }
}

/// Запись журнала изменений. Неизменяема; правка — новая запись.
class SyncEvent {
  final String id;
  final String tripId;
  final String device; // кто создал
  final int seq; // порядковый номер у этого устройства
  final int ts; // время создания, мс
  final String type;
  final Map<String, dynamic> data;
  SyncEvent(this.id, this.tripId, this.device, this.seq, this.ts, this.type, this.data);

  Map<String, Object?> toRow() => {
        'id': id,
        'trip_id': tripId,
        'device': device,
        'seq': seq,
        'ts': ts,
        'type': type,
        'data': jsonEncode(data),
      };

  static SyncEvent fromRow(Map<String, Object?> r) => SyncEvent(
        r['id'] as String,
        r['trip_id'] as String,
        r['device'] as String,
        r['seq'] as int,
        r['ts'] as int,
        r['type'] as String,
        (jsonDecode(r['data'] as String) as Map).cast<String, dynamic>(),
      );

  // Компактный вид для передачи между телефонами.
  Map<String, Object?> toWire() => {'i': id, 't': tripId, 'd': device, 's': seq, 'ts': ts, 'y': type, 'x': data};
  static SyncEvent fromWire(Map<String, dynamic> m) => SyncEvent(
        m['i'] as String,
        m['t'] as String,
        m['d'] as String,
        m['s'] as int,
        m['ts'] as int,
        m['y'] as String,
        (m['x'] as Map).cast<String, dynamic>(),
      );
}

class Repo extends ChangeNotifier {
  Repo._(this._db, this.deviceId, this._seq);
  final Database _db;

  /// Ключ этого телефона (пока случайный id; позже — пара ключей для подписи).
  final String deviceId;
  int _seq;

  /// Подписчики на новые записи, созданные на этом телефоне (рассылка соседям, сервер).
  final localEventListeners = <void Function(List<SyncEvent> events)>[];

  /// Подписчики на записи, пришедшие с других телефонов (входящие звонки и т.п.).
  final ingestListeners = <void Function(List<SyncEvent> events)>[];

  static Future<Repo> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'roamly.db'),
      version: 7,
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute('ALTER TABLE trips ADD COLUMN meeting_lat REAL');
          await db.execute('ALTER TABLE trips ADD COLUMN meeting_lng REAL');
        }
        if (from < 3) {
          await db.execute('ALTER TABLE trips ADD COLUMN meeting_ts INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE plan_items ADD COLUMN done_ts INTEGER DEFAULT 0');
          await _createSyncTables(db);
          await _backfill(db);
        } else if (from < 4) {
          await db.execute('ALTER TABLE events ADD COLUMN sent INTEGER DEFAULT 0');
        }
        if (from < 5) {
          await db.execute('ALTER TABLE trips ADD COLUMN kind INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE members ADD COLUMN device TEXT');
          await db.execute('ALTER TABLE members ADD COLUMN pub TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN channel INTEGER DEFAULT 0');
          await db.execute('UPDATE messages SET channel = 1 WHERE kind = ${MsgKind.meeting.index}');
          await _createV5Tables(db);
        }
        if (from < 6) await _createV6Tables(db);
        if (from < 7) {
          await db.execute('ALTER TABLE messages ADD COLUMN reply_to TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN edited INTEGER DEFAULT 0');
          await _createV7Tables(db);
        }
      },
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('''CREATE TABLE trips (id TEXT PRIMARY KEY, name TEXT, type INTEGER,
          start_ms INTEGER, end_ms INTEGER, currency TEXT, child_percent INTEGER, archived INTEGER,
          meeting_text TEXT, meeting_time TEXT, created INTEGER, meeting_lat REAL, meeting_lng REAL,
          meeting_ts INTEGER DEFAULT 0, kind INTEGER DEFAULT 0)''');
        await db.execute('CREATE TABLE wallets (id TEXT PRIMARY KEY, trip_id TEXT, name TEXT)');
        await db.execute('''CREATE TABLE members (id TEXT PRIMARY KEY, trip_id TEXT, name TEXT,
          is_child INTEGER, wallet_id TEXT, is_me INTEGER, device TEXT, pub TEXT)''');
        await db.execute('''CREATE TABLE messages (id TEXT PRIMARY KEY, trip_id TEXT, author_id TEXT,
          kind INTEGER, text TEXT, ref_id TEXT, created INTEGER, channel INTEGER DEFAULT 0,
          reply_to TEXT, edited INTEGER DEFAULT 0)''');
        await db.execute('''CREATE TABLE expenses (id TEXT PRIMARY KEY, trip_id TEXT, title TEXT,
          category TEXT, amount_cents INTEGER, currency TEXT, rate REAL, trip_cents INTEGER,
          payer_id TEXT, mode INTEGER, created INTEGER)''');
        await db.execute('CREATE TABLE expense_parts (expense_id TEXT, wallet_id TEXT, cents INTEGER)');
        await db.execute('''CREATE TABLE transfers (id TEXT PRIMARY KEY, trip_id TEXT, from_wallet TEXT,
          to_wallet TEXT, cents INTEGER, created INTEGER)''');
        await db.execute('''CREATE TABLE plan_items (id TEXT PRIMARY KEY, trip_id TEXT, day INTEGER,
          time TEXT, title TEXT, done INTEGER, done_ts INTEGER DEFAULT 0)''');
        await _createSyncTables(db);
        await _createV5Tables(db);
        await _createV6Tables(db);
        await _createV7Tables(db);
      },
    );
    var dev = (await db.query('kv', where: 'k = ?', whereArgs: ['device_id'])).firstOrNull?['v'] as String?;
    if (dev == null) {
      dev = newId();
      await db.insert('kv', {'k': 'device_id', 'v': dev}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final r = await db.rawQuery('SELECT MAX(seq) AS m FROM events WHERE device = ?', [dev]);
    return Repo._(db, dev, (r.first['m'] as int?) ?? 0);
  }

  static Future<void> _createSyncTables(Database db) async {
    // sent = 1 — запись уже есть на сервере-«почте».
    await db.execute('''CREATE TABLE events (id TEXT PRIMARY KEY, trip_id TEXT, device TEXT,
      seq INTEGER, ts INTEGER, type TEXT, data TEXT, sent INTEGER DEFAULT 0)''');
    await db.execute('CREATE INDEX events_trip ON events (trip_id, device, seq)');
    // Удалённые объекты: чтобы запоздавшая запись «добавить» не вернула их обратно.
    await db.execute('CREATE TABLE deleted (id TEXT PRIMARY KEY, trip_id TEXT)');
  }

  static Future<void> _createV7Tables(Database db) async {
    await db.execute('''CREATE TABLE reactions (msg_id TEXT, trip_id TEXT, member_id TEXT, emoji TEXT, ts INTEGER,
      PRIMARY KEY (msg_id, member_id))''');
    await db.execute('''CREATE TABLE polls (id TEXT PRIMARY KEY, trip_id TEXT, author_id TEXT, question TEXT,
      options TEXT, multi INTEGER, created INTEGER)''');
    await db.execute('''CREATE TABLE votes (poll_id TEXT, trip_id TEXT, member_id TEXT, choices TEXT, ts INTEGER,
      PRIMARY KEY (poll_id, member_id))''');
  }

  static Future<void> _createV6Tables(Database db) async {
    await db.execute('''CREATE TABLE media (id TEXT PRIMARY KEY, trip_id TEXT, author_id TEXT, kind INTEGER,
      created INTEGER, name TEXT, mime TEXT, w INTEGER, h INTEGER, dur INTEGER, thumb TEXT, parts TEXT,
      channel INTEGER DEFAULT 0, caption TEXT)''');
    // Части вложений, которые есть на этом телефоне; up = 1 — уже на сервере (или не нужно загружать).
    await db.execute('''CREATE TABLE media_files (media_id TEXT, part TEXT, path TEXT, up INTEGER DEFAULT 1,
      PRIMARY KEY (media_id, part))''');
  }

  static Future<void> _createV5Tables(Database db) async {
    await db.execute('''CREATE TABLE receipts (trip_id TEXT, device TEXT, member_id TEXT,
      delivered INTEGER DEFAULT 0, read INTEGER DEFAULT 0, PRIMARY KEY (trip_id, device))''');
  }

  /// Переход с 0.1.x: уже накопленные данные превращаются в записи журнала,
  /// чтобы ими тоже обменяться с остальными телефонами.
  static Future<void> _backfill(Database db) async {
    final dev = newId();
    await db.insert('kv', {'k': 'device_id', 'v': dev}, conflictAlgorithm: ConflictAlgorithm.replace);
    var seq = 0;
    Future<void> add(String tripId, int ts, String type, Map<String, dynamic> data) async {
      seq++;
      await db.insert('events', SyncEvent(newId(), tripId, dev, seq, ts, type, data).toRow());
    }

    for (final m in await db.query('messages', orderBy: 'created ASC')) {
      if (m['kind'] == MsgKind.expense.index) continue; // появятся из записей о тратах
      await add(m['trip_id'] as String, m['created'] as int, 'msg', Map<String, dynamic>.from(m));
    }
    for (final e in await db.query('expenses')) {
      final parts = await db.query('expense_parts', where: 'expense_id = ?', whereArgs: [e['id']]);
      await add(e['trip_id'] as String, e['created'] as int, 'expense', {
        'e': Map<String, dynamic>.from(e),
        'p': {for (final r in parts) r['wallet_id'] as String: r['cents'] as int},
      });
    }
    for (final t in await db.query('transfers')) {
      // текст перевода уже есть в чате как системное сообщение
      await add(t['trip_id'] as String, t['created'] as int, 'transfer', {'t': Map<String, dynamic>.from(t)});
    }
    for (final i in await db.query('plan_items')) {
      final m = Map<String, dynamic>.from(i)..remove('done_ts');
      await add(i['trip_id'] as String, i['day'] as int, 'plan', {'i': m});
    }
  }

  // ---------- журнал ----------

  /// Создаёт запись на этом телефоне и применяет её.
  Future<SyncEvent> _emit(DatabaseExecutor tx, String tripId, String type, Map<String, dynamic> data) async {
    _seq++;
    final e = SyncEvent(newId(), tripId, deviceId, _seq, DateTime.now().millisecondsSinceEpoch, type, data);
    await tx.insert('events', e.toRow());
    await _apply(tx, e);
    return e;
  }

  void _published(List<SyncEvent> list) {
    notifyListeners();
    for (final l in List.of(localEventListeners)) {
      l(list);
    }
  }

  /// Записи, пришедшие с другого телефона. Возвращает те, которых здесь ещё не было.
  Future<List<SyncEvent>> ingest(List<SyncEvent> events, {bool fromServer = false}) async {
    final fresh = <SyncEvent>[];
    final known = (await tripIds()).toSet();
    await _db.transaction((tx) async {
      for (final e in events) {
        if (!known.contains(e.tripId)) continue;
        final row = e.toRow();
        if (fromServer) row['sent'] = 1;
        final n = await tx.insert('events', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (n == 0) {
          if (fromServer) await tx.update('events', {'sent': 1}, where: 'id = ?', whereArgs: [e.id]);
          continue; // уже есть
        }
        try {
          await _apply(tx, e);
        } catch (err) {
          debugPrint('sync: не удалось применить ${e.type}: $err');
        }
        fresh.add(e);
      }
    });
    if (fresh.isNotEmpty) {
      notifyListeners();
      for (final l in List.of(ingestListeners)) {
        l(fresh);
      }
    }
    return fresh;
  }

  /// Записи, которых ещё нет на сервере (свои и полученные от соседей рядом).
  Future<List<SyncEvent>> unsent({int limit = 200}) async {
    final r = await _db.query('events', where: 'sent = 0 OR sent IS NULL', orderBy: 'ts ASC', limit: limit);
    return r.map(SyncEvent.fromRow).toList();
  }

  Future<void> markSent(List<String> ids) async {
    if (ids.isEmpty) return;
    final batch = _db.batch();
    for (final id in ids) {
      batch.update('events', {'sent': 1}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Создать запись «звонок» (видна всем участникам; по ней присоединяются к комнате).
  Future<SyncEvent> startCall(String tripId, {required String room, required String? memberId, required String name, required bool video}) async {
    final evs = <SyncEvent>[];
    await _db.transaction((tx) async => evs.add(await _emit(tx, tripId, 'call', {'room': room, 'by': memberId, 'name': name, 'video': video})));
    _published(evs);
    return evs.first;
  }

  /// Сколько записей от каждого телефона уже есть по поездке: {device: maxSeq}.
  Future<Map<String, int>> vector(String tripId) async {
    final r = await _db.rawQuery(
        'SELECT device, MAX(seq) AS m FROM events WHERE trip_id = ? GROUP BY device', [tripId]);
    return {for (final row in r) row['device'] as String: row['m'] as int};
  }

  /// Записи поездки, которых нет у соседа с вектором [have].
  Future<List<SyncEvent>> missingFor(String tripId, Map<String, int> have) async {
    final r = await _db.query('events', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'ts ASC');
    return [
      for (final row in r)
        if ((row['seq'] as int) > (have[row['device']] ?? 0)) SyncEvent.fromRow(row),
    ];
  }

  Future<List<String>> tripIds() async =>
      [for (final t in await _db.query('trips', columns: ['id'])) t['id'] as String];

  Future<bool> _isDeleted(DatabaseExecutor tx, String id) async =>
      (await tx.query('deleted', where: 'id = ?', whereArgs: [id])).isNotEmpty;

  static Map<String, Object?> _cols(Map<String, dynamic> m, List<String> keep) => {
        for (final k in keep)
          if (m.containsKey(k)) k: m[k],
      };

  /// Применение записи к таблицам. Результат одинаков при любом порядке и повторах.
  Future<void> _apply(DatabaseExecutor tx, SyncEvent e) async {
    final d = e.data;
    const ignore = ConflictAlgorithm.ignore;
    switch (e.type) {
      case 'msg':
        final m = _cols(d, ['id', 'trip_id', 'author_id', 'kind', 'text', 'ref_id', 'created', 'channel', 'reply_to']);
        if (!await _isDeleted(tx, m['id'] as String)) await tx.insert('messages', m, conflictAlgorithm: ignore);
        // Кто пишет текст, тот и владелец телефона: так узнаём телефон участника даже без «ident».
        if (d['author_id'] != null && d['kind'] == MsgKind.text.index) {
          await tx.rawUpdate('UPDATE members SET device = ? WHERE id = ? AND trip_id = ? AND device IS NULL',
              [e.device, d['author_id'], e.tripId]);
        }
      case 'wallet':
        await tx.insert('wallets', _cols(d, ['id', 'trip_id', 'name']), conflictAlgorithm: ignore);
      case 'member':
        final m = _cols(d, ['id', 'trip_id', 'name', 'is_child', 'wallet_id', 'device', 'pub'])..['is_me'] = 0;
        await tx.insert('members', m, conflictAlgorithm: ignore);
      case 'ident':
        // какой телефон (и ключ) у участника
        await tx.update('members', {'device': d['device'], 'pub': d['pub']},
            where: 'id = ? AND trip_id = ?', whereArgs: [d['member'], e.tripId]);
      case 'rcpt':
        await tx.insert('receipts', {'trip_id': e.tripId, 'device': e.device, 'member_id': d['member']},
            conflictAlgorithm: ignore);
        await tx.rawUpdate(
          'UPDATE receipts SET member_id = ?, delivered = MAX(delivered, ?), read = MAX(read, ?) WHERE trip_id = ? AND device = ?',
          [d['member'], (d['d'] as num?)?.toInt() ?? 0, (d['r'] as num?)?.toInt() ?? 0, e.tripId, e.device],
        );
      case 'dm':
        break; // приглашение в личный чат открывает DirectService (нужен закрытый ключ)
      case 'meeting':
        // побеждает самая поздняя точка сбора
        await tx.update(
          'trips',
          {
            'meeting_text': d['text'],
            'meeting_time': d['time'],
            'meeting_lat': d['lat'],
            'meeting_lng': d['lng'],
            'meeting_ts': e.ts,
          },
          where: 'id = ? AND (meeting_ts IS NULL OR meeting_ts < ?)',
          whereArgs: [e.tripId, e.ts],
        );
        await tx.insert(
          'messages',
          Message(
            id: 'm-${e.id}',
            tripId: e.tripId,
            authorId: d['author'] as String?,
            kind: MsgKind.meeting,
            text: '${d['text']} · ${d['time']}${d['lat'] != null ? ' · на карте' : ''}',
            created: DateTime.fromMillisecondsSinceEpoch(e.ts),
            channel: 1,
          ).toMap(),
          conflictAlgorithm: ignore,
        );
      case 'expense':
        final ex = _cols((d['e'] as Map).cast<String, dynamic>(), [
          'id', 'trip_id', 'title', 'category', 'amount_cents', 'currency', //
          'rate', 'trip_cents', 'payer_id', 'mode', 'created',
        ]);
        final id = ex['id'] as String;
        if (await _isDeleted(tx, id)) return;
        final n = await tx.insert('expenses', ex, conflictAlgorithm: ignore);
        if (n == 0) return;
        for (final entry in (d['p'] as Map).entries) {
          await tx.insert('expense_parts', {'expense_id': id, 'wallet_id': entry.key, 'cents': entry.value});
        }
        await tx.insert(
          'messages',
          Message(
            id: 'm-$id',
            tripId: e.tripId,
            authorId: ex['payer_id'] as String?,
            kind: MsgKind.expense,
            text: ex['title'] as String,
            refId: id,
            created: DateTime.fromMillisecondsSinceEpoch(ex['created'] as int),
          ).toMap(),
          conflictAlgorithm: ignore,
        );
      case 'expense.del':
        final id = d['id'] as String;
        await tx.insert('deleted', {'id': id, 'trip_id': e.tripId}, conflictAlgorithm: ignore);
        await tx.delete('expense_parts', where: 'expense_id = ?', whereArgs: [id]);
        await tx.delete('expenses', where: 'id = ?', whereArgs: [id]);
        await tx.delete('messages', where: 'ref_id = ?', whereArgs: [id]);
      case 'transfer':
        final t = _cols((d['t'] as Map).cast<String, dynamic>(),
            ['id', 'trip_id', 'from_wallet', 'to_wallet', 'cents', 'created']);
        final n = await tx.insert('transfers', t, conflictAlgorithm: ignore);
        final text = d['text'] as String?;
        if (n > 0 && text != null) {
          await tx.insert(
            'messages',
            Message(
              id: 'm-${t['id']}',
              tripId: e.tripId,
              kind: MsgKind.system,
              text: text,
              created: DateTime.fromMillisecondsSinceEpoch(t['created'] as int),
            ).toMap(),
            conflictAlgorithm: ignore,
          );
        }
      case 'plan':
        final i = _cols((d['i'] as Map).cast<String, dynamic>(), ['id', 'trip_id', 'day', 'time', 'title', 'done']);
        if (!await _isDeleted(tx, i['id'] as String)) {
          await tx.insert('plan_items', {...i, 'done_ts': 0}, conflictAlgorithm: ignore);
        }
      case 'plan.done':
        // побеждает последняя отметка
        await tx.update('plan_items', {'done': d['done'] == true ? 1 : 0, 'done_ts': e.ts},
            where: 'id = ? AND (done_ts IS NULL OR done_ts < ?)', whereArgs: [d['id'], e.ts]);
      case 'call':
        await tx.insert(
          'messages',
          Message(
            id: 'm-${e.id}',
            tripId: e.tripId,
            authorId: d['by'] as String?,
            kind: MsgKind.system,
            text: '📞 ${d['name'] ?? ''} ${d['video'] == true ? 'начал(а) видеозвонок' : 'начал(а) звонок'} · нажмите, чтобы присоединиться',
            refId: 'call:${d['room']}:${d['video'] == true ? 1 : 0}',
            created: DateTime.fromMillisecondsSinceEpoch(e.ts),
          ).toMap(),
          conflictAlgorithm: ignore,
        );
      case 'plan.del':
        await tx.insert('deleted', {'id': d['id'], 'trip_id': e.tripId}, conflictAlgorithm: ignore);
        await tx.delete('plan_items', where: 'id = ?', whereArgs: [d['id']]);
      case 'media':
        final m = Media.fromMap({...d, 'trip_id': e.tripId});
        if (await _isDeleted(tx, m.id)) return;
        final n = await tx.insert('media', m.toMap(), conflictAlgorithm: ignore);
        if (n == 0) return;
        await tx.insert(
          'messages',
          Message(
            id: 'm-${m.id}',
            tripId: e.tripId,
            authorId: m.authorId,
            kind: MsgKind.text,
            text: m.caption == null || m.caption!.isEmpty ? m.label : '${m.label} · ${m.caption}',
            refId: 'media:${m.id}',
            created: m.created,
            channel: m.channel,
          ).toMap(),
          conflictAlgorithm: ignore,
        );
      case 'msg.edit':
        // правит только автор; побеждает последняя правка
        await tx.update('messages', {'text': d['text'], 'edited': e.ts},
            where: 'id = ? AND author_id = ? AND (edited IS NULL OR edited < ?)', whereArgs: [d['id'], d['author'], e.ts]);
      case 'msg.del':
        final id = d['id'] as String;
        final own = await tx.query('messages', columns: ['author_id'], where: 'id = ?', whereArgs: [id]);
        if (own.isNotEmpty && own.first['author_id'] != d['author']) return;
        await tx.insert('deleted', {'id': id, 'trip_id': e.tripId}, conflictAlgorithm: ignore);
        await tx.delete('messages', where: 'id = ?', whereArgs: [id]);
        await tx.delete('reactions', where: 'msg_id = ?', whereArgs: [id]);
      case 'react':
        final emoji = (d['e'] as String?) ?? '';
        final old = await tx.query('reactions', columns: ['ts'], where: 'msg_id = ? AND member_id = ?', whereArgs: [d['msg'], d['member']]);
        if (old.isNotEmpty && ((old.first['ts'] as int?) ?? 0) > e.ts) return;
        if (emoji.isEmpty) {
          await tx.delete('reactions', where: 'msg_id = ? AND member_id = ?', whereArgs: [d['msg'], d['member']]);
        } else {
          await tx.insert('reactions', {'msg_id': d['msg'], 'trip_id': e.tripId, 'member_id': d['member'], 'emoji': emoji, 'ts': e.ts},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      case 'poll':
        final id = d['id'] as String;
        if (await _isDeleted(tx, id)) return;
        final n = await tx.insert(
            'polls',
            {
              'id': id,
              'trip_id': e.tripId,
              'author_id': d['author'],
              'question': d['q'],
              'options': jsonEncode(d['o']),
              'multi': d['multi'] == true ? 1 : 0,
              'created': (d['created'] as num?)?.toInt() ?? e.ts,
            },
            conflictAlgorithm: ignore);
        if (n == 0) return;
        await tx.insert(
          'messages',
          Message(
            id: 'm-$id',
            tripId: e.tripId,
            authorId: d['author'] as String?,
            kind: MsgKind.text,
            text: '📊 ${d['q']}',
            refId: 'poll:$id',
            created: DateTime.fromMillisecondsSinceEpoch((d['created'] as num?)?.toInt() ?? e.ts),
            channel: (d['channel'] as num?)?.toInt() ?? 0,
          ).toMap(),
          conflictAlgorithm: ignore,
        );
      case 'vote':
        final old = await tx.query('votes', columns: ['ts'], where: 'poll_id = ? AND member_id = ?', whereArgs: [d['poll'], d['member']]);
        if (old.isNotEmpty && ((old.first['ts'] as int?) ?? 0) > e.ts) return;
        await tx.insert('votes', {'poll_id': d['poll'], 'trip_id': e.tripId, 'member_id': d['member'], 'choices': jsonEncode(d['c'] ?? []), 'ts': e.ts},
            conflictAlgorithm: ConflictAlgorithm.replace);
      case 'media.del':
        final id = d['id'] as String;
        await tx.insert('deleted', {'id': id, 'trip_id': e.tripId}, conflictAlgorithm: ignore);
        for (final f in await tx.query('media_files', where: 'media_id = ?', whereArgs: [id])) {
          try {
            File(f['path'] as String).deleteSync();
          } catch (_) {}
        }
        await tx.delete('media_files', where: 'media_id = ?', whereArgs: [id]);
        await tx.delete('media', where: 'id = ?', whereArgs: [id]);
        await tx.delete('messages', where: 'ref_id = ?', whereArgs: ['media:$id']);
      default:
        debugPrint('sync: неизвестный тип записи ${e.type} — пропускаем (новая версия у соседа)');
    }
  }

  // ---------- личное: ключи, отметки, контакты ----------

  /// Записать в беседу событие от своего имени (служебные: ident, rcpt, dm).
  Future<SyncEvent> emitEvent(String tripId, String type, Map<String, dynamic> data) async {
    final evs = <SyncEvent>[];
    await _db.transaction((tx) async => evs.add(await _emit(tx, tripId, type, data)));
    _published(evs);
    return evs.first;
  }

  Future<List<Receipt>> receipts(String tripId) async {
    final r = await _db.query('receipts', where: 'trip_id = ?', whereArgs: [tripId]);
    return [
      for (final x in r)
        Receipt(x['device'] as String, x['member_id'] as String?, (x['delivered'] as int?) ?? 0, (x['read'] as int?) ?? 0),
    ];
  }

  /// Время самой старой своей записи в беседе, которая ещё никуда не ушла (null — всё ушло).
  Future<int?> oldestUnsent(String tripId) async {
    final r = await _db.rawQuery(
        'SELECT MIN(ts) AS m FROM events WHERE trip_id = ? AND device = ? AND (sent = 0 OR sent IS NULL)', [tripId, deviceId]);
    return r.first['m'] as int?;
  }

  /// Время последнего чужого сообщения в канале (для «прочитано» и счётчика «Важного»).
  Future<int> lastForeignMessage(String tripId, {int? channel}) async {
    final me = (await _db.query('members', columns: ['id'], where: 'trip_id = ? AND is_me = 1', whereArgs: [tripId]))
        .firstOrNull?['id'] as String?;
    final r = await _db.rawQuery(
      'SELECT MAX(created) AS m FROM messages WHERE trip_id = ? AND kind != ${MsgKind.system.index} '
      'AND (author_id IS NULL OR author_id != ?)${channel == null ? '' : ' AND channel = $channel'}',
      [tripId, me ?? ''],
    );
    return (r.first['m'] as int?) ?? 0;
  }

  /// Сколько непрочитанных «Важных» от других.
  Future<int> unreadImportant(String tripId) async {
    final seen = int.tryParse(await getSetting('seen_imp:$tripId') ?? '') ?? 0;
    final me = (await _db.query('members', columns: ['id'], where: 'trip_id = ? AND is_me = 1', whereArgs: [tripId]))
        .firstOrNull?['id'] as String?;
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM messages WHERE trip_id = ? AND channel = 1 AND created > ? '
      'AND (author_id IS NULL OR author_id != ?)',
      [tripId, seen, me ?? ''],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> markImportantSeen(String tripId) async {
    final last = await lastForeignMessage(tripId, channel: 1);
    final seen = int.tryParse(await getSetting('seen_imp:$tripId') ?? '') ?? 0;
    if (last <= seen) return; // нечего отмечать — без лишних обновлений экрана
    await setSetting('seen_imp:$tripId', '$last');
    notifyListeners();
  }

  /// Все люди из общих бесед. Написать лично можно тем, чей телефон и ключ уже известны.
  Future<List<Contact>> contacts() async {
    final rows = await _db.rawQuery('''
      SELECT m.device, m.name, m.pub, m.id AS member_id, m.trip_id, t.kind
      FROM members m JOIN trips t ON t.id = m.trip_id
      WHERE m.is_me = 0 AND (m.device IS NULL OR m.device != ?)
      ORDER BY t.kind DESC, (m.pub IS NULL), t.created DESC''', [deviceId]);
    final byKey = <String, Contact>{};
    for (final r in rows) {
      final dev = r['device'] as String?;
      final name = r['name'] as String;
      final key = dev ?? 'name:${name.trim().toLowerCase()}';
      final old = byKey[key];
      final isDirect = r['kind'] == 1;
      byKey[key] = Contact(
        dev,
        old?.name ?? name,
        old?.pub ?? r['pub'] as String?,
        old?.viaTripId ?? (isDirect ? null : r['trip_id'] as String),
        old?.viaMemberId ?? (isDirect ? null : r['member_id'] as String),
        old?.directTripId ?? (isDirect ? r['trip_id'] as String : null),
      );
    }
    // Тот же человек без известного телефона — не показывать дважды.
    final named = {for (final c in byKey.values) if (c.device != null) c.name.trim().toLowerCase()};
    byKey.removeWhere((k, c) => c.device == null && named.contains(c.name.trim().toLowerCase()));
    return byKey.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Для записей, пришедших до 0.5.1: узнать телефоны участников по их сообщениям.
  Future<void> learnDevices() async {
    final r = await _db.query('events', columns: ['trip_id', 'device', 'data'], where: "type = 'msg'");
    final batch = _db.batch();
    for (final row in r) {
      try {
        final d = jsonDecode(row['data'] as String) as Map;
        if (d['author_id'] == null || d['kind'] != MsgKind.text.index) continue;
        batch.rawUpdate('UPDATE members SET device = ? WHERE id = ? AND trip_id = ? AND device IS NULL',
            [row['device'], d['author_id'], row['trip_id']]);
      } catch (_) {}
    }
    await batch.commit(noResult: true);
  }

  /// Личный чат с этим телефоном, если уже есть.
  Future<String?> directWith(String device) async {
    final r = await _db.rawQuery(
        'SELECT t.id FROM trips t JOIN members m ON m.trip_id = t.id WHERE t.kind = 1 AND m.device = ? LIMIT 1', [device]);
    return r.firstOrNull?['id'] as String?;
  }

  // ---------- настройки ----------
  Future<String?> getSetting(String k) async {
    final r = await _db.query('kv', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  Future<void> setSetting(String k, String v) async {
    await _db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------- поездки ----------
  Future<List<Trip>> trips() async {
    final r = await _db.query('trips', orderBy: 'start_ms ASC');
    return r.map(Trip.fromMap).toList();
  }

  Future<TripBundle> bundle(String tripId) async {
    final t = await _db.query('trips', where: 'id = ?', whereArgs: [tripId]);
    final w = await _db.query('wallets', where: 'trip_id = ?', whereArgs: [tripId]);
    final m = await _db.query('members', where: 'trip_id = ?', whereArgs: [tripId]);
    return TripBundle(
      Trip.fromMap(t.first),
      w.map(Wallet.fromMap).toList(),
      m.map(Member.fromMap).toList(),
    );
  }

  Future<void> createTrip(Trip trip, List<Wallet> wallets, List<Member> members, {String? systemText}) async {
    final evs = <SyncEvent>[];
    await _db.transaction((tx) async {
      await tx.insert('trips', trip.toMap());
      for (final w in wallets) {
        await tx.insert('wallets', w.toMap());
      }
      for (final m in members) {
        await tx.insert('members', m.toMap());
      }
      evs.add(await _emit(
        tx,
        trip.id,
        'msg',
        Message(
          id: newId(),
          tripId: trip.id,
          kind: MsgKind.system,
          text: systemText ?? 'Поездка создана · ${members.length} участников',
          created: DateTime.now(),
        ).toMap(),
      ));
    });
    _published(evs);
  }

  Future<bool> hasTrip(String id) async {
    final r = await _db.query('trips', columns: ['id'], where: 'id = ?', whereArgs: [id]);
    return r.isNotEmpty;
  }

  /// Присоединение по приглашению: копия поездки на этом телефоне.
  /// Новый участник и его кошелёк уходят остальным через журнал.
  Future<void> joinTrip(Trip trip, List<Wallet> wallets, List<Member> members, String myName,
      {Wallet? newWallet, Member? newMember, bool announce = true}) async {
    final evs = <SyncEvent>[];
    await _db.transaction((tx) async {
      await tx.insert('trips', trip.toMap());
      for (final w in wallets) {
        if (w.id != newWallet?.id) await tx.insert('wallets', w.toMap());
      }
      for (final m in members) {
        if (m.id != newMember?.id) await tx.insert('members', m.toMap());
      }
      if (newWallet != null) evs.add(await _emit(tx, trip.id, 'wallet', newWallet.toMap()));
      if (newMember != null) {
        evs.add(await _emit(tx, trip.id, 'member', newMember.toMap()));
        await tx.update('members', {'is_me': 1}, where: 'id = ?', whereArgs: [newMember.id]);
      }
      if (announce) {
        evs.add(await _emit(
        tx,
        trip.id,
        'msg',
        Message(
          id: newId(),
          tripId: trip.id,
          authorId: members.where((m) => m.isMe).firstOrNull?.id,
          kind: MsgKind.system,
          text: '$myName присоединился(ась) к поездке',
          created: DateTime.now(),
        ).toMap(),
      ));
      }
    });
    _published(evs);
  }

  /// Только локальные поля (архив) — другим телефонам не передаётся.
  Future<void> updateTrip(Trip trip) async {
    await _db.update('trips', {'archived': trip.archived ? 1 : 0}, where: 'id = ?', whereArgs: [trip.id]);
    notifyListeners();
  }

  /// Удаляет поездку только с этого телефона.
  Future<void> deleteTrip(String tripId) async {
    await _db.transaction((tx) async {
      final ex = await tx.query('expenses', columns: ['id'], where: 'trip_id = ?', whereArgs: [tripId]);
      for (final e in ex) {
        await tx.delete('expense_parts', where: 'expense_id = ?', whereArgs: [e['id']]);
      }
      final files = await tx.rawQuery(
          'SELECT f.path FROM media_files f JOIN media m ON m.id = f.media_id WHERE m.trip_id = ?', [tripId]);
      for (final f in files) {
        try {
          File(f['path'] as String).deleteSync();
        } catch (_) {}
      }
      await tx.rawDelete('DELETE FROM media_files WHERE media_id IN (SELECT id FROM media WHERE trip_id = ?)', [tripId]);
      for (final t in ['expenses', 'messages', 'members', 'wallets', 'transfers', 'plan_items', 'events', 'deleted', 'media', 'reactions', 'polls', 'votes']) {
        await tx.delete(t, where: 'trip_id = ?', whereArgs: [tripId]);
      }
      await tx.delete('trips', where: 'id = ?', whereArgs: [tripId]);
    });
    notifyListeners();
  }

  Future<Message?> lastMessage(String tripId) async {
    final r = await _db.query('messages',
        where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'created DESC', limit: 1);
    return r.isEmpty ? null : Message.fromMap(r.first);
  }

  // ---------- чат ----------
  Future<List<Message>> messages(String tripId) async {
    final r = await _db.query('messages', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'created ASC');
    return r.map(Message.fromMap).toList();
  }

  Future<void> _one(String tripId, String type, Map<String, dynamic> data) async {
    final evs = <SyncEvent>[];
    await _db.transaction((tx) async => evs.add(await _emit(tx, tripId, type, data)));
    _published(evs);
  }

  Future<void> addMessage(Message m) => _one(m.tripId, 'msg', m.toMap());

  /// Текст с упоминаниями: [at] — телефоны упомянутых (подсказка серверу для push без звука).
  Future<void> sendText(Message m, {List<String> at = const []}) =>
      _one(m.tripId, 'msg', {...m.toMap(), if (at.isNotEmpty) 'at': at});

  Future<void> setMeeting(Trip trip, String text, String time, String? authorId, {double? lat, double? lng}) async {
    trip.meetingText = text;
    trip.meetingTime = time;
    trip.meetingLat = lat;
    trip.meetingLng = lng;
    await _one(trip.id, 'meeting', {'text': text, 'time': time, 'lat': lat, 'lng': lng, 'author': authorId});
  }

  // ---------- расходы ----------
  Future<List<Expense>> expenses(String tripId) async {
    final r = await _db.query('expenses', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'created DESC');
    final out = <Expense>[];
    for (final e in r) {
      final parts = await _db.query('expense_parts', where: 'expense_id = ?', whereArgs: [e['id']]);
      out.add(Expense.fromMap(e, {for (final pRow in parts) pRow['wallet_id'] as String: pRow['cents'] as int}));
    }
    return out;
  }

  Future<Expense?> expense(String id) async {
    final r = await _db.query('expenses', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return null;
    final parts = await _db.query('expense_parts', where: 'expense_id = ?', whereArgs: [id]);
    return Expense.fromMap(r.first, {for (final pRow in parts) pRow['wallet_id'] as String: pRow['cents'] as int});
  }

  Future<void> addExpense(Expense e, String? authorId) => _one(e.tripId, 'expense', {'e': e.toMap(), 'p': e.parts});

  Future<void> deleteExpense(String id) async {
    final r = await _db.query('expenses', columns: ['trip_id'], where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return;
    await _one(r.first['trip_id'] as String, 'expense.del', {'id': id});
  }

  Future<List<Transfer>> transfers(String tripId) async {
    final r = await _db.query('transfers', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'created DESC');
    return r.map(Transfer.fromMap).toList();
  }

  Future<void> addTransfer(Transfer t, String text) => _one(t.tripId, 'transfer', {'t': t.toMap(), 'text': text});

  // ---------- план ----------
  Future<List<PlanItem>> plan(String tripId) async {
    final r = await _db.query('plan_items', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'day ASC, time ASC');
    return r.map(PlanItem.fromMap).toList();
  }

  Future<void> addPlanItem(PlanItem i) => _one(i.tripId, 'plan', {'i': i.toMap()});

  Future<void> togglePlanItem(PlanItem i) async {
    i.done = !i.done;
    await _one(i.tripId, 'plan.done', {'id': i.id, 'done': i.done});
  }

  Future<void> deletePlanItem(String id) async {
    final r = await _db.query('plan_items', columns: ['trip_id'], where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return;
    await _one(r.first['trip_id'] as String, 'plan.del', {'id': id});
  }

  // ---------- вложения ----------
  /// Новое вложение с этого телефона: [files] — части, которые лежат здесь (part → путь);
  /// все, кроме оригинала фото, помечаются «загрузить на сервер».
  Future<void> addMedia(Media m, Map<String, String> files) async {
    final evs = <SyncEvent>[];
    await _db.transaction((tx) async {
      for (final f in files.entries) {
        await tx.insert('media_files', {'media_id': m.id, 'part': f.key, 'path': f.value, 'up': f.key == 'o' ? 1 : 0},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final data = m.toMap()..remove('trip_id');
      evs.add(await _emit(tx, m.tripId, 'media', data));
    });
    _published(evs);
  }

  Future<List<Media>> mediaList({String? tripId, Set<MediaKind>? kinds}) async {
    final r = tripId == null
        ? await _db.query('media', orderBy: 'created DESC')
        : await _db.query('media', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'created DESC');
    final all = r.map(Media.fromMap);
    return (kinds == null ? all : all.where((m) => kinds.contains(m.kind))).toList();
  }

  Future<Media?> media(String id) async {
    final r = await _db.query('media', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Media.fromMap(r.first);
  }

  /// Части вложений на этом телефоне: mediaId → {part → путь}.
  Future<Map<String, Map<String, String>>> localMediaFiles() async {
    final out = <String, Map<String, String>>{};
    for (final r in await _db.query('media_files')) {
      (out[r['media_id'] as String] ??= {})[r['part'] as String] = r['path'] as String;
    }
    return out;
  }

  Future<String?> mediaPath(String mediaId, String part) async {
    final r = await _db.query('media_files', where: 'media_id = ? AND part = ?', whereArgs: [mediaId, part]);
    return r.isEmpty ? null : r.first['path'] as String;
  }

  /// Часть пришла с другого телефона или с сервера.
  Future<void> setMediaFile(String mediaId, String part, String path) async {
    await _db.insert('media_files', {'media_id': mediaId, 'part': part, 'path': path, 'up': 1},
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  /// Свои части, которых ещё нет на сервере.
  Future<List<(Media, String, String)>> pendingUploads() async {
    final r = await _db.rawQuery(
        'SELECT m.*, f.part AS f_part, f.path AS f_path FROM media_files f JOIN media m ON m.id = f.media_id WHERE f.up = 0');
    return [for (final x in r) (Media.fromMap(x), x['f_part'] as String, x['f_path'] as String)];
  }

  Future<void> markUploaded(String mediaId, String part) =>
      _db.update('media_files', {'up': 1}, where: 'media_id = ? AND part = ?', whereArgs: [mediaId, part]);

  Future<void> deleteMedia(Media m) => _one(m.tripId, 'media.del', {'id': m.id});

  // ---------- сообщения: ответ, правка, удаление, реакции, опросы (0.7) ----------
  Future<void> editMessage(Message m, String text) =>
      _one(m.tripId, 'msg.edit', {'id': m.id, 'text': text, 'author': m.authorId});

  Future<void> deleteMessage(Message m) => _one(m.tripId, 'msg.del', {'id': m.id, 'author': m.authorId});

  /// Своя реакция на сообщение; пустая строка — убрать.
  Future<void> react(String tripId, String msgId, String? memberId, String emoji) =>
      _one(tripId, 'react', {'msg': msgId, 'member': memberId, 'e': emoji});

  /// Реакции беседы: msgId → {memberId → emoji}.
  Future<Map<String, Map<String, String>>> reactions(String tripId) async {
    final out = <String, Map<String, String>>{};
    for (final r in await _db.query('reactions', where: 'trip_id = ?', whereArgs: [tripId])) {
      (out[r['msg_id'] as String] ??= {})[r['member_id'] as String? ?? ''] = r['emoji'] as String;
    }
    return out;
  }

  Future<void> addPoll(String tripId, String? authorId, String q, List<String> options, {bool multi = false, int channel = 0}) =>
      _one(tripId, 'poll', {
        'id': newId(),
        'author': authorId,
        'q': q,
        'o': options,
        'multi': multi,
        'created': DateTime.now().millisecondsSinceEpoch,
        'channel': channel,
      });

  Future<void> vote(String tripId, String pollId, String? memberId, List<int> choices) =>
      _one(tripId, 'vote', {'poll': pollId, 'member': memberId, 'c': choices});

  Future<Map<String, Poll>> polls(String tripId) async {
    final out = <String, Poll>{};
    for (final r in await _db.query('polls', where: 'trip_id = ?', whereArgs: [tripId])) {
      out[r['id'] as String] = Poll(
        r['id'] as String,
        tripId,
        r['author_id'] as String?,
        r['question'] as String,
        (jsonDecode(r['options'] as String) as List).cast<String>(),
        r['multi'] == 1,
        DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
      );
    }
    return out;
  }

  /// Голоса: pollId → {memberId → номера вариантов}.
  Future<Map<String, Map<String, List<int>>>> votes(String tripId) async {
    final out = <String, Map<String, List<int>>>{};
    for (final r in await _db.query('votes', where: 'trip_id = ?', whereArgs: [tripId])) {
      (out[r['poll_id'] as String] ??= {})[r['member_id'] as String? ?? ''] =
          (jsonDecode(r['choices'] as String) as List).map((x) => (x as num).toInt()).toList();
    }
    return out;
  }

  // ---------- звук беседы ----------
  Future<bool> isMuted(String tripId) async => (await getSetting('mute:$tripId')) == '1';

  Future<void> setMuted(String tripId, bool on) async {
    await setSetting('mute:$tripId', on ? '1' : '0');
    notifyListeners();
  }

  Future<Set<String>> mutedTrips() async {
    final r = await _db.query('kv', where: "k LIKE 'mute:%' AND v = '1'");
    return {for (final x in r) (x['k'] as String).substring(5)};
  }
}
