// Автоматическая синхронизация группы рядом, без интернета (Android).
//
// Каждый телефон одновременно объявляет себя и ищет соседей через Google Nearby Connections:
// система сама выбирает Bluetooth, BLE или Wi‑Fi. Найденные телефоны соединяются без вопросов
// пользователю и обмениваются записями журнала (Repo) по поездкам, которые есть у обоих.
//
// Протокол (JSON в байтовых пакетах до ~30 КБ):
//   hello: {k:"hello", v:1, trips:{<хеш поездки>: {<device>: maxSeq}}}
//   ev:    {k:"ev", e:[<запись>...]}
//   want:  {k:"want", t:<хеш>, i:["<mediaId>:<часть>", ...]}   каких частей вложений не хватает
//   file:  {k:"file", pid, m, p}                               следом идёт файл с этим payloadId
// Поездка называется соседу только хешем её id: чужой телефон рядом ничего о ней не узнает.
// iPhone: Nearby Connections там нет — для него будет отдельный транспорт (общая Wi‑Fi сеть / BLE)
// с тем же протоколом hello/ev.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data.dart';

enum SyncState { off, noPermission, error, searching, connected }

class Peer {
  Peer(this.endpointId);
  final String endpointId;
  String? device;
  Set<String> tripHashes = {};
  DateTime? lastExchange;
}

class NearbySync extends ChangeNotifier {
  NearbySync(this.repo) {
    repo.localEventListeners.add(_broadcast);
  }

  final Repo repo;
  static const _serviceId = 'com.roamlyoffline.sync';
  static const _maxPacket = 30000; // лимит Nearby для байтов — 32 КБ

  final _nearby = Nearby();
  final Map<String, Peer> _peers = {}; // соединённые
  final Set<String> _pending = {}; // соединение в процессе
  final Map<String, String> _found = {}; // endpointId -> device
  Map<String, String> _hashToTrip = {};
  Timer? _tick;

  // Передача файлов: что за файл (из сообщения «file») и сам принятый файл.
  final Map<int, (String, String)> _fileMeta = {}; // payloadId → (mediaId, часть)
  final Map<int, Payload> _filePayload = {};
  final Set<int> _fileDone = {};
  final Set<String> _sending = {}; // "endpoint|media:part" — уже отправляем

  /// Принять готовую часть вложения (MediaService.accept).
  Future<bool> Function(String mediaId, String part, String tmpPath)? onFile;

  /// Путь к части вложения, если она есть на этом телефоне.
  Future<String?> Function(String mediaId, String part)? localFile;

  /// Сосед соединился — пора попросить недостающие вложения.
  void Function()? onPeer;

  SyncState state = SyncState.off;
  String? error;
  DateTime? lastSync;

  String get _me => repo.deviceId;

  /// Сколько телефонов рядом соединено (всего или по поездке).
  int peersFor([String? tripId]) {
    if (tripId == null) return _peers.length;
    final h = tripHash(tripId);
    return _peers.values.where((p) => p.tripHashes.contains(h)).length;
  }

  static String tripHash(String tripId) =>
      sha256.convert(utf8.encode('roamly-trip:$tripId')).toString().substring(0, 24);

