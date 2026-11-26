import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../calls/call_screen.dart';
import '../data.dart';
import '../money.dart';
import '../sync/sync_badge.dart';
import '../theme.dart';
import 'add_expense.dart';
import 'chat.dart';
import 'home.dart' show dateRange;
import 'invite.dart';
import 'meeting.dart';
import 'photos.dart';
import 'sos.dart';

/// Подписка экрана на изменения хранилища.
mixin RepoListener<T extends StatefulWidget> on State<T> {
  Repo? _r;
  Repo get repo => _r!;
  Future<void> reload();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_r == null) {
      _r = App.read(context).repo;
      _r!.addListener(_onChange);
      reload();
    }
  }

  void _onChange() => reload();

  @override
  void dispose() {
    _r?.removeListener(_onChange);
    super.dispose();
  }
}

class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.tripId});
  final String tripId;
  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> with RepoListener<TripScreen> {
  TripBundle? _b;
  int _unreadImp = 0;
  bool _muted = false;
  bool _searching = false;
  final _search = ValueNotifier<String>('');

  @override
  Future<void> reload() async {
    try {
      final b = await repo.bundle(widget.tripId);
      final unread = await repo.unreadImportant(widget.tripId);
      final muted = await repo.isMuted(widget.tripId);
      if (mounted) {
        setState(() {
          _b = b;
          _unreadImp = unread;
          _muted = muted;
        });
      }
    } catch (_) {
      // поездку удалили
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  PreferredSizeWidget _searchBar() => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _searching = false;
            _search.value = '';
          }),
        ),
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Поиск по переписке', border: InputBorder.none),
          onChanged: (v) => _search.value = v,
        ),
      );

  Future<void> _toggleMute() async {
    final s = App.read(context);
    await repo.setMuted(widget.tripId, !_muted);
    s.server.poke(); // сообщить серверу: push только для звонков и упоминаний
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_muted ? 'Звук включён' : 'Без звука: уведомления только о звонках и @упоминаниях'),
      ));
    }
  }

  List<PopupMenuEntry<String>> _chatMenuItems() => [
        const PopupMenuItem(value: 'search', child: Text('Поиск по переписке')),
        PopupMenuItem(value: 'mute', child: Text(_muted ? 'Включить звук' : 'Выключить звук')),
      ];

  bool _chatMenu(String v) {
    if (v == 'search') {
      setState(() => _searching = true);
      return true;
    }
    if (v == 'mute') {
      _toggleMute();
      return true;
    }
    return false;
  }

  Widget _callButton(TripBundle b, {String tip = 'Позвонить группе'}) => PopupMenuButton<bool>(
        icon: const Icon(Icons.call_outlined),
        tooltip: tip,
        onSelected: (video) => startTripCall(context, b, video: video),
        itemBuilder: (_) => const [
          PopupMenuItem(value: false, child: ListTile(leading: Icon(Icons.call), title: Text('Звонок'))),
          PopupMenuItem(value: true, child: ListTile(leading: Icon(Icons.videocam), title: Text('Видеозвонок'))),
        ],
      );

  /// Личный чат: только переписка и звонки.
  Widget _direct(TripBundle b) {
    final peer = b.members.where((m) => !m.isMe).firstOrNull;
    final name = peer?.name ?? b.trip.name;
    return Scaffold(
      appBar: _searching ? _searchBar() : AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Avatar(name, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              peer?.device == null
                  ? Text('ещё не принял(а) приглашение', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))
                  : SyncBadge(tripId: b.trip.id),
            ]),
          ),
        ]),
        actions: [
          _callButton(b, tip: 'Позвонить'),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (_chatMenu(v)) return;
              if (v == 'delete') {
                await repo.deleteTrip(b.trip.id);
                if (mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (_) => [
              ..._chatMenuItems(),
              const PopupMenuItem(value: 'delete', child: Text('Удалить чат с этого телефона')),
            ],
          ),
        ],
      ),
      body: ChatTab(b: b, search: _search),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (b.trip.isDirect) return _direct(b);
    final cs = Theme.of(context).colorScheme;
    final sos = sosColor(context);
    return DefaultTabController(
      length: 6,
      initialIndex: 1,
      child: Scaffold(
        appBar: _searching ? _searchBar() : AppBar(
          titleSpacing: 0,
          title: Row(children: [
            CircleAvatar(radius: 20, backgroundColor: tripColor(b.trip.type), child: Icon(tripIcon(b.trip.type), color: Colors.white, size: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b.trip.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                Text('${dateRange(b.trip.start, b.trip.end)} · ${b.members.length} участников',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                SyncBadge(tripId: b.trip.id),
              ]),
            ),
          ]),
          actions: [
            _callButton(b),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: sos,
                side: BorderSide(color: sos, width: 2),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 36),
              ),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SosScreen(tripId: b.trip.id))),
              child: const Text('SOS', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (_chatMenu(v)) return;
                if (v == 'invite') {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => InviteScreen(tripId: b.trip.id)));
                } else if (v == 'members') {
                  showMembers(context, b);
                } else if (v == 'archive') {
                  b.trip.archived = !b.trip.archived;
                  await repo.updateTrip(b.trip);
                } else if (v == 'delete') {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Удалить поездку?'),
                      content: const Text('Чат, расходы и план удалятся с этого телефона.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await repo.deleteTrip(b.trip.id);
                    if (mounted) Navigator.pop(context);
                  }
                }
              },
              itemBuilder: (_) => [
                ..._chatMenuItems(),
                const PopupMenuItem(value: 'members', child: Text('Участники · написать лично')),
                const PopupMenuItem(value: 'invite', child: Text('Пригласить по QR')),
                PopupMenuItem(value: 'archive', child: Text(b.trip.archived ? 'Вернуть из архива' : 'В архив')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить поездку')),
              ],
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Важное'),
                  if (_unreadImp > 0) ...[
                    const SizedBox(width: 6),
                    Badge(label: Text('$_unreadImp'), backgroundColor: sos),
                  ],
                ]),
              ),
              const Tab(text: 'Чат'),
              const Tab(text: 'Карта'),
              const Tab(text: 'Расходы'),
              const Tab(text: 'Фото'),
              const Tab(text: 'План'),
            ],
          ),
        ),
        body: TabBarView(children: [
          ChatTab(b: b, channel: 1, search: _search),
          ChatTab(b: b, search: _search),
          MapTab(b: b),
          ExpensesTab(b: b),
          PhotosTab(b: b),
          PlanTab(b: b),
        ]),
      ),
    );
  }
}

