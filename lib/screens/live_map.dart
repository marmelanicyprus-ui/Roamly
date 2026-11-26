// Вкладка «Карта»: где сейчас свои, точка сбора, «я на месте», открыть в навигаторе.
// Движок MapLibre, карты OpenFreeMap; без интернета — из скачанных квадратов (geo/offline_maps.dart).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../app_state.dart';
import '../data.dart';
import '../geo/location_service.dart';
import '../geo/offline_maps.dart';
import '../geo/open_in.dart';
import '../theme.dart';
import 'trip.dart' show openDirect;

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

class LiveMapTab extends StatefulWidget {
  const LiveMapTab({super.key, required this.b});
  final TripBundle b;
  @override
  State<LiveMapTab> createState() => _LiveMapTabState();
}

class _LiveMapTabState extends State<LiveMapTab> with AutomaticKeepAliveClientMixin {
  ml.MapLibreMapController? _c;
  bool _styleReady = false;
  Timer? _redraw;
  bool _sharing = true;
  DateTime? _hidden;
  Set<String> _arrived = {};
  LocationService? _loc;
  Repo? _repo;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loc == null) {
      final s = App.read(context);
      _loc = s.location;
      _loc!.addListener(_scheduleDraw);
      _repo = s.repo;
      _repo!.addListener(_loadState);
      _loadState();
      s.location.start();
    }
  }

  @override
  void dispose() {
    _loc?.removeListener(_scheduleDraw);
    _repo?.removeListener(_loadState);
    _redraw?.cancel();
    super.dispose();
  }

  Future<void> _loadState() async {
    final s = App.read(context);
    final t = widget.b.trip;
    final sharing = await s.location.sharing(t.id);
    final hidden = await s.location.hiddenUntil();
    final arrived = t.meetingLat == null ? <String>{} : await s.repo.arrivals(t.id, LocationService.meetingKey(t));
    if (t.meetingLat != null) s.offlineMaps.around(t.meetingLat!, t.meetingLng!, kind: 'meeting');
    if (!mounted) return;
    setState(() {
      _sharing = sharing;
      _hidden = hidden;
      _arrived = arrived;
    });
    _scheduleDraw();
  }

  void _scheduleDraw() {
    if (!mounted) return;
    setState(() {});
    _redraw?.cancel();
    _redraw = Timer(const Duration(milliseconds: 600), _draw);
  }

  Future<void> _draw() async {
    final c = _c;
    if (c == null || !_styleReady || !mounted) return;
    final t = widget.b.trip;
    final pos = _loc!.positions(t.id);
    try {
      await c.clearCircles();
      await c.clearSymbols();
      if (t.meetingLat != null) {
        final g = ml.LatLng(t.meetingLat!, t.meetingLng!);
        await c.addCircle(ml.CircleOptions(
          geometry: g,
          circleRadius: 10,
          circleColor: '#E53935',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ), {'meet': 1});
        await c.addSymbol(ml.SymbolOptions(
          geometry: g,
          textField: 'Сбор${t.meetingTime == null ? '' : ' · ${t.meetingTime}'}',
          textSize: 13,
          textOffset: const Offset(0, 1.6),
          textColor: '#B71C1C',
          textHaloColor: '#FFFFFF',
          textHaloWidth: 1.5,
          fontNames: const ['Noto Sans Bold'],
        ));
      }
      for (final m in widget.b.members) {
        if (m.isMe) continue;
        final p = pos[m.id];
        if (p == null) continue;
        final g = ml.LatLng(p.lat, p.lng);
        final stale = p.age > const Duration(minutes: 15);
        await c.addCircle(ml.CircleOptions(
          geometry: g,
          circleRadius: 9,
          circleColor: _hex(avatarColor(m.name)),
          circleOpacity: stale ? 0.45 : 1,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2.5,
        ), {'m': m.id});
        await c.addSymbol(ml.SymbolOptions(
          geometry: g,
          textField: '${m.name}${stale ? ' · ${ageText(p.age)}' : ''}',
          textSize: 12,
          textOffset: const Offset(0, 1.5),
          textColor: '#1B1B1B',
          textHaloColor: '#FFFFFF',
          textHaloWidth: 1.5,
          fontNames: const ['Noto Sans Regular'],
        ));
      }
    } catch (e) {
      debugPrint('map: $e');
    }
  }

  void _onMapCreated(ml.MapLibreMapController c) {
    _c = c;
    c.onCircleTapped.add((circle) {
      final d = circle.data;
      if (d == null) return;
      if (d['m'] is String) _memberSheet(d['m'] as String);
      if (d['meet'] != null) _meetingSheet();
    });
  }

  void _onStyleLoaded() {
    _styleReady = true;
    _draw();
  }

  ml.CameraPosition _initial() {
    final t = widget.b.trip;
    final me = _loc?.me;
    if (t.meetingLat != null) return ml.CameraPosition(target: ml.LatLng(t.meetingLat!, t.meetingLng!), zoom: 14);
    if (me != null) return ml.CameraPosition(target: ml.LatLng(me.latitude, me.longitude), zoom: 14);
    return const ml.CameraPosition(target: ml.LatLng(34.9178, 33.6383), zoom: 8);
  }

  void _moveTo(double lat, double lng, [double zoom = 15]) =>
      _c?.animateCamera(ml.CameraUpdate.newLatLngZoom(ml.LatLng(lat, lng), zoom));

  // ---------------- листы ----------------

  void _memberSheet(String memberId) {
    final m = widget.b.member(memberId);
    final p = _loc!.positions(widget.b.trip.id)[memberId];
    if (m == null || p == null) return;
    final me = _loc!.me;
    final dist = me == null ? null : distanceM(me.latitude, me.longitude, p.lat, p.lng);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Avatar(m.name, size: 44),
            title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              if (dist != null) '${distanceText(dist)} ${directionWord(me!.latitude, me!.longitude, p.lat, p.lng)}',
              ageText(p.age),
              if (p.battery != null && p.battery! >= 0) 'батарея ${p.battery}%',
              if (p.acc > 30) 'точность ±${p.acc.round()} м',
            ].join(' · ')),
          ),
          ListTile(
            leading: const Icon(Icons.center_focus_strong),
            title: const Text('Показать на карте'),
            onTap: () {
              Navigator.pop(ctx);
              _moveTo(p.lat, p.lng, 16);
            },
          ),
          ListTile(
            leading: const Icon(Icons.directions),
            title: const Text('Открыть в навигаторе'),
            onTap: () {
              Navigator.pop(ctx);
              showOpenIn(context, p.lat, p.lng, m.name);
            },
          ),
          if (m.device != null)
            ListTile(
              leading: const Icon(Icons.call_outlined),
              title: const Text('Позвонить лично'),
              onTap: () {
                Navigator.pop(ctx);
                openDirect(context, viaTripId: widget.b.trip.id, memberId: m.id, call: true);
              },
            ),
        ]),
      ),
    );
  }

  void _meetingSheet() {
    final t = widget.b.trip;
    if (t.meetingLat == null) return;
    final s = App.read(context);
    final me = _loc!.me;
    final dist = me == null ? null : distanceM(me.latitude, me.longitude, t.meetingLat!, t.meetingLng!);
    final names = [for (final m in widget.b.members) if (_arrived.contains(m.id)) m.name];
    final myArrived = widget.b.me != null && _arrived.contains(widget.b.me!.id);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.flag, color: Color(0xFFE53935)),
            title: Text(t.meetingText ?? 'Точка сбора', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              if (t.meetingTime != null) 'в ${t.meetingTime}',
              if (dist != null) 'до неё ${distanceText(dist)}',
              names.isEmpty ? 'пока никто не на месте' : 'на месте: ${names.join(', ')}',
            ].join(' · ')),
          ),
          if (!myArrived)
            ListTile(
              leading: const Icon(Icons.where_to_vote_outlined),
              title: const Text('Я на месте'),
              subtitle: const Text('Отмечается само, когда вы в 10 м от точки'),
              onTap: () {
                Navigator.pop(ctx);
                s.location.markArrived(widget.b);
              },
            ),
          ListTile(
            leading: const Icon(Icons.directions),
            title: const Text('Открыть в навигаторе'),
            onTap: () {
              Navigator.pop(ctx);
              showOpenIn(context, t.meetingLat!, t.meetingLng!, t.meetingText ?? 'Точка сбора');
            },
          ),
        ]),
      ),
    );
  }

  void _visibilitySheet() {
    final s = App.read(context);
    final t = widget.b.trip;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(
            value: _sharing,
            title: const Text('Показывать моё место в этой поездке'),
            subtitle: const Text('Видят только участники поездки'),
            onChanged: (v) {
              Navigator.pop(ctx);
              s.location.setSharing(t.id, v);
              _loadState();
            },
          ),
          const Divider(),
          const ListTile(title: Text('Невидимка во всех поездках')),
          for (final (label, d) in [
            ('на 1 час', const Duration(hours: 1)),
            ('на 2 часа', const Duration(hours: 2)),
            ('на 4 часа', const Duration(hours: 4)),
            ('на 8 часов', const Duration(hours: 8)),
          ])
            ListTile(
              dense: true,
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text(label),
              onTap: () {
                Navigator.pop(ctx);
                s.location.hideFor(d);
                _loadState();
              },
            ),
          if (_hidden != null)
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('Снять невидимку'),
              onTap: () {
                Navigator.pop(ctx);
                s.location.hideFor(null);
                _loadState();
              },
            ),
          const ListTile(
            dense: true,
            title: Text('SOS работает всегда, даже в невидимке.', style: TextStyle(fontSize: 12)),
          ),
        ]),
      ),
    );
  }

  // ---------------- экран ----------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final s = App.of(context);
    final t = widget.b.trip;
    final loc = s.location;
    final pos = loc.positions(t.id);
    final me = loc.me;
    final others = [
      for (final m in widget.b.members)
        if (!m.isMe && pos[m.id] != null) m,
    ];
    if (me != null) {
      others.sort((a, b) => distanceM(me.latitude, me.longitude, pos[a.id]!.lat, pos[a.id]!.lng)
          .compareTo(distanceM(me.latitude, me.longitude, pos[b.id]!.lat, pos[b.id]!.lng)));
    }
    final visible = _sharing && _hidden == null;
    return Stack(children: [
      ml.MapLibreMap(
        styleString: mapStyle,
        initialCameraPosition: _initial(),
        onMapCreated: _onMapCreated,
        onStyleLoadedCallback: _onStyleLoaded,
        myLocationEnabled: loc.permission,
        compassEnabled: true,
        attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
      ),
      Positioned(
        top: 10,
        left: 10,
        right: 10,
        child: Row(children: [
          ActionChip(
            avatar: Icon(visible ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
            label: Text(visible ? 'Вас видят свои' : (_hidden != null ? 'Невидимка' : 'Вас не видно')),
            onPressed: _visibilitySheet,
          ),
          const Spacer(),
          ListenableBuilder(
            listenable: s.offlineMaps,
            builder: (context, _) {
              final p = s.offlineMaps.progress;
              if (p == null) return const SizedBox.shrink();
              return Chip(
                avatar: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, value: p == 0 ? null : p)),
                label: Text('Карта вокруг ${(p * 100).round()}%'),
              );
            },
          ),
        ]),
      ),
      Positioned(
        right: 12,
        bottom: 150,
        child: Column(children: [
          if (me != null)
            FloatingActionButton.small(
              heroTag: 'map-me',
              tooltip: 'Где я',
              onPressed: () => _moveTo(me.latitude, me.longitude),
              child: const Icon(Icons.my_location),
            ),
          if (t.meetingLat != null) ...[
            const SizedBox(height: 8),
            FloatingActionButton.small(
              heroTag: 'map-meet',
              tooltip: 'Точка сбора',
              onPressed: () {
                _moveTo(t.meetingLat!, t.meetingLng!);
                _meetingSheet();
              },
              child: const Icon(Icons.flag_outlined),
            ),
          ],
        ]),
      ),
      Positioned(
        left: 12,
        right: 12,
        bottom: 16,
        child: Material(
          color: cs.surface,
          elevation: 3,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 112,
            child: others.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        loc.permission
                            ? 'Здесь появятся участники, когда их телефоны рядом или в интернете'
                            : 'Разрешите доступ к геопозиции, чтобы видеть себя и своих',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(10),
                    children: [
                      for (final m in others) _memberCard(m, pos[m.id]!, cs),
                    ],
                  ),
          ),
        ),
      ),
    ]);
  }

  Widget _memberCard(Member m, MemberPos p, ColorScheme cs) {
    final myLoc = _loc!.me;
    final dist = myLoc == null ? null : distanceM(myLoc.latitude, myLoc.longitude, p.lat, p.lng);
    return GestureDetector(
      onTap: () {
        _moveTo(p.lat, p.lng, 16);
        _memberSheet(m.id);
      },
      child: Container(
        width: 120,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Avatar(m.name, size: 26),
            const SizedBox(width: 6),
            Expanded(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          const Spacer(),
          if (dist != null) Text(distanceText(dist), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          Text(ageText(p.age), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          if (_arrived.contains(m.id)) Text('на месте', style: TextStyle(fontSize: 12, color: cs.primary)),
        ]),
      ),
    );
  }
}