  // ---------------- запуск ----------------

  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.android) return; // iPhone — позже
    if (state == SyncState.searching || state == SyncState.connected) return;
    if (!await _permissions()) {
      _set(SyncState.noPermission);
      return;
    }
    try {
      await _nearby.stopAdvertising();
      await _nearby.stopDiscovery();
      final okA = await _nearby.startAdvertising(
        _me,
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
      final okD = await _nearby.startDiscovery(
        _me,
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onEndpointFound: _onFound,
        onEndpointLost: (id) {
          if (id != null) _found.remove(id);
        },
      );
      if (!okA && !okD) throw 'Nearby не запустился';
      error = null;
      _set(_peers.isEmpty ? SyncState.searching : SyncState.connected);
      _tick?.cancel();
      // Раз в минуту — повторный обмен векторами: подхватит новые поездки и всё пропущенное.
      _tick = Timer.periodic(const Duration(minutes: 1), (_) => _helloAll());
    } catch (e) {
      error = _human(e);
      _set(SyncState.error);
    }
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> stop() async {
    _tick?.cancel();
    try {
      await _nearby.stopAdvertising();
      await _nearby.stopDiscovery();
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    _peers.clear();
    _pending.clear();
    _found.clear();
    _set(SyncState.off);
  }

  Future<bool> _permissions() async {
    final need = <Permission>[
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ];
    final res = await need.request();
    // на старых Android части разрешений нет — они приходят как granted/restricted
    bool ok(Permission p) {
      final s = res[p];
      return s == null || s.isGranted || s.isLimited || s.isRestricted;
    }

    final bt = ok(Permission.bluetoothScan) && ok(Permission.bluetoothAdvertise) && ok(Permission.bluetoothConnect);
    return bt && (ok(Permission.location) || ok(Permission.nearbyWifiDevices));
  }

  // ---------------- соединения ----------------

  void _onFound(String endpointId, String name, String serviceId) {
    if (name == _me || serviceId != _serviceId) return;
    _found[endpointId] = name;
    if (_peers.containsKey(endpointId) || _pending.contains(endpointId)) return;
    if (_peers.values.any((p) => p.device == name)) return;
    // Соединение просит тот, у кого id меньше; второй подстрахует через 8 с.
    if (_me.compareTo(name) < 0) {
      _request(endpointId);
    } else {
      Future.delayed(const Duration(seconds: 8), () {
        if (_found.containsKey(endpointId) && !_peers.containsKey(endpointId) && !_pending.contains(endpointId)) {
          _request(endpointId);
        }
      });
    }
  }

  Future<void> _request(String endpointId) async {
    _pending.add(endpointId);
    try {
      await _nearby.requestConnection(
        _me,
        endpointId,
        onConnectionInitiated: _onInitiated,
        onConnectionResult: _onResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      _pending.remove(endpointId);
      debugPrint('sync: requestConnection $endpointId: $e');
    }
  }

  void _onInitiated(String endpointId, ConnectionInfo info) {
    _pending.add(endpointId);
    // Принимаем автоматически: данные поездок всё равно уходят только тем, у кого эта поездка есть.
    _nearby
        .acceptConnection(endpointId, onPayLoadRecieved: _onPayload, onPayloadTransferUpdate: _onTransfer)
        .catchError((e) {
      debugPrint('sync: accept $endpointId: $e');
      return false;
    });
  }

  void _onResult(String endpointId, Status status) {
    _pending.remove(endpointId);
    if (status == Status.CONNECTED) {
      _peers[endpointId] = Peer(endpointId)..device = _found[endpointId];
      _set(SyncState.connected);
      _hello(endpointId);
    }
  }

  void _onDisconnected(String endpointId) {
    _peers.remove(endpointId);
    _pending.remove(endpointId);
    if (state == SyncState.connected && _peers.isEmpty) _set(SyncState.searching);
    notifyListeners();
  }

  // ---------------- обмен ----------------

  Future<void> _refreshHashes() async {
    _hashToTrip = {for (final id in await repo.tripIds()) tripHash(id): id};
  }

  Future<void> _helloAll() async {
    for (final id in _peers.keys.toList()) {
      await _hello(id);
    }
  }

  Future<void> _hello(String endpointId) async {
    await _refreshHashes();
    final trips = <String, Map<String, int>>{};
    for (final e in _hashToTrip.entries) {
      trips[e.key] = await repo.vector(e.value);
    }
    await _send(endpointId, {'k': 'hello', 'v': 1, 'dev': _me, 'trips': trips});
  }

  Future<void> _onPayload(String endpointId, Payload payload) async {
    if (payload.type == PayloadType.FILE) {
      _filePayload[payload.id] = payload;
      await _tryFinishFile(payload.id);
      return;
    }
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;
    Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(utf8.decode(payload.bytes!)) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final peer = _peers[endpointId] ?? (_peers[endpointId] = Peer(endpointId));
    switch (msg['k']) {
      case 'hello':
        peer.device = msg['dev'] as String? ?? peer.device;
        await _refreshHashes();
        final theirs = (msg['trips'] as Map? ?? {}).cast<String, dynamic>();
        peer.tripHashes = theirs.keys.where(_hashToTrip.containsKey).toSet();
        // Отдаём то, чего у соседа нет.
        final out = <SyncEvent>[];
        for (final h in peer.tripHashes) {
          final have = (theirs[h] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
          out.addAll(await repo.missingFor(_hashToTrip[h]!, have));
        }
        await _sendEvents(endpointId, out);
        peer.lastExchange = DateTime.now();
        notifyListeners();
        onPeer?.call();
      case 'ev':
        final list = [
          for (final m in (msg['e'] as List? ?? []))
            SyncEvent.fromWire((m as Map).cast<String, dynamic>()),
        ];
        final fresh = await repo.ingest(list);
        if (fresh.isNotEmpty) {
          lastSync = DateTime.now();
          peer.lastExchange = lastSync;
          // Передаём дальше остальным соседям — так запись идёт по цепочке телефонов.
          _broadcast(fresh, except: endpointId);
          notifyListeners();
        }
        onPeer?.call();
      case 'want':
        final items = (msg['i'] as List? ?? []).cast<String>();
        for (final it in items.take(50)) {
          final i = it.lastIndexOf(':');
          if (i <= 0) continue;
          await _sendFile(endpointId, it.substring(0, i), it.substring(i + 1));
        }
      case 'file':
        final pid = (msg['pid'] as num).toInt();
        _fileMeta[pid] = (msg['m'] as String, msg['p'] as String);
        await _tryFinishFile(pid);
    }
  }

  // ---------------- файлы (вложения) ----------------

  /// Попросить у соседей по поездке недостающие части вложений.
  void want(String tripId, List<String> items) {
    final h = tripHash(tripId);
    for (final peer in _peers.values.toList()) {
      if (peer.tripHashes.contains(h)) _send(peer.endpointId, {'k': 'want', 't': h, 'i': items});
    }
  }

  Future<void> _sendFile(String endpointId, String mediaId, String part) async {
    final key = '$endpointId|$mediaId:$part';
    if (_sending.contains(key)) return;
    final path = await localFile?.call(mediaId, part);
    if (path == null || !await File(path).exists()) return;
    _sending.add(key);
    try {
      final pid = await _nearby.sendFilePayload(endpointId, path);
      await _send(endpointId, {'k': 'file', 'pid': pid, 'm': mediaId, 'p': part});
    } catch (e) {
      debugPrint('sync: файл $mediaId.$part: $e');
    } finally {
      Future.delayed(const Duration(minutes: 2), () => _sending.remove(key));
    }
  }

  void _onTransfer(String endpointId, PayloadTransferUpdate u) {
    if (u.status == PayloadStatus.SUCCESS) {
      _fileDone.add(u.id);
      _tryFinishFile(u.id);
    } else if (u.status == PayloadStatus.FAILURE || u.status == PayloadStatus.CANCELED) {
      _fileMeta.remove(u.id);
      _filePayload.remove(u.id);
    }
  }

  Future<void> _tryFinishFile(int pid) async {
    final meta = _fileMeta[pid];
    final payload = _filePayload[pid];
    if (meta == null || payload == null || !_fileDone.contains(pid)) return;
    _fileMeta.remove(pid);
    _filePayload.remove(pid);
    _fileDone.remove(pid);
    try {
      final tmp = pth.join((await getTemporaryDirectory()).path, 'nb_${pid}_${DateTime.now().millisecondsSinceEpoch}');
      if (payload.uri != null) {
        await _nearby.copyFileAndDeleteOriginal(payload.uri!, tmp);
      } else if (payload.filePath != null) {
        await File(payload.filePath!).copy(tmp);
        try {
          await File(payload.filePath!).delete();
        } catch (_) {}
      } else {
        return;
      }
      await onFile?.call(meta.$1, meta.$2, tmp);
    } catch (e) {
      debugPrint('sync: приём файла: $e');
    }
  }

  void _broadcast(List<SyncEvent> events, {String? except}) {
    if (events.isEmpty || _peers.isEmpty) return;
    for (final p in _peers.values.toList()) {
      if (p.endpointId == except) continue;
      final mine = events.where((e) => p.tripHashes.contains(tripHash(e.tripId))).toList();
      if (mine.isNotEmpty) _sendEvents(p.endpointId, mine);
    }
    // новая поездка, о которой сосед ещё не знает, — повторный hello
    final known = _peers.values.expand((p) => p.tripHashes).toSet();
    if (events.any((e) => !known.contains(tripHash(e.tripId)))) _helloAll();
  }

  Future<void> _sendEvents(String endpointId, List<SyncEvent> events) async {
    var batch = <Map<String, Object?>>[];
    var size = 0;
    for (final e in events) {
      final w = e.toWire();
      final len = utf8.encode(jsonEncode(w)).length;
      if (batch.isNotEmpty && size + len > _maxPacket) {
        await _send(endpointId, {'k': 'ev', 'e': batch});
        batch = [];
        size = 0;
      }
      batch.add(w);
      size += len + 1;
    }
    if (batch.isNotEmpty) await _send(endpointId, {'k': 'ev', 'e': batch});
    if (events.isNotEmpty) {
      lastSync = DateTime.now();
      notifyListeners();
    }
  }

  Future<void> _send(String endpointId, Map<String, Object?> msg) async {
    try {
      await _nearby.sendBytesPayload(endpointId, Uint8List.fromList(utf8.encode(jsonEncode(msg))));
    } catch (e) {
      debugPrint('sync: send to $endpointId: $e');
    }
  }

  // ---------------- прочее ----------------

  void _set(SyncState s) {
    state = s;
    notifyListeners();
  }

  String _human(Object e) {
    final t = e.toString();
    if (t.contains('8034') || t.contains('BLUETOOTH')) return 'Включите Bluetooth';
    if (t.contains('8029') || t.contains('LOCATION')) return 'Включите геолокацию';
    return 'Ошибка связи рядом: $t';
  }

  /// Короткая подпись для экранов.
  String label([String? tripId]) => switch (state) {
        SyncState.off => 'Связь рядом выключена',
        SyncState.noPermission => 'Нет разрешений для связи рядом',
        SyncState.error => error ?? 'Ошибка связи рядом',
        SyncState.searching => 'Ищу телефоны рядом',
        SyncState.connected => _nearLabel(peersFor(tripId)),
      };

  static String _nearLabel(int n) => n == 0 ? 'Рядом: нет своих' : 'Рядом: $n ${_phones(n)}';

  static String _phones(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'телефон';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'телефона';
    return 'телефонов';
  }
}
