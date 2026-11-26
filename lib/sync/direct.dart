// Личные чаты и отметки доставки.
//
// Ключ телефона: пара X25519. Открытый ключ участник публикует в каждой своей беседе
// записью «ident». Личный чат — отдельная беседа на двоих (Trip.kind = 1) со своим id и ключом;
// приглашение в него отправляется через общую беседу записью «dm», зашифрованной открытым
// ключом получателя, — остальные участники общей беседы прочитать его не могут.
//
// Отметки: получив сообщения, телефон пишет в беседу «rcpt» {d: время}; открыв чат — {r: время}.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../data.dart';
import '../invite_code.dart';

class DirectService {
  DirectService(this.repo) {
    repo.ingestListeners.add(_onIngested);
    // Новая беседа (создали, вступили по QR или по ссылке) — опубликовать в ней свой ключ.
    repo.addListener(() {
      _identTimer?.cancel();
      _identTimer = Timer(const Duration(seconds: 4), () => ensureIdent().catchError((_) => 0));
    });
  }
  Timer? _identTimer;

  final Repo repo;
  final _x = X25519();
  final _aes = AesGcm.with256bits();
  SimpleKeyPair? _kp;
  String? _pub;
  String myName = '';

  final Map<String, Timer> _deliveredTimers = {};
  final Map<String, int> _readSent = {};

  /// Открытый ключ этого телефона (base64).
  Future<String> publicKey() async {
    await _ensureKeys();
    return _pub!;
  }

  Future<void> _ensureKeys() async {
    if (_kp != null) return;
    final saved = await repo.getSetting('x25519_seed');
    if (saved != null) {
      _kp = await _x.newKeyPairFromSeed(base64Decode(saved));
    } else {
      final kp = await _x.newKeyPair();
      await repo.setSetting('x25519_seed', base64Encode(await kp.extractPrivateKeyBytes()));
      _kp = kp;
    }
    _pub = base64Encode((await _kp!.extractPublicKey()).bytes);
  }

  /// Последняя ошибка ключа/публикации (показывается в «Контактах»), null — всё в порядке.
  String? lastError;
  bool _learned = false;

  /// Опубликовать свой телефон и ключ во всех беседах, где их ещё не знают.
  /// [force] — отправить заново во все беседы (кнопка «Обновить» в контактах).
  Future<int> ensureIdent({bool force = false}) async {
    var sent = 0;
    try {
      if (!_learned) {
        _learned = true;
        await repo.learnDevices();
      }
      await _ensureKeys();
      for (final id in await repo.tripIds()) {
        final b = await repo.bundle(id);
        final me = b.me;
        if (me == null) continue;
        if (!force && me.device == repo.deviceId && me.pub == _pub) continue;
        await repo.emitEvent(id, 'ident', {'member': me.id, 'device': repo.deviceId, 'pub': _pub});
        sent++;
      }
      lastError = null;
    } catch (e) {
      lastError = '$e';
      debugPrint('direct: ключ: $e');
      rethrow;
    }
    return sent;
  }

  // ---------------- входящее ----------------

  void _onIngested(List<SyncEvent> events) {
    for (final e in events) {
      if (e.type == 'dm') _openInvite(e);
      if (const {'msg', 'expense', 'meeting', 'transfer', 'call', 'media', 'poll'}.contains(e.type) && e.device != repo.deviceId) {
        _scheduleDelivered(e.tripId);
      }
    }
  }

  void _scheduleDelivered(String tripId) {
    _deliveredTimers[tripId]?.cancel();
    _deliveredTimers[tripId] = Timer(const Duration(seconds: 3), () async {
      _deliveredTimers.remove(tripId);
      final b = await repo.bundle(tripId);
      await repo.emitEvent(tripId, 'rcpt', {'member': b.me?.id, 'd': DateTime.now().millisecondsSinceEpoch});
    });
  }

  /// Открыли чат беседы: отметить «прочитано», если есть новое чужое.
  Future<void> markRead(TripBundle b) async {
    final last = await repo.lastForeignMessage(b.trip.id);
    if (last == 0 || last <= (_readSent[b.trip.id] ?? 0)) return;
    final mine = (await repo.receipts(b.trip.id)).where((r) => r.device == repo.deviceId).firstOrNull;
    if (mine != null && mine.read >= last) {
      _readSent[b.trip.id] = last;
      return;
    }
    _readSent[b.trip.id] = last;
    final now = DateTime.now().millisecondsSinceEpoch;
    await repo.emitEvent(b.trip.id, 'rcpt', {'member': b.me?.id, 'd': now, 'r': now});
  }