/// Участники поездки: написать лично или позвонить.
void showMembers(BuildContext context, TripBundle b) {
  final others = b.members.where((m) => !m.isMe).toList();
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Участники', style: TextStyle(fontWeight: FontWeight.w600))),
        for (final m in others)
          ListTile(
            leading: Avatar(m.name, size: 40),
            title: Text(m.name),
            subtitle: Text(m.device == null ? 'без приложения или ещё не вступил(а)' : (m.isChild ? 'ребёнок' : 'в Roamly')),
            trailing: m.device == null
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.chat_bubble_outline),
                      tooltip: 'Написать лично',
                      onPressed: () {
                        Navigator.pop(ctx);
                        openDirect(context, viaTripId: b.trip.id, memberId: m.id);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.call_outlined),
                      tooltip: 'Позвонить лично',
                      onPressed: () {
                        Navigator.pop(ctx);
                        openDirect(context, viaTripId: b.trip.id, memberId: m.id, call: true);
                      },
                    ),
                  ]),
          ),
        if (others.isEmpty) const ListTile(title: Text('Пока вы одни — пригласите остальных по QR')),
      ]),
    ),
  );
}

/// Открыть (или создать) личный чат с участником; call — сразу позвонить.
Future<void> openDirect(BuildContext context, {required String viaTripId, required String memberId, bool call = false}) async {
  final s = App.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  try {
    final id = await s.direct.openWith(viaTripId: viaTripId, peerMemberId: memberId);
    if (call) {
      final b = await s.repo.bundle(id);
      final room = await s.calls.start(b, video: false, myName: s.myName);
      final peer = b.members.where((m) => !m.isMe).firstOrNull;
      nav.push(MaterialPageRoute(builder: (_) => CallScreen(tripId: id, room: room, video: false, title: peer?.name ?? 'Звонок')));
    } else {
      nav.push(MaterialPageRoute(builder: (_) => TripScreen(tripId: id)));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

// ================= РАСХОДЫ =================

class ExpensesTab extends StatefulWidget {
  const ExpensesTab({super.key, required this.b});
  final TripBundle b;
  @override
  State<ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<ExpensesTab> with RepoListener<ExpensesTab> {
  List<Expense> _ex = [];
  List<Transfer> _tr = [];

  @override
  Future<void> reload() async {
    final ex = await repo.expenses(widget.b.trip.id);
    final tr = await repo.transfers(widget.b.trip.id);
    if (mounted) setState(() {
      _ex = ex;
      _tr = tr;
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.b;
    final cs = Theme.of(context).colorScheme;
    final cur = b.trip.currency;
    final bal = balances(b, _ex, _tr);
    final my = b.me?.walletId;
    final myBal = my == null ? 0 : (bal[my] ?? 0);
    final total = _ex.fold<int>(0, (a, e) => a + e.tripCents);
    final myShare = my == null ? 0 : _ex.fold<int>(0, (a, e) => a + (e.parts[my] ?? 0));
    final plan = settle(bal);
    final myWalletMembers = my == null ? <Member>[] : b.membersOf(my);
    final kids = myWalletMembers.where((m) => m.isChild).length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 96),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Ваш кошелёк${kids > 0 ? ' · вы + $kids дет.' : ''}', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                const SizedBox(height: 6),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(
                    myBal == 0 ? money(0, cur) : '${myBal > 0 ? '+' : ''}${money(myBal, cur)}',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: myBal >= 0 ? cs.primary : cs.error),
                  ),
                  const SizedBox(width: 8),
                  Text(myBal > 0 ? 'вам должны' : myBal < 0 ? 'вы должны' : 'всё ровно', style: TextStyle(color: cs.onSurfaceVariant)),
                ]),
                const SizedBox(height: 8),
                Text('Всего в поездке ${money(total, cur)} · ваша доля ${money(myShare, cur)}', style: const TextStyle(fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          if (plan.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Минимум переводов · ${plan.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  for (final s in plan)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${b.wallet(s.fromWallet)?.name ?? '—'} → ${b.wallet(s.toWallet)?.name ?? '—'}', style: const TextStyle(fontSize: 14)),
                      subtitle: Text(money(s.cents, cur), style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: FilledButton.tonal(
                        onPressed: () => repo.addTransfer(
                          Transfer(
                            id: newId(),
                            tripId: b.trip.id,
                            fromWallet: s.fromWallet,
                            toWallet: s.toWallet,
                            cents: s.cents,
                            created: DateTime.now(),
                          ),
                          '${b.wallet(s.fromWallet)?.name} вернул(а) ${money(s.cents, cur)} → ${b.wallet(s.toWallet)?.name}',
                        ),
                        child: const Text('Вернул'),
                      ),
                    ),
                ]),
              ),
            ),
          if (plan.isNotEmpty) const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text('Траты · ${_ex.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (_ex.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Пока нет трат. Нажмите «Трата».', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
            )
          else
            Card(
              child: Column(children: [
                for (final e in _ex)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: cs.primary.withValues(alpha: 0.14),
                      child: Icon(categoryIcon(e.category), color: cs.primary, size: 20),
                    ),
                    title: Text(e.title),
                    subtitle: Text('${b.member(e.payerId)?.name ?? '—'} · ${_modeLabel(e.mode)}'
                        '${e.currency != cur ? ' · ${money(e.amountCents, e.currency)}' : ''}'),
                    trailing: Text(money(e.tripCents, cur), style: const TextStyle(fontWeight: FontWeight.w600)),
                    onLongPress: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Удалить трату?'),
                          content: Text('${e.title} · ${money(e.tripCents, cur)}'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
                          ],
                        ),
                      );
                      if (ok == true) await repo.deleteExpense(e.id);
                    },
                  ),
              ]),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'addExpense',
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AddExpenseScreen(tripId: b.trip.id))),
        icon: const Icon(Icons.add),
        label: const Text('Трата'),
      ),
    );
  }

  String _modeLabel(SplitMode m) => switch (m) {
        SplitMode.rules => 'по правилам',
        SplitMode.equal => 'поровну',
        SplitMode.manual => 'вручную',
      };
}

