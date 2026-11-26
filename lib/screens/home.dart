import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data.dart';
import '../sync/sync_badge.dart';
import '../theme.dart';
import 'contacts.dart';
import 'create_trip.dart';
import 'join.dart';
import 'roaming_prep.dart';
import 'trip.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Row {
  final Trip trip;
  final Message? last;
  final int members;
  final String? peer; // для личного чата — имя собеседника
  _Row(this.trip, this.last, this.members, [this.peer]);
}

class _HomeScreenState extends State<HomeScreen> {
  String _folder = 'all';
  List<_Row> _rows = [];
  Set<String> _muted = {};
  Repo? _repoRef;
  Repo get _repo => _repoRef!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_repoRef == null) {
      _repoRef = App.read(context).repo;
      _repo.addListener(_load);
      _load();
    }
  }

  @override
  void dispose() {
    _repo.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final trips = await _repo.trips();
    final rows = <_Row>[];
    for (final t in trips) {
      final b = await _repo.bundle(t.id);
      rows.add(_Row(t, await _repo.lastMessage(t.id), b.members.length, b.members.where((m) => !m.isMe).firstOrNull?.name));
    }
    final muted = await _repo.mutedTrips();
    if (mounted) {
      setState(() {
        _rows = rows;
        _muted = muted;
      });
    }
  }


  List<_Row> get _visible => _rows.where((r) {
        if (r.trip.isDirect) return _folder == 'all' || _folder == 'direct';
        final ph = r.trip.phase;
        return switch (_folder) {
          'active' => ph == 'active',
          'upcoming' => ph == 'upcoming',
          'archive' => ph == 'archive' || ph == 'past',
          'direct' => false,
          _ => ph != 'archive',
        };
      }).toList()
        ..sort((a, b) {
          int rank(_Row x) => x.trip.isDirect ? 1 : switch (x.trip.phase) { 'active' => 0, 'upcoming' => 2, _ => 3 };
          final r = rank(a).compareTo(rank(b));
          if (r != 0) return r;
          if (a.trip.isDirect) {
            final la = a.last?.created ?? a.trip.created, lb = b.last?.created ?? b.trip.created;
            return lb.compareTo(la);
          }
          return a.trip.start.compareTo(b.trip.start);
        });

  @override
  Widget build(BuildContext context) {
    final s = App.of(context);
    final cs = Theme.of(context).colorScheme;
    final active = _rows.where((r) => r.trip.phase == 'active').length;
    return Scaffold(
      backgroundColor: cs.surface,
      drawer: const _Menu(),
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Roamly offline', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
            SyncBadge(suffix: ' · ${s.traffic.label}'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Контакты',
            icon: const Icon(Icons.people_outline),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContactsScreen())),
          ),
          IconButton(
            tooltip: 'Присоединиться по QR',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _join,
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                for (final f in [
                  ('all', 'Все'),
                  ('active', active > 0 ? 'Активные $active' : 'Активные'),
                  ('upcoming', 'Предстоящие'),
                  ('direct', 'Личные'),
                  ('archive', 'Архив'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _folder == f.$1,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _folder = f.$1),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _visible.isEmpty
                ? _Empty(onCreate: _create, onJoin: _join)
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: _visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 82),
                    itemBuilder: (_, i) => _TripTile(row: _visible[i], muted: _muted.contains(_visible[i].trip.id)),
                  ),
          ),
        ],
      ),
      floatingActionButton: _rows.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _choose,
              icon: const Icon(Icons.add),
              label: const Text('Поездка'),
            ),
    );
  }

  void _create() => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateTripScreen()));
  void _join() => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanScreen()));

  void _choose() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('Создать поездку'),
            subtitle: const Text('Вы организатор, пригласите остальных по QR'),
            onTap: () {
              Navigator.pop(ctx);
              _create();
            },
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Присоединиться'),
            subtitle: const Text('Отсканируйте QR-код организатора'),
            onTap: () {
              Navigator.pop(ctx);
              _join();
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate, required this.onJoin});
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.luggage_outlined, size: 56, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          const Text('Поездок пока нет', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('Создайте свою или присоединитесь к поездке друзей — всё работает и без интернета.',
              textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(260, 50)),
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('Создать поездку'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(260, 50)),
            onPressed: onJoin,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Присоединиться по QR'),
          ),
        ]),
      ),
    );
  }
}

