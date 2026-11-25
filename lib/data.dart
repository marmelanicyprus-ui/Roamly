// Локальное хранилище Roamly offline: всё лежит на телефоне (SQLite).
// Синхронизация телефон-телефон появится в следующей сборке.
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

class Repo extends ChangeNotifier {
  Repo._(this._db);
  final Database _db;

  static Future<Repo> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'roamly.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('''CREATE TABLE trips (id TEXT PRIMARY KEY, name TEXT, type INTEGER,
          start_ms INTEGER, end_ms INTEGER, currency TEXT, child_percent INTEGER, archived INTEGER,
          meeting_text TEXT, meeting_time TEXT, created INTEGER)''');
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
          time TEXT, title TEXT, done INTEGER)''');
      },
    );
    return Repo._(db);
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
    await _db.transaction((tx) async {
      await tx.insert('trips', trip.toMap());
      for (final w in wallets) {
        await tx.insert('wallets', w.toMap());
      }
      for (final m in members) {
        await tx.insert('members', m.toMap());
      }
      await tx.insert(
        'messages',
        Message(
          id: newId(),
          tripId: trip.id,
          kind: MsgKind.system,
          text: 'Поездка создана · ${members.length} участников',
          created: DateTime.now(),
        ).toMap(),
      );
    });
    notifyListeners();
  }

  Future<bool> hasTrip(String id) async {
    final r = await _db.query('trips', columns: ['id'], where: 'id = ?', whereArgs: [id]);
    return r.isNotEmpty;
  }

  /// Присоединение по приглашению: копия поездки на этом телефоне.
  Future<void> joinTrip(Trip trip, List<Wallet> wallets, List<Member> members, String myName) async {
    await _db.transaction((tx) async {
      await tx.insert('trips', trip.toMap());
      for (final w in wallets) {
        await tx.insert('wallets', w.toMap());
      }
      for (final m in members) {
        await tx.insert('members', m.toMap());
      }
      await tx.insert(
        'messages',
        Message(
          id: newId(),
          tripId: trip.id,
          kind: MsgKind.system,
          text: '$myName присоединился(ась) по QR',
          created: DateTime.now(),
        ).toMap(),
      );
    });
    notifyListeners();
  }

  Future<void> updateTrip(Trip trip) async {
    await _db.update('trips', trip.toMap(), where: 'id = ?', whereArgs: [trip.id]);
    notifyListeners();
  }

  Future<void> deleteTrip(String tripId) async {
    await _db.transaction((tx) async {
      final ex = await tx.query('expenses', columns: ['id'], where: 'trip_id = ?', whereArgs: [tripId]);
      for (final e in ex) {
        await tx.delete('expense_parts', where: 'expense_id = ?', whereArgs: [e['id']]);
      }
      for (final t in ['expenses', 'messages', 'members', 'wallets', 'transfers', 'plan_items']) {
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

  Future<void> addMessage(Message m) async {
    await _db.insert('messages', m.toMap());
    notifyListeners();
  }

  Future<void> setMeeting(Trip trip, String text, String time, String? authorId) async {
    trip.meetingText = text;
    trip.meetingTime = time;
    await _db.update('trips', trip.toMap(), where: 'id = ?', whereArgs: [trip.id]);
    await _db.insert(
      'messages',
      Message(
        id: newId(),
        tripId: trip.id,
        authorId: authorId,
        kind: MsgKind.meeting,
        text: '$text · $time',
        created: DateTime.now(),
      ).toMap(),
    );
    notifyListeners();
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

  Future<void> addExpense(Expense e, String? authorId) async {
    await _db.transaction((tx) async {
      await tx.insert('expenses', e.toMap());
      for (final entry in e.parts.entries) {
        await tx.insert('expense_parts', {'expense_id': e.id, 'wallet_id': entry.key, 'cents': entry.value});
      }
      await tx.insert(
        'messages',
        Message(
          id: newId(),
          tripId: e.tripId,
          authorId: e.payerId,
          kind: MsgKind.expense,
          text: e.title,
          refId: e.id,
          created: e.created,
        ).toMap(),
      );
    });
    notifyListeners();
  }

  Future<void> deleteExpense(String id) async {
    await _db.transaction((tx) async {
      await tx.delete('expense_parts', where: 'expense_id = ?', whereArgs: [id]);
      await tx.delete('expenses', where: 'id = ?', whereArgs: [id]);
      await tx.delete('messages', where: 'ref_id = ?', whereArgs: [id]);
    });
    notifyListeners();
  }

  Future<List<Transfer>> transfers(String tripId) async {
    final r = await _db.query('transfers', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'created DESC');
    return r.map(Transfer.fromMap).toList();
  }

  Future<void> addTransfer(Transfer t, String text) async {
    await _db.insert('transfers', t.toMap());
    await _db.insert(
      'messages',
      Message(id: newId(), tripId: t.tripId, kind: MsgKind.system, text: text, created: t.created).toMap(),
    );
    notifyListeners();
  }

  // ---------- план ----------
  Future<List<PlanItem>> plan(String tripId) async {
    final r = await _db.query('plan_items', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'day ASC, time ASC');
    return r.map(PlanItem.fromMap).toList();
  }

  Future<void> addPlanItem(PlanItem i) async {
    await _db.insert('plan_items', i.toMap());
    notifyListeners();
  }

  Future<void> togglePlanItem(PlanItem i) async {
    i.done = !i.done;
    await _db.update('plan_items', i.toMap(), where: 'id = ?', whereArgs: [i.id]);
    notifyListeners();
  }

  Future<void> deletePlanItem(String id) async {
    await _db.delete('plan_items', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }
}
