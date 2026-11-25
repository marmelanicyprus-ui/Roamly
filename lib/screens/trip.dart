import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../calls/call_screen.dart';
import '../data.dart';
import '../money.dart';
import '../sync/sync_badge.dart';
import '../theme.dart';
import 'add_expense.dart';
import 'home.dart' show dateRange;
import 'invite.dart';
import 'meeting.dart';
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

  @override
  Future<void> reload() async {
    try {
      final b = await repo.bundle(widget.tripId);
      if (mounted) setState(() => _b = b);
    } catch (_) {
      // поездку удалили
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final cs = Theme.of(context).colorScheme;
    final sos = sosColor(context);
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
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
            PopupMenuButton<bool>(
              icon: const Icon(Icons.call_outlined),
              tooltip: 'Позвонить группе',
              onSelected: (video) => startTripCall(context, b, video: video),
              itemBuilder: (_) => const [
                PopupMenuItem(value: false, child: ListTile(leading: Icon(Icons.call), title: Text('Звонок'))),
                PopupMenuItem(value: true, child: ListTile(leading: Icon(Icons.videocam), title: Text('Видеозвонок'))),
              ],
            ),
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
                if (v == 'invite') {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => InviteScreen(tripId: b.trip.id)));
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
                const PopupMenuItem(value: 'invite', child: Text('Пригласить по QR')),
                PopupMenuItem(value: 'archive', child: Text(b.trip.archived ? 'Вернуть из архива' : 'В архив')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить поездку')),
              ],
            ),
          ],
          bottom: const TabBar(
            isScrollable: false,
            labelPadding: EdgeInsets.zero,
            tabs: [Tab(text: 'Чат'), Tab(text: 'Карта'), Tab(text: 'Расходы'), Tab(text: 'Фото'), Tab(text: 'План')],
          ),
        ),
        body: TabBarView(children: [
          ChatTab(b: b),
          MapTab(b: b),
          ExpensesTab(b: b),
          const _Soon(icon: Icons.photo_library_outlined, title: 'Фото', text: 'Общий альбом и передача фото рядом — в следующей сборке.'),
          PlanTab(b: b),
        ]),
      ),
    );
  }
}

class _Soon extends StatelessWidget {
  const _Soon({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// ================= ЧАТ =================

class ChatTab extends StatefulWidget {
  const ChatTab({super.key, required this.b});
  final TripBundle b;
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> with RepoListener<ChatTab> {
  List<Message> _msgs = [];
  Map<String, Expense> _expenses = {};
  final _text = TextEditingController();
  final _scroll = ScrollController();

  @override
  Future<void> reload() async {
    final msgs = await repo.messages(widget.b.trip.id);
    final ex = await repo.expenses(widget.b.trip.id);
    if (!mounted) return;
    setState(() {
      _msgs = msgs;
      _expenses = {for (final e in ex) e.id: e};
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    await repo.addMessage(Message(
      id: newId(),
      tripId: widget.b.trip.id,
      authorId: widget.b.me?.id,
      kind: MsgKind.text,
      text: t,
      created: DateTime.now(),
    ));
  }

  Future<void> _setMeeting() => editMeeting(context, widget.b);

  void _attach() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Трата'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => AddExpenseScreen(tripId: widget.b.trip.id)));
            },
          ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Точка сбора'),
            onTap: () {
              Navigator.pop(ctx);
              _setMeeting();
            },
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.photo_outlined),
            title: Text('Фото, бронь, голосование'),
            subtitle: Text('в следующей сборке'),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final t = widget.b.trip;
    final items = _msgs.reversed.toList();
    return Container(
      color: dark ? const Color(0xFF0D1412) : const Color(0xFFEEF2F0),
      child: Column(children: [
        if (t.meetingText != null)
          Material(
            color: cs.surface,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.flag_outlined, color: cs.primary),
              title: Text('Точка сбора · ${t.meetingTime ?? ''}', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
              subtitle: Text(t.meetingText!),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (t.meetingLat != null)
                  IconButton(
                    icon: const Icon(Icons.directions),
                    tooltip: 'Маршрут',
                    onPressed: () => openInMaps(t.meetingLat!, t.meetingLng!, t.meetingText!),
                  ),
                IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Изменить', onPressed: _setMeeting),
              ]),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            itemCount: items.length,
            itemBuilder: (_, i) => _bubble(items[i]),
          ),
        ),
        Material(
          color: cs.surface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
              child: Row(children: [
                IconButton(icon: const Icon(Icons.attach_file), tooltip: 'Прикрепить', onPressed: _attach),
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Сообщение',
                      filled: true,
                      fillColor: cs.surfaceContainerHighest,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(icon: const Icon(Icons.send), tooltip: 'Отправить', onPressed: _send),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(Message m) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final time = DateFormat('HH:mm').format(m.created);
    final call = m.refId != null && m.refId!.startsWith('call:') ? m.refId!.split(':') : null;
    if (m.kind == MsgKind.system && call != null && call.length == 3) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ActionChip(
            avatar: Icon(call[2] == '1' ? Icons.videocam : Icons.call, color: cs.primary),
            label: Text('${m.text.replaceAll(' · нажмите, чтобы присоединиться', '')} · $time · войти'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => CallScreen(tripId: widget.b.trip.id, room: call[1], video: call[2] == '1', title: widget.b.trip.name)),
            ),
          ),
        ),
      );
    }
    if (m.kind == MsgKind.system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: cs.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(10)),
          child: Text(m.text, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ),
      );
    }
    final author = widget.b.member(m.authorId);
    final mine = author?.isMe ?? false;
    final bg = mine ? (dark ? const Color(0xFF14544C) : const Color(0xFFD7EEE9)) : cs.surface;
    Widget body;
    if (m.kind == MsgKind.expense) {
      final e = _expenses[m.refId];
      if (e == null) return const SizedBox.shrink();
      final myWallet = widget.b.me?.walletId;
      final myPart = myWallet == null ? 0 : (e.parts[myWallet] ?? 0);
      body = SizedBox(
        width: 260,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${author?.name ?? '—'} · трата', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: avatarColor(author?.name ?? ''))),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: Text(e.title, style: const TextStyle(fontWeight: FontWeight.w500))),
            Text(money(e.tripCents, widget.b.trip.currency), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ]),
          if (e.currency != widget.b.trip.currency)
            Text('оплачено ${money(e.amountCents, e.currency)}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const Divider(height: 14),
          Text('Доля вашего кошелька ${money(myPart, widget.b.trip.currency)}', style: const TextStyle(fontSize: 13)),
        ]),
      );
    } else if (m.kind == MsgKind.meeting) {
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.flag_outlined, size: 18, color: cs.primary),
        const SizedBox(width: 6),
        Flexible(child: Text('Точка сбора: ${m.text}', style: const TextStyle(fontSize: 15))),
      ]);
    } else {
      body = Text(m.text, style: const TextStyle(fontSize: 15, height: 1.3));
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 290),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (!mine && m.kind != MsgKind.expense)
            Text(author?.name ?? '—', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: avatarColor(author?.name ?? ''))),
          body,
          Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(time, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              if (mine) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Сохранено на телефоне, ждёт отправки',
                  child: Icon(Icons.schedule, size: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
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
