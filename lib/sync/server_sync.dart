// Синхронизация через сервер-«почту» (когда телефоны не рядом).
//
// Сервер хранит и пересылает записи журнала, но прочитать их не может: каждая запись
// шифруется AES-GCM ключом поездки (выводится из id поездки, который знают только участники
// по QR), а поездка называется серверу только хешем. Протокол — см. server/index.mjs.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data.dart';
import 'nearby_sync.dart' show NearbySync;

/// Адрес сервера. Пока без своего домена — бесплатный адрес sslip.io по IP сервера.
const serverHost = '88-218-76-167.sslip.io';

enum ServerState { off, connecting, online, offline }

class ServerSync extends ChangeNotifier {
  ServerSync(this.repo) {
    repo.addListener(_scheduleFlush);
  }

  final Repo repo;
  final _aes = AesGcm.with256bits();
  final Map<String, SecretKey> _keys = {};
  Map<String, String> _hashToTrip = {};

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _retry;
  Timer? _flushTimer;
  int _attempt = 0;
  bool _enabled = false;
  bool _flushing = false;
  final Set<String> _inFlight = {};

  ServerState state = ServerState.off;
  DateTime? lastSync;
  String? _pushToken;

  /// Push-токен FCM этого телефона: сервер будит по нему, когда приложение закрыто.
  void setPushToken(String token) {
    _pushToken = token;
    if (state == ServerState.online) _send({'k': 'push', 'token': token});
  }

  String get label => switch (state) {
        ServerState.off => 'Интернет выключен (роуминг)',
        ServerState.connecting => 'Подключаюсь к серверу',
        ServerState.online => 'Сервер: на связи',
        ServerState.offline => 'Нет интернета — отправлю позже',
      };

  /// Включить/выключить (режим «Роуминг» — без интернета).
  void setEnabled(bool on) {
    if (on == _enabled) return;
    _enabled = on;
    if (on) {
      _connect();
    } else {
      _close();
      _set(ServerState.off);
    }
  }

  /// Принудительно переподключиться (например, после появления сети или push).
  void poke() {
    if (!_enabled) return;
    if (state == ServerState.online) {
      _subscribe();
      _scheduleFlush();
    } else {
      _retry?.cancel();
      _connect();
    }
  }

  // ---------------- соединение ----------------

  Future<void> _connect() async {
    if (!_enabled) return;
    _close();
    _set(ServerState.connecting);
    try {
      final ch = WebSocketChannel.connect(Uri.parse('wss://$serverHost/ws'));
      _ch = ch;
      await ch.ready.timeout(const Duration(seconds: 15));
      _sub = ch.stream.listen(_onData, onDone: _onClosed, onError: (_) => _onClosed());
      _attempt = 0;
      _set(ServerState.online);
      _send({'k': 'hello', 'dev': repo.deviceId, 'v': 1});
      if (_pushToken != null) _send({'k': 'push', 'token': _pushToken});
      await _subscribe();
      _scheduleFlush();
    } catch (e) {
      debugPrint('server: нет соединения: $e');
      _onClosed();
    }
  }

  void _onClosed() {
    _close();
    if (!_enabled) return;
    _set(ServerState.offline);
    final delays = [2, 5, 10, 30, 60];
    final d = delays[min(_attempt, delays.length - 1)];
    _attempt++;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: d), _connect);
  }

  void _close() {
    _sub?.cancel();
    _sub = null;
    _ch?.sink.close();
    _ch = null;
    _inFlight.clear();
  }

  void _send(Map<String, Object?> m) => _ch?.sink.add(jsonEncode(m));

  Future<void> _subscribe() async {
    final ids = await repo.tripIds();
    _hashToTrip = {for (final id in ids) NearbySync.tripHash(id): id};
    final trips = <String, int>{};
    for (final h in _hashToTrip.keys) {
      trips[h] = int.tryParse(await repo.getSetting('srv_cur:$h') ?? '') ?? 0;
    }
    _send({'k': 'sub', 'trips': trips});
  }

  // ---------------- приём ----------------

  Future<void> _onData(dynamic raw) async {
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (m['k']) {
      case 'ev':
        final h = m['t'] as String;
        final tripId = _hashToTrip[h];
        if (tripId == null) return;
        final out = <SyncEvent>[];
        var cursor = 0;
        for (final row in (m['e'] as List)) {
          final r = (row as Map).cast<String, dynamic>();
          cursor = max(cursor, (r['s'] as num).toInt());
          final e = await _decrypt(tripId, r['b'] as String);
          if (e != null && e.tripId == tripId) out.add(e);
        }
        if (out.isNotEmpty) await repo.ingest(out, fromServer: true);
        if (cursor > 0) await repo.setSetting('srv_cur:$h', '$cursor');
        lastSync = DateTime.now();
        notifyListeners();
      case 'ack':
        final ids = [for (final i in (m['ids'] as List)) i as String];
        _inFlight.removeAll(ids);
        await repo.markSent(ids);
        lastSync = DateTime.now();
        notifyListeners();
    }
  }

  // ---------------- отправка ----------------

  void _scheduleFlush() {
    if (state != ServerState.online) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 300), _flush);
  }

  Future<void> _flush() async {
    if (_flushing || state != ServerState.online) return;
    _flushing = true;
    try {
      // Новая поездка (вступили по QR) — подписаться и на неё.
      final ids = await repo.tripIds();
      if (ids.length != _hashToTrip.length || ids.any((id) => !_hashToTrip.containsValue(id))) {
        await _subscribe();
      }
      final list = (await repo.unsent(limit: 200)).where((e) => !_inFlight.contains(e.id)).toList();
      if (list.isEmpty) return;
      final out = <Map<String, Object?>>[];
      for (final e in list) {
        out.add({
          't': NearbySync.tripHash(e.tripId),
          'id': e.id,
          'b': await _encrypt(e),
          // подсказка серверу для push «входящий звонок» (сам звонок зашифрован)
          if (e.type == 'call') 'n': 'call',
        });
        _inFlight.add(e.id);
      }
      _send({'k': 'put', 'e': out});
    } catch (e) {
      debugPrint('server: отправка: $e');
    } finally {
      _flushing = false;
    }
  }

  // ---------------- шифрование ----------------

  SecretKey _key(String tripId) =>
      _keys[tripId] ??= SecretKey(hash.sha256.convert(utf8.encode('roamly-key:$tripId')).bytes);

  Future<String> _encrypt(SyncEvent e) async {
    final box = await _aes.encrypt(utf8.encode(jsonEncode(e.toWire())), secretKey: _key(e.tripId));
    return base64Encode(box.concatenation());
  }

  Future<SyncEvent?> _decrypt(String tripId, String b64) async {
    try {
      final box = SecretBox.fromConcatenation(base64Decode(b64), nonceLength: 12, macLength: 16);
      final clear = await _aes.decrypt(box, secretKey: _key(tripId));
      return SyncEvent.fromWire((jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
    } catch (e) {
      debugPrint('server: не удалось расшифровать запись: $e');
      return null;
    }
  }

  void _set(ServerState s) {
    state = s;
    notifyListeners();
  }
}