// ================= ПЛАН =================

class PlanTab extends StatefulWidget {
  const PlanTab({super.key, required this.b});
  final TripBundle b;
  @override
  State<PlanTab> createState() => _PlanTabState();
}

class _PlanTabState extends State<PlanTab> with RepoListener<PlanTab> {
  List<PlanItem> _items = [];
  late DateTime _day;
  bool _dayInit = false;

  @override
  Future<void> reload() async {
    final items = await repo.plan(widget.b.trip.id);
    if (mounted) setState(() => _items = items);
  }

  List<DateTime> get _days {
    final t = widget.b.trip;
    final out = <DateTime>[];
    var d = DateTime(t.start.year, t.start.month, t.start.day);
    final end = DateTime(t.end.year, t.end.month, t.end.day);
    while (!d.isAfter(end) && out.length < 60) {
      out.add(d);
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return out;
  }

  Future<void> _add() async {
    final title = TextEditingController();
    TimeOfDay time = const TimeOfDay(hour: 9, minute: 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('План на ${DateFormat('d MMMM', 'ru').format(_day)}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, autofocus: true, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Что')),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.schedule),
              label: Text('Время: ${time.format(ctx)}'),
              onPressed: () async {
                final t = await showTimePicker(context: ctx, initialTime: time);
                if (t != null) setD(() => time = t);
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    await repo.addPlanItem(PlanItem(
      id: newId(),
      tripId: widget.b.trip.id,
      day: _day,
      time: '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
      title: title.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final days = _days;
    if (!_dayInit && days.isNotEmpty) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      _day = days.firstWhere((d) => DateUtils.isSameDay(d, today), orElse: () => days.first);
      _dayInit = true;
    }
    if (days.isEmpty) return const SizedBox.shrink();
    final dayItems = _items.where((i) => DateUtils.isSameDay(i.day, _day)).toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        SizedBox(
          height: 74,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            children: [
              for (final d in days)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Material(
                    color: DateUtils.isSameDay(d, _day) ? cs.primary : cs.surface,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _day = d),
                      child: SizedBox(
                        width: 46,
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(DateFormat('E', 'ru').format(d),
                              style: TextStyle(fontSize: 11, color: DateUtils.isSameDay(d, _day) ? cs.onPrimary : cs.onSurfaceVariant)),
                          Text('${d.day}',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: DateUtils.isSameDay(d, _day) ? cs.onPrimary : cs.onSurface)),
                        ]),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: dayItems.isEmpty
              ? Center(child: Text('На этот день планов нет', style: TextStyle(color: cs.onSurfaceVariant)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  children: [
                    Card(
                      child: Column(children: [
                        for (final i in dayItems)
                          CheckboxListTile(
                            value: i.done,
                            onChanged: (_) => repo.togglePlanItem(i),
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(i.title, style: TextStyle(decoration: i.done ? TextDecoration.lineThrough : null)),
                            secondary: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(i.time, style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
                              IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Удалить', onPressed: () => repo.deletePlanItem(i.id)),
                            ]),
                          ),
                      ]),
                    ),
                  ],
                ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'addPlan',
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('В план'),
      ),
    );
  }
}


/// Начать звонок в поездке: запись «звонок» уходит всем, сами сразу входим в комнату.
Future<void> startTripCall(BuildContext context, TripBundle b, {required bool video}) async {
  final s = App.read(context);
  final room = await s.calls.start(b, video: video, myName: s.myName);
  if (!context.mounted) return;
  Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen(tripId: b.trip.id, room: room, video: video, title: b.trip.name)));
}
