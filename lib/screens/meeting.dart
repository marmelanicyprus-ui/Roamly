import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data.dart';

// Карта: OpenStreetMap. Офлайн-регионы — в следующих сборках, сейчас тайлы грузятся из интернета.
// Публичные тайлы OSM запрещены для приложений (блокируют) — берём CARTO Voyager (данные OSM).
const _tiles = 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';
const _subdomains = ['a', 'b', 'c', 'd'];
const _pkg = 'com.roamlyoffline.roamly';
const _defaultCenter = LatLng(34.9178, 33.6383); // если нет геопозиции

Future<LatLng?> myLocation(BuildContext context) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final last = await Geolocator.getLastKnownPosition();
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return last == null ? null : LatLng(last.latitude, last.longitude);
    }
  } catch (_) {
    return null;
  }
}

/// Открыть точку в навигаторе (Google Карты или другое приложение карт).
Future<void> openInMaps(double lat, double lng, String label) async {
  final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(label)})');
  if (!await launchUrl(geo, mode: LaunchMode.externalApplication)) {
    await launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
        mode: LaunchMode.externalApplication);
  }
}

Widget _pin(Color c) => Icon(Icons.location_on, size: 44, color: c, shadows: const [Shadow(blurRadius: 6, color: Colors.black26)]);

Widget _meDot() => Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: const Color(0xFF1D4ED8),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
      ),
    );

Widget _attribution() => const SimpleAttributionWidget(source: Text('OpenStreetMap contributors · CARTO'));

/// Экран выбора точки: тап по карте ставит метку.
class MapPickerScreen extends StatefulWidget {
  const MapPickerScreen({super.key, this.initial});
  final LatLng? initial;
  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  final _map = MapController();
  LatLng? _point;
  LatLng? _me;

