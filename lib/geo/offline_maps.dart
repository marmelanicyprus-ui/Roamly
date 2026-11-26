// Карта без интернета: MapLibre хранит скачанные регионы на телефоне.
// Пока есть интернет (и не роуминг), подкачиваем квадрат ±10 км вокруг телефона и вокруг точки сбора.
// Карта мира целиком не качается. Векторные тайлы OpenFreeMap: бесплатно, без ключей;
// их наибольший масштаб 14 уже содержит все улицы и дома, дальше карта просто увеличивается.
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import 'location_service.dart' show distanceM;

const mapStyle = 'https://tiles.openfreemap.org/styles/liberty';
const _radiusKm = 10.0;

class OfflineMaps extends ChangeNotifier {
  OfflineMaps({required this.canDownload});

  /// Есть интернет и не режим «Роуминг».
  final bool Function() canDownload;

  double? progress; // 0..1, null — не качаем
  String? lastError;
  DateTime? lastDone;
  bool _busy = false;
  final Map<String, (double, double)> _last = {}; // вид → центр последней подкачки

  /// Подкачать ±10 км вокруг точки (не чаще, чем при сдвиге на 5 км).
  Future<void> around(double lat, double lng, {String kind = 'around'}) async {
    if (_busy || !canDownload()) return;
    final prev = _last[kind];
    if (prev != null && distanceM(prev.$1, prev.$2, lat, lng) < 5000) return;
    _busy = true;
    _last[kind] = (lat, lng);
    progress = 0;
    notifyListeners();
    try {
      final dLat = _radiusKm / 111.0;
      final dLng = _radiusKm / (111.0 * max(0.1, cos(lat * pi / 180)));
      final def = ml.OfflineRegionDefinition(
        bounds: ml.LatLngBounds(
          southwest: ml.LatLng(lat - dLat, lng - dLng),
          northeast: ml.LatLng(lat + dLat, lng + dLng),
        ),
        mapStyleUrl: mapStyle,
        minZoom: 5,
        maxZoom: 14,
      );
      await ml.downloadOfflineRegion(
        def,
        metadata: {'kind': kind, 'lat': lat, 'lng': lng, 'ts': DateTime.now().millisecondsSinceEpoch},
        onEvent: (ev) {
          if (ev is ml.InProgress) {
            final p = ev.progress;
            progress = (p > 1 ? p / 100 : p).clamp(0.0, 1.0);
          } else if (ev is ml.Success) {
            progress = null;
            lastDone = DateTime.now();
            lastError = null;
            _busy = false;
          } else if (ev is ml.Error) {
            progress = null;
            lastError = 'Карта не скачалась';
            _busy = false;
            _last.remove(kind);
          }
          notifyListeners();
        },
      );
      await _prune(kind);
    } catch (e) {
      debugPrint('offline: $e');
      lastError = 'Карта не скачалась';
      progress = null;
      _busy = false;
      _last.remove(kind);
      notifyListeners();
    }
  }

  /// Держим не больше трёх последних квадратов каждого вида.
  Future<void> _prune(String kind, {int keep = 3}) async {
    try {
      final list = await ml.getListOfRegions();
      final mine = list.where((r) => r.metadata['kind'] == kind).toList()
        ..sort((a, b) => ((b.metadata['ts'] as num?) ?? 0).compareTo((a.metadata['ts'] as num?) ?? 0));
      for (final r in mine.skip(keep)) {
        await ml.deleteOfflineRegion(r.id);
      }
    } catch (e) {
      debugPrint('offline: очистка: $e');
    }
  }
}