String dateRange(DateTime a, DateTime b) {
  final d = DateFormat('d', 'ru');
  final dm = DateFormat('d MMM', 'ru');
  if (a.year == b.year && a.month == b.month) return '${d.format(a)}–${dm.format(b)}';
  return '${dm.format(a)} – ${dm.format(b)}';
}

class _TripTile extends StatelessWidget {
  const _TripTile({required this.row, this.muted = false});
  final _Row row;
  final bool muted;

  Widget _mutedIcon(String tripId, ColorScheme cs) => muted
      ? Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.notifications_off_outlined, size: 16, color: cs.onSurfaceVariant))
      : const SizedBox.shrink();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = row.trip;
    final last = row.last;
    final when = last == null
        ? ''
        : DateUtils.isSameDay(last.created, DateTime.now())
            ? DateFormat('HH:mm').format(last.created)
            : DateFormat('d MMM', 'ru').format(last.created);
    if (t.isDirect) {
      final name = row.peer ?? t.name;
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Avatar(name, size: 54),
        title: Row(children: [
          Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          _mutedIcon(t.id, cs),
          Text(when, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        ]),
        subtitle: Text(last?.text ?? 'Личный чат', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.75))),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: t.id))),
      );
    }
    final phase = switch (t.phase) {
      'active' => 'идёт',
      'upcoming' => 'через ${t.start.difference(DateTime.now()).inDays + 1} дн.',
      'past' => 'завершена',
      _ => 'в архиве',
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        radius: 27,
        backgroundColor: tripColor(t.type),
        child: Icon(tripIcon(t.type), color: Colors.white),
      ),
      title: Row(children: [
        Expanded(child: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
        _mutedIcon(t.id, cs),
        Text(when, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
      ]),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${dateRange(t.start, t.end)} · $phase · ${row.members} уч.',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        if (last != null)
          Text(last.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.75))),
      ]),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: t.id))),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu();
  @override
  Widget build(BuildContext context) {
    final s = App.of(context);
    final cs = Theme.of(context).colorScheme;
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Container(
            color: cs.primary,
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 24, 20, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Avatar(s.myName, size: 56),
              const SizedBox(height: 12),
              Text(s.myName, style: TextStyle(color: cs.onPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
              Text('Free · тестовая сборка', style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.8), fontSize: 13)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('Режим трафика', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final m in TrafficMode.values)
                ChoiceChip(
                  label: Text(m.label),
                  selected: s.traffic == m,
                  showCheckmark: false,
                  onSelected: (_) => s.setTraffic(m),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text('Пока влияет только на подсказки: связь появится в следующей сборке.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: const Text('Подготовить к роумингу'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const RoamingPrepScreen()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('Тема'),
            subtitle: Text(switch (s.themeMode) {
              ThemeMode.light => 'Светлая',
              ThemeMode.dark => 'Тёмная',
              ThemeMode.system => 'Как в системе',
            }),
            onTap: () {
              final next = ThemeMode.values[(s.themeMode.index + 1) % 3];
              s.setTheme(next);
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Моё имя'),
            subtitle: Text(s.myName),
            onTap: () async {
              final c = TextEditingController(text: s.myName);
              final v = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Моё имя'),
                  content: TextField(controller: c, autofocus: true),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Сохранить')),
                  ],
                ),
              );
              if (v != null && v.trim().isNotEmpty) s.setName(v);
            },
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Text('Roamly offline 0.7.0 · данные на телефонах, сервер только передаёт',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