  @override
  void initState() {
    super.initState();
    _point = widget.initial;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final me = await myLocation(context);
      if (!mounted || me == null) return;
      setState(() => _me = me);
      if (widget.initial == null) _map.move(me, 16);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Точка сбора на карте')),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: widget.initial ?? _defaultCenter,
            initialZoom: widget.initial == null ? 12 : 16,
            onTap: (_, p) => setState(() => _point = p),
          ),
          children: [
            TileLayer(urlTemplate: _tiles, subdomains: _subdomains, userAgentPackageName: _pkg),
            MarkerLayer(markers: [
              if (_me != null) Marker(point: _me!, width: 24, height: 24, child: _meDot()),
              if (_point != null) Marker(point: _point!, width: 48, height: 48, alignment: Alignment.topCenter, child: _pin(cs.primary)),
            ]),
            _attribution(),
          ],
        ),
        Positioned(
          left: 16,
          right: 16,
          top: 12,
          child: Material(
            color: cs.surface,
            elevation: 2,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _point == null ? 'Нажмите на карту, чтобы поставить точку сбора' : 'Точка выбрана. Можно нажать в другом месте, чтобы передвинуть.',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 100,
          child: FloatingActionButton.small(
            heroTag: 'myLoc',
            tooltip: 'Где я',
            onPressed: () async {
              final me = _me ?? await myLocation(context);
              if (me == null) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет доступа к геопозиции')));
                }
                return;
              }
              setState(() => _me = me);
              _map.move(me, 16);
            },
            child: const Icon(Icons.my_location),
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            if (_me != null)
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  onPressed: () => setState(() => _point = _me),
                  child: const Text('Я здесь'),
                ),
              ),
            if (_me != null) const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: _point == null ? null : () => Navigator.pop(context, _point),
                child: const Text('Готово'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Диалог точки сбора: название, время, метка на карте.
Future<void> editMeeting(BuildContext context, TripBundle b) async {
  final repo = App.read(context).repo;
  final t = b.trip;
  final place = TextEditingController(text: t.meetingText ?? '');
  TimeOfDay time = TimeOfDay.now();
  if (t.meetingTime != null && t.meetingTime!.contains(':')) {
    final parts = t.meetingTime!.split(':');
    time = TimeOfDay(hour: int.tryParse(parts[0]) ?? time.hour, minute: int.tryParse(parts[1]) ?? time.minute);
  }
  LatLng? point = t.meetingLat == null ? null : LatLng(t.meetingLat!, t.meetingLng!);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('Точка сбора'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: place, autofocus: point == null, decoration: const InputDecoration(labelText: 'Где (например, марина, причал C)')),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule),
            label: Text('Когда: ${time.format(ctx)}'),
            onPressed: () async {
              final v = await showTimePicker(context: ctx, initialTime: time);
              if (v != null) setD(() => time = v);
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: Icon(point == null ? Icons.add_location_alt_outlined : Icons.check_circle_outline),
            label: Text(point == null ? 'Отметить на карте' : 'На карте: ${point!.latitude.toStringAsFixed(4)}, ${point!.longitude.toStringAsFixed(4)}'),
            onPressed: () async {
              final p = await Navigator.push<LatLng>(ctx, MaterialPageRoute(builder: (_) => MapPickerScreen(initial: point)));
              if (p != null) setD(() => point = p);
            },
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Закрепить')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  var text = place.text.trim();
  if (text.isEmpty && point == null) return;
  if (text.isEmpty) text = 'Точка на карте';
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  await repo.setMeeting(t, text, '$hh:$mm', b.me?.id, lat: point?.latitude, lng: point?.longitude);
}

/// Вкладка «Карта» поездки: точка сбора и я.
class MapTab extends StatefulWidget {
  const MapTab({super.key, required this.b});
  final TripBundle b;
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> with AutomaticKeepAliveClientMixin {
  final _map = MapController();
  LatLng? _me;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final me = await myLocation(context);
      if (!mounted || me == null) return;
      setState(() => _me = me);
      if (widget.b.trip.meetingLat == null) _map.move(me, 15);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final t = widget.b.trip;
    final meet = t.meetingLat == null ? null : LatLng(t.meetingLat!, t.meetingLng!);
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(initialCenter: meet ?? _defaultCenter, initialZoom: meet == null ? 12 : 15),
        children: [
          TileLayer(urlTemplate: _tiles, subdomains: _subdomains, userAgentPackageName: _pkg),
          MarkerLayer(markers: [
            if (_me != null) Marker(point: _me!, width: 24, height: 24, child: _meDot()),
            if (meet != null) Marker(point: meet, width: 48, height: 48, alignment: Alignment.topCenter, child: _pin(cs.primary)),
          ]),
          _attribution(),
        ],
      ),
      Positioned(
        left: 12,
        right: 12,
        bottom: 16,
        child: Material(
          color: cs.surface,
          elevation: 3,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(children: [
              Icon(Icons.flag_outlined, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(t.meetingText == null ? 'Точка сбора не задана' : 'Сбор · ${t.meetingTime ?? ''}',
                      style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary)),
                  if (t.meetingText != null) Text(t.meetingText!, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (t.meetingText != null && meet == null)
                    Text('без метки на карте', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ]),
              ),
              if (meet != null)
                IconButton(
                  tooltip: 'Маршрут',
                  icon: const Icon(Icons.directions),
                  onPressed: () => openInMaps(meet.latitude, meet.longitude, t.meetingText ?? 'Точка сбора'),
                ),
              IconButton(
                tooltip: 'Изменить точку сбора',
                icon: const Icon(Icons.edit_location_alt_outlined),
                onPressed: () => editMeeting(context, widget.b),
              ),
            ]),
          ),
        ),
      ),
      Positioned(
        right: 16,
        top: 16,
        child: FloatingActionButton.small(
          heroTag: 'tabMyLoc',
          tooltip: 'Где я',
          onPressed: () async {
            final me = _me ?? await myLocation(context);
            if (me == null) return;
            setState(() => _me = me);
            _map.move(me, 16);
          },
          child: const Icon(Icons.my_location),
        ),
      ),
    ]);
  }
}
