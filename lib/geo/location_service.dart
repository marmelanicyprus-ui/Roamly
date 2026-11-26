// Где сейчас участники. Своё место телефон рассылает своим:
//   • рядом — через Nearby (сообщение loc, без интернета);
//   • через сервер — WebSocket loc, зашифровано ключом поездки; сервер держит только последнюю точку в памяти.
// В журнал поездки места не пишутся (их слишком много), только «на месте» у точки сбора (запись arrived).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../data.dart';

/// Последнее известное место участника.
class MemberPos {
  final double lat;
  final double lng;
  final double acc;
  final int ts;
  final int? battery;
  const MemberPos(this.lat, this.lng, this.acc, this.ts, this.battery);

  Map<String, Object?> toJson() => {'la': lat, 'lo': lng, 'a': acc, 't': ts, if (battery != null) 'b': battery};
  static MemberPos? fromJson(Map m) {
    final la = m['la'], lo = m['lo'];
    if (la is! num || lo is! num) return null;
    return MemberPos(la.toDouble(), lo.toDouble(), (m['a'] as num?)?.toDouble() ?? 0, (m['t'] as num?)?.toInt() ?? 0,
        (m['b'] as num?)?.toInt());
  }

  Duration get age => DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
}

/// Расстояние в метрах.
double distanceM(double lat1, double lng1, double lat2, double lng2) =>
    Geolocator.distanceBetween(lat1, lng1, lat2, lng2);

/// Направление словами: «на север», «на юго-запад»…
String directionWord(double lat1, double lng1, double lat2, double lng2) {
  final b = Geolocator.bearingBetween(lat1, lng1, lat2, lng2);
  const names = ['на север', 'на северо-восток', 'на восток', 'на юго-восток', 'на юг', 'на юго-запад', 'на запад', 'на северо-запад'];
  final i = (((b + 360) % 360 + 22.5) ~/ 45) % 8;
  return names[i];
}

String distanceText(double m) => m < 1000 ? '${m.round()} м' : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} км';

String ageText(Duration d) {
  if (d.inMinutes < 1) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  if (d.inHours < 24) return '${d.inHours} ч назад';
  return '${d.inDays} дн назад';
}

class LocationService extends ChangeNotifier {
  LocationService(this.repo, {required this.isRoaming});

  final Repo repo;
  final bool Function() isRoaming;

  /// Отправить своё место соседям (tripId, данные) — задаётся в AppState.
  void Function(String tripId, Map<String, Object?> data)? sendNearby;
  void Function(String tripId, Map<String, Object?> data)? sendServer;

  /// Своё место изменилось (для подкачки карты вокруг).
  void Function(double lat, double lng)? onMoved;

  final Map<String, Map<String, MemberPos>> _pos = {}; // tripId → memberId → место
  Position? me;
  bool permission = false;
  StreamSubscription<Position>? _sub;
  Timer? _beat;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  Position? _lastSentPos;
  int? _battery;
  final _bat = Battery();
  bool _restored = false;

  Map<String, MemberPos> positions(String tripId) => _pos[tripId] ?? const {};

  // ---------------- видимость ----------------

  Future<bool> sharing(String tripId) async => (await repo.getSetting('loc_share:$tripId')) != '0';

  Future<void> setSharing(String tripId, bool on) async {
    await repo.setSetting('loc_share:$tripId', on ? '1' : '0');
    notifyListeners();
    if (on) _broadcast(force: true);
  }

