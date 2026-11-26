import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../calls/call_screen.dart';
import '../data.dart';
import '../media/media_service.dart';
import '../media/media_widgets.dart';
import '../money.dart';
import '../sync/sync_badge.dart';
import '../theme.dart';
import 'add_expense.dart';
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

  @override
  Future<void> reload() async {
    try {
      final b = await repo.bundle(widget.tripId);
      final unread = await repo.unreadImportant(widget.tripId);
      if (mounted) {
        setState(() {
          _b = b;
          _unreadImp = unread;
        });
      }
    } catch (_) {
      // поездку удалили
    }
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
      appBar: AppBar(
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
              if (v == 'delete') {
                await repo.deleteTrip(b.trip.id);
                if (mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Удалить чат с этого телефона'))],
          ),
        ],
      ),
      body: ChatTab(b: b),
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
          ChatTab(b: b, channel: 1),
          ChatTab(b: b),
          MapTab(b: b),
          ExpensesTab(b: b),
          PhotosTab(b: b),
          PlanTab(b: b),
        ]),
      ),
    );
  }
}

// ================= ЧАТ =================

class ChatTab extends StatefulWidget {
  const ChatTab({super.key, required this.b, this.channel = 0});
  final TripBundle b;

  /// 0 — «Чат», 1 — «Важное».
  final int channel;
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> with RepoListener<ChatTab> {
  List<Message> _msgs = [];
  Map<String, Expense> _expenses = {};
  List<Receipt> _rcpt = [];
  int? _unsentSince;
  Map<String, Media> _media = {};
  Map<String, Map<String, String>> _local = {};
  final _text = TextEditingController();
  final _scroll = ScrollController();

  // голосовое
  final _rec = AudioRecorder();
  bool _recording = false;
  DateTime? _recStart;
  Timer? _recTick;

  @override
  void initState() {
    super.initState();
    // пустое поле — вместо «отправить» кнопка микрофона
    _text.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Future<void> reload() async {
    final id = widget.b.trip.id;
    final msgs = (await repo.messages(id)).where((m) => m.channel == widget.channel).toList();
    final ex = await repo.expenses(id);
    final rcpt = await repo.receipts(id);
    final unsent = await repo.oldestUnsent(id);
    final media = await repo.mediaList(tripId: id);
    final local = await repo.localMediaFiles();
    if (!mounted) return;
    setState(() {
      _msgs = msgs;
      _expenses = {for (final e in ex) e.id: e};
      _rcpt = rcpt;
      _unsentSince = unsent;
      _media = {for (final m in media) m.id: m};
      _local = local;
    });
    // открыли чат — отметить «прочитано»
    final s = App.read(context);
    s.direct.markRead(widget.b);
    if (widget.channel == 1) repo.markImportantSeen(id);
  }

  @override
  void dispose() {
    _recTick?.cancel();
    _rec.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startVoice() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await _rec.hasPermission()) {
        messenger.showSnackBar(const SnackBar(content: Text('Нужно разрешение на микрофон')));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = pth.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000, sampleRate: 22050, numChannels: 1),
        path: path,
      );
      _recStart = DateTime.now();
      _recTick = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (!mounted) return;
        setState(() {});
        if (DateTime.now().difference(_recStart!) >= const Duration(minutes: 10)) _stopVoice(send: true);
      });
      setState(() => _recording = true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Запись не началась: $e')));
    }
  }

  Future<void> _stopVoice({required bool send}) async {
    if (!_recording) return;
    _recTick?.cancel();
    final dur = DateTime.now().difference(_recStart!).inMilliseconds;
    setState(() => _recording = false);
    if (!send || dur < 700) {
      await _rec.cancel();
      return;
    }
    final path = await _rec.stop();
    if (path == null || !mounted) return;
    try {
      await App.read(context).media.addVoice(widget.b, path, dur, channel: widget.channel);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправилось: $e')));
    }
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
      channel: widget.channel,
    ));
  }

  /// Статус своего сообщения: 0 — ждёт отправки, 1 — ушло, 2 — доставлено всем, 3 — прочитано всеми.
  int _status(Message m) {
    final t = m.created.millisecondsSinceEpoch;
    final myDev = repo.deviceId;
    final others = <String>{
      for (final x in widget.b.members)
        if (!x.isMe && x.device != null && x.device != myDev) x.device!,
      for (final r in _rcpt)
        if (r.device != myDev) r.device,
    };
    final got = _rcpt.where((r) => r.device != myDev && r.delivered >= t).map((r) => r.device).toSet();
    final read = _rcpt.where((r) => r.device != myDev && r.read >= t).map((r) => r.device).toSet();
    if (others.isNotEmpty && others.every(read.contains)) return 3;
    if (others.isNotEmpty && others.every(got.contains)) return 2;
    if (got.isNotEmpty) return 1;
    final u = _unsentSince;
    return (u != null && u <= t + 1000) ? 0 : 1;
  }

  Widget _statusIcon(Message m, ColorScheme cs) {
    final st = _status(m);
    final (icon, color, tip) = switch (st) {
      0 => (Icons.schedule, cs.onSurfaceVariant, 'Сохранено на телефоне, ждёт отправки'),
      1 => (Icons.done, cs.onSurfaceVariant, 'Отправлено'),
      2 => (Icons.done_all, cs.onSurfaceVariant, 'Доставлено всем'),
      _ => (Icons.done_all, cs.primary, 'Прочитано всеми'),
    };
    return Tooltip(message: tip, child: Icon(icon, size: 14, color: color));
  }

  /// Кому доставлено и кто прочитал.
  void _showStatus(Message m) {
    final t = m.created.millisecondsSinceEpoch;
    final fmt = DateFormat('d MMM HH:mm', 'ru');
    final byDevice = {for (final r in _rcpt) r.device: r};
    final people = widget.b.members.where((x) => !x.isMe).toList();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Статус сообщения', style: TextStyle(fontWeight: FontWeight.w600))),
          for (final p in people) _statusTile(p, t, fmt, byDevice),
        ]),
      ),
    );
  }

  Widget _statusTile(Member p, int t, DateFormat fmt, Map<String, Receipt> byDevice) {
    final r = p.device == null ? _rcpt.where((x) => x.memberId == p.id).firstOrNull : byDevice[p.device];
    final String line;
    final IconData icon;
    if (r != null && r.read >= t) {
      line = 'прочитано · ${fmt.format(DateTime.fromMillisecondsSinceEpoch(r.read))}';
      icon = Icons.done_all;
    } else if (r != null && r.delivered >= t) {
      line = 'доставлено · ${fmt.format(DateTime.fromMillisecondsSinceEpoch(r.delivered))}';
      icon = Icons.done_all;
    } else {
      line = p.device == null ? 'нет приложения или ещё не вступил(а)' : 'ещё не доставлено';
      icon = Icons.schedule;
    }
    return ListTile(leading: Avatar(p.name, size: 36), title: Text(p.name), subtitle: Text(line), trailing: Icon(icon, size: 18));
  }

  /// Долгое нажатие: переслать в «Важное», статус.
  void _messageMenu(Message m, bool mine) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.channel == 0 && m.kind == MsgKind.text && m.refId == null)
            ListTile(
              leading: const Icon(Icons.priority_high),
              title: const Text('Переслать в «Важное»'),
              onTap: () async {
                Navigator.pop(ctx);
                final author = widget.b.member(m.authorId);
                await repo.addMessage(Message(
                  id: newId(),
                  tripId: widget.b.trip.id,
                  authorId: widget.b.me?.id,
                  kind: MsgKind.text,
                  text: author == null || author.isMe ? m.text : '${author.name}: ${m.text}',
                  created: DateTime.now(),
                  channel: 1,
                ));
              },
            ),
          if (mine && m.refId != null && m.refId!.startsWith('media:') && _media[m.refId!.substring(6)] != null)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Удалить у всех'),
              onTap: () {
                Navigator.pop(ctx);
                confirmDeleteMedia(context, _media[m.refId!.substring(6)]!);
              },
            ),
          if (mine)
            ListTile(
              leading: const Icon(Icons.done_all),
              title: const Text('Кому доставлено'),
              onTap: () {
                Navigator.pop(ctx);
                _showStatus(m);
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _setMeeting() => editMeeting(context, widget.b);

  void _attach() {
    final direct = widget.b.trip.isDirect;
    showAttachSheet(context, widget.b, channel: widget.channel, extra: [
      if (!direct)
        ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('Трата'),
          onTap: () {
            Navigator.pop(context);
            Navigator.push(context, MaterialPageRoute(builder: (_) => AddExpenseScreen(tripId: widget.b.trip.id)));
          },
        ),
      if (!direct)
        ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: const Text('Точка сбора'),
          onTap: () {
            Navigator.pop(context);
            _setMeeting();
          },
        ),
    ]);
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
              child: _recording ? _recordingRow(cs) : Row(children: [
                IconButton(icon: const Icon(Icons.attach_file), tooltip: 'Прикрепить', onPressed: _attach),
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: widget.channel == 1 ? 'Важное для всех: место, время, изменения' : 'Сообщение',
                      filled: true,
                      fillColor: cs.surfaceContainerHighest,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 6),
                if (_text.text.trim().isEmpty)
                  IconButton.filled(icon: const Icon(Icons.mic), tooltip: 'Голосовое', onPressed: _startVoice)
                else
                  IconButton.filled(icon: const Icon(Icons.send), tooltip: 'Отправить', onPressed: _send),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _recordingRow(ColorScheme cs) {
    final ms = _recStart == null ? 0 : DateTime.now().difference(_recStart!).inMilliseconds;
    return Row(children: [
      IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Отменить', onPressed: () => _stopVoice(send: false)),
      const SizedBox(width: 4),
      Icon(Icons.fiber_manual_record, color: (ms ~/ 600).isEven ? Colors.red : Colors.red.shade200, size: 14),
      const SizedBox(width: 8),
      Text(formatDur(ms), style: const TextStyle(fontSize: 16)),
      const SizedBox(width: 12),
      Expanded(child: Text('Идёт запись голосового', style: TextStyle(color: cs.onSurfaceVariant))),
      IconButton.filled(icon: const Icon(Icons.send), tooltip: 'Отправить', onPressed: () => _stopVoice(send: true)),
    ]);
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
    } else if (m.refId != null && m.refId!.startsWith('media:') && _media[m.refId!.substring(6)] != null) {
      final md = _media[m.refId!.substring(6)]!;
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 2),
        MediaBubble(media: md, local: _local[md.id] ?? const {}, b: widget.b),
        if (md.caption != null && md.caption!.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(md.caption!, style: const TextStyle(fontSize: 15))),
      ]);
    } else {
      body = Text(m.text, style: const TextStyle(fontSize: 15, height: 1.3));
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _messageMenu(m, mine),
        onTap: mine ? () => _showStatus(m) : null,
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
                _statusIcon(m, cs),
              ],
            ]),
          ),
        ]),
      ),
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
