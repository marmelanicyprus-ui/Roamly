// Локальное хранилище Roamly offline: всё лежит на телефоне (SQLite).
// Каждое изменение — запись в журнале (таблица events). Телефоны обмениваются записями,
// которых нет у другого (sync/nearby_sync.dart), и применяют их через Repo._apply.
import 'dart:convert';

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
  Member({
    required this.id,
    required this.tripId,
    required this.name,
    required this.isChild,
    required this.walletId,
    this.isMe = false,
  });
  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'name': name,
        'is_child': isChild ? 1 : 0,
        'wallet_id': walletId,
        'is_me': isMe ? 1 : 0,
      };
  static Member fromMap(Map<String, Object?> m) => Member(
        id: m['id'] as String,
        tripId: m['trip_id'] as String,
        name: m['name'] as String,
        isChild: (m['is_child'] as int) == 1,
        walletId: m['wallet_id'] as String,
        isMe: (m['is_me'] as int) == 1,
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
  Message({
    required this.id,
    required this.tripId,
    this.authorId,
    required this.kind,
    required this.text,
    this.refId,
    required this.created,
  });
  Map<String, Object?> toMap() => {
        'id': id,
        'trip_id': tripId,
        'author_id': authorId,
        'kind': kind.index,
        'text': text,
        'ref_id': refId,
        'created': created.millisecondsSinceEpoch,
      };
  static Message fromMap(Map<String, Object?> m) => Message(
        id: m['id'] as String,
        tripId: m['trip_id'] as String,
        authorId: m['author_id'] as String?,
        kind: MsgKind.values[m['kind'] as int],
        text: m['text'] as String,
        refId: m['ref_id'] as String?,
        created: DateTime.fromMillisecondsSinceEpoch(m['created'] as int),
      );
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

  /// Вызывается для новых записей, созданных на этом телефоне (для отправки соседям).
  void Function(List<SyncEvent> events)? onLocalEvents;

  static Future<Repo> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'roamly.db'),
      version: 3,
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
        }
      },
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('''CREATE TABLE trips (id TEXT PRIMARY KEY, name TEXT, type INTEGER,
          start_ms INTEGER, end_ms INTEGER, currency TEXT, child_percent INTEGER, archived INTEGER,
          meeting_text TEXT, meeting_time TEXT, created INTEGER, meeting_lat REAL, meeting_lng REAL,
          meeting_ts INTEGER DEFAULT 0)''');
        await db.execute('CREATE TABLE wallets (id TEXT PRIMARY KEY, trip_id TEXT, name TEXT)');
        await db.execute('''CREATE TABLE members (id TEXT PRIMARY KEY, trip_id TEXT, name TEXT,
          is_child INTEGER, wallet_id TEXT, is_me INTEGER)''');
        await db.execute('''CREATE TABLE messages (id TEXT PRIMARY KEY, trip_id TEXT, author_id TEXT,
          kind INTEGER, text TEXT, ref_id TEXT, created INTEGER)''');
        await db.execute('''CREATE TABLE expenses (id TEXT PRIMARY KEY, trip_id TEXT, title TEXT,
          category TEXT, amount_cents INTEGER, currency TEXT, rate REAL, trip_cents INTEGER,
          payer_id TEXT, mode INTEGER, created INTEGER)''');
        await db.execute('CREATE TABLE expense_parts (expense_id TEXT, wallet_id TEXT, cents INTEGER)');
        await db.execute('''CREATE TABLE transfers (id TEXT PRIMARY KEY, trip_id TEXT, from_wallet TEXT,
          to_wallet TEXT, cents INTEGER, created INTEGER)''');
        await db.execute('''CREATE TABLE plan_items (id TEXT PRIMARY KEY, trip_id TEXT, day INTEGER,
          time TEXT, title TEXT, done INTEGER, done_ts INTEGER DEFAULT 0)''');
        await _createSyncTables(db);
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
    await db.execute('''CREATE TABLE events (id TEXT PRIMARY KEY, trip_id TEXT, device TEXT,
      seq INTEGER, ts INTEGER, type TEXT, data TEXT)''');
    await db.execute('CREATE INDEX events_trip ON events (trip_id, device, seq)');
    // Удалённые объекты: чтобы запоздавшая запись «добавить» не вернула их обратно.
    await db.execute('CREATE TABLE deleted (id TEXT PRIMARY KEY, trip_id TEXT)');
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
    onLocalEvents?.call(list);
  }

  /// Записи, пришедшие с другого телефона. Возвращает те, которых здесь ещё не было.
  Future<List<SyncEvent>> ingest(List<SyncEvent> events) async {
    final fresh = <SyncEvent>[];
    final known = (await tripIds()).toSet();
    await _db.transaction((tx) async {
      for (final e in events) {
        if (!known.contains(e.tripId)) continue;
        final n = await tx.insert('events', e.toRow(), conflictAlgorithm: ConflictAlgorithm.ignore);
        if (n == 0) continue; // уже есть
        try {
          await _apply(tx, e);
        } catch (err) {
          debugPrint('sync: не удалось применить ${e.type}: $err');
        }
        fresh.add(e);
      }
    });
    if (fresh.isNotEmpty) notifyListeners();
    return fresh;
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
        final m = _cols(d, ['id', 'trip_id', 'author_id', 'kind', 'text', 'ref_id', 'created']);
        if (!await _isDeleted(tx, m['id'] as String)) await tx.insert('messages', m, conflictAlgorithm: ignore);
      case 'wallet':
        await tx.insert('wallets', _cols(d, ['id', 'trip_id', 'name']), conflictAlgorithm: ignore);
      case 'member':
        final m = _cols(d, ['id', 'trip_id', 'name', 'is_child', 'wallet_id'])..['is_me'] = 0;
        await tx.insert('members', m, conflictAlgorithm: ignore);
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
      case 'plan.del':
        await tx.insert('deleted', {'id': d['id'], 'trip_id': e.tripId}, conflictAlgorithm: ignore);
        await tx.delete('plan_items', where: 'id = ?', whereArgs: [d['id']]);
      default:
        debugPrint('sync: неизвестный тип записи ${e.type} — пропускаем (новая версия у соседа)');
    }
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

  Future<void> createTrip(Trip trip, List<Wallet> wallets, List<Member> members) async {
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
          text: 'Поездка создана · ${members.length} участников',
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
      {Wallet? newWallet, Member? newMember}) async {
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
      for (final t in ['expenses', 'messages', 'members', 'wallets', 'transfers', 'plan_items', 'events', 'deleted']) {
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
}