  /// Невидимка до этого времени (null — видно).
  Future<DateTime?> hiddenUntil() async {
    final v = int.tryParse(await repo.getSetting('loc_hide_until') ?? '');
    if (v == null || v < DateTime.now().millisecondsSinceEpoch) return null;
    return DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<void> hideFor(Duration? d) async {
    await repo.setSetting('loc_hide_until', d == null ? '0' : '${DateTime.now().add(d).millisecondsSinceEpoch}');
    notifyListeners();
    if (d == null) _broadcast(force: true);
  }

  // ---------------- запуск ----------------

  Future<void> start() async {
    if (_sub != null) return;
    await _restore();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      permission = perm == LocationPermission.always || perm == LocationPermission.whileInUse;
      notifyListeners();
      if (!permission) return;
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15),
      ).listen(_onPosition, onError: (e) => debugPrint('loc: $e'));
      // раз в минуту — «я здесь», чтобы у остальных не устаревало время
      _beat = Timer.periodic(const Duration(minutes: 1), (_) => _broadcast());
      _bat.batteryLevel.then((v) => _battery = v).catchError((_) => -1);
    } catch (e) {
      debugPrint('loc: старт: $e');
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _beat?.cancel();
  }

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    for (final id in await repo.tripIds()) {
      final raw = await repo.getSetting('loc_last:$id');
      if (raw == null) continue;
      try {
        final m = jsonDecode(raw) as Map;
        _pos[id] = {
          for (final e in m.entries)
            if (MemberPos.fromJson(e.value as Map) != null) e.key as String: MemberPos.fromJson(e.value as Map)!,
        };
      } catch (_) {}
    }
  }

  void _onPosition(Position p) {
    me = p;
    notifyListeners();
    onMoved?.call(p.latitude, p.longitude);
    _broadcast();
    _checkArrival(p);
  }

  // ---------------- рассылка ----------------

  Future<void> _broadcast({bool force = false}) async {
    final p = me;
    if (p == null) return;
    final now = DateTime.now();
    final minGap = isRoaming() ? const Duration(minutes: 5) : const Duration(seconds: 30);
    final moved = _lastSentPos == null
        ? double.infinity
        : distanceM(_lastSentPos!.latitude, _lastSentPos!.longitude, p.latitude, p.longitude);
    if (!force && now.difference(_lastSent) < minGap && moved < 50) return;
    if (await hiddenUntil() != null) return;
    _lastSent = now;
    _lastSentPos = p;
    try {
      _battery = await _bat.batteryLevel;
    } catch (_) {}
    for (final id in await repo.tripIds()) {
      final b = await repo.bundle(id);
      final mine = b.me;
      if (mine == null || b.trip.phase == 'archive' || b.trip.phase == 'past') continue;
      if (!await sharing(id)) continue;
      final pos = MemberPos(p.latitude, p.longitude, p.accuracy, now.millisecondsSinceEpoch, _battery);
      (_pos[id] ??= {})[mine.id] = pos;
      final data = {'m': mine.id, ...pos.toJson()};
      sendNearby?.call(id, data);
      sendServer?.call(id, data);
    }
    notifyListeners();
  }

  /// Пришло место участника (рядом или через сервер).
  void receive(String tripId, Map data) {
    final m = data['m'];
    final pos = MemberPos.fromJson(data);
    if (m is! String || pos == null) return;
    final old = _pos[tripId]?[m];
    if (old != null && old.ts >= pos.ts) return;
    (_pos[tripId] ??= {})[m] = pos;
    notifyListeners();
    _save(tripId);
  }

  final Map<String, Timer> _saveTimers = {};
  void _save(String tripId) {
    _saveTimers[tripId]?.cancel();
    _saveTimers[tripId] = Timer(const Duration(seconds: 20), () {
      final all = _pos[tripId];
      if (all == null) return;
      repo.setSetting('loc_last:$tripId', jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}));
    });
  }

  // ---------------- «я на месте» ----------------

  static String meetingKey(Trip t) => '${t.meetingLat},${t.meetingLng},${t.meetingTime}';

  Future<void> _checkArrival(Position p) async {
    for (final id in await repo.tripIds()) {
      final b = await repo.bundle(id);
      final t = b.trip;
      final mine = b.me;
      if (mine == null || t.meetingLat == null || t.meetingLng == null) continue;
      final d = distanceM(p.latitude, p.longitude, t.meetingLat!, t.meetingLng!);
      // 10 м по ТЗ + погрешность GPS (не больше 15 м), чтобы отметка не мигала
      if (d > 10 + min(p.accuracy, 15)) continue;
      await markArrived(b);
    }
  }

  /// Отметить «я на месте» у текущей точки сбора (сам или кнопкой).
  Future<void> markArrived(TripBundle b) async {
    final mine = b.me;
    if (mine == null || b.trip.meetingLat == null) return;
    final key = meetingKey(b.trip);
    if ((await repo.getSetting('arrived:${b.trip.id}')) == key) return;
    await repo.setSetting('arrived:${b.trip.id}', key);
    await repo.emitEvent(b.trip.id, 'arrived', {'member': mine.id, 'key': key, 'name': mine.name});
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