  Future<void> _openInvite(SyncEvent e) async {
    try {
      final b = await repo.bundle(e.tripId);
      final me = b.me;
      if (me == null || e.data['to'] != me.id) return;
      await _ensureKeys();
      final eph = SimplePublicKey(base64Decode(e.data['eph'] as String), type: KeyPairType.x25519);
      final key = await _boxKey(_kp!, eph);
      final box = SecretBox.fromConcatenation(base64Decode(e.data['box'] as String), nonceLength: 12, macLength: 16);
      final j = jsonDecode(utf8.decode(await _aes.decrypt(box, secretKey: key))) as Map<String, dynamic>;
      final p = parseInvite(j['link'] as String);
      if (p == null || await repo.hasTrip(p.trip.id)) return;
      final you = j['you'] as String;
      for (final m in p.members) {
        if (m.id == you) {
          m.isMe = true;
          m.device = repo.deviceId;
          m.pub = _pub;
        }
      }
      await repo.joinTrip(p.trip, p.wallets, p.members, myName, announce: false);
      await ensureIdent();
    } catch (err) {
      debugPrint('direct: приглашение не открылось: $err');
    }
  }

  Future<SecretKey> _boxKey(SimpleKeyPair mine, SimplePublicKey other) async {
    final shared = await _x.sharedSecretKey(keyPair: mine, remotePublicKey: other);
    final bytes = await shared.extractBytes();
    return SecretKey(hash.sha256.convert([...bytes, ...utf8.encode('roamly-dm')]).bytes);
  }

  // ---------------- создание личного чата ----------------

  /// Личный чат с участником общей беседы. Возвращает id беседы.
  Future<String> openWith({required String viaTripId, required String peerMemberId}) async {
    final via = await repo.bundle(viaTripId);
    final peer = via.member(peerMemberId)!;
    final existing = peer.device == null ? null : await repo.directWith(peer.device!);
    if (existing != null) return existing;
    if (peer.pub == null) {
      throw 'Ключ телефона ${peer.name} ещё не пришёл. Нужна версия 0.5.1: пусть ${peer.name} откроет приложение, '
          'когда вы рядом или в интернете, и нажмёт «Обновить» в Контактах';
    }
    await _ensureKeys();
    final (dm, peerDmId) = await _createDirect(name: peer.name, currency: via.trip.currency, peerDevice: peer.device, peerPub: peer.pub);
    // Приглашение — только получателю: шифруем его открытым ключом.
    final link = buildInviteLink(dm);
    final eph = await _x.newKeyPair();
    final key = await _boxKey(eph, SimplePublicKey(base64Decode(peer.pub!), type: KeyPairType.x25519));
    final box = await _aes.encrypt(utf8.encode(jsonEncode({'link': link, 'you': peerDmId})), secretKey: key);
    await repo.emitEvent(viaTripId, 'dm', {
      'to': peer.id,
      'eph': base64Encode((await eph.extractPublicKey()).bytes),
      'box': base64Encode(box.concatenation()),
    });
    return dm.trip.id;
  }

  /// Личный чат с человеком, которого ещё нет в Roamly: ссылка-приглашение для SMS/мессенджера.
  Future<String> inviteLink(String name, String currency) async {
    await _ensureKeys();
    final (dm, _) = await _createDirect(name: name, currency: currency);
    return buildInviteLink(dm);
  }

  Future<(TripBundle, String)> _createDirect({required String name, required String currency, String? peerDevice, String? peerPub}) async {
    final id = newId();
    final now = DateTime.now();
    final trip = Trip(
      id: id,
      name: name,
      type: TripType.hike,
      start: now,
      end: now.add(const Duration(days: 3650)),
      currency: currency,
      created: now,
      kind: 1,
    );
    final w1 = Wallet(id: newId(), tripId: id, name: myName);
    final w2 = Wallet(id: newId(), tripId: id, name: name);
    final me = Member(id: newId(), tripId: id, name: myName, isChild: false, walletId: w1.id, isMe: true, device: repo.deviceId, pub: _pub);
    final peer = Member(id: newId(), tripId: id, name: name, isChild: false, walletId: w2.id, device: peerDevice, pub: peerPub);
    await repo.createTrip(trip, [w1, w2], [me, peer], systemText: 'Личный чат');
    await repo.emitEvent(id, 'ident', {'member': me.id, 'device': repo.deviceId, 'pub': _pub});
    return (TripBundle(trip, [w1, w2], [me, peer]), peer.id);
  }
}
