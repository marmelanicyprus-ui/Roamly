// Чат беседы: сообщения, вложения, голосовые, ответы, реакции, правка и удаление,
// @упоминания, поиск, опросы. Используется во вкладках «Важное» и «Чат» и в личных чатах.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../calls/call_screen.dart';
import '../data.dart';
import '../geo/open_in.dart';
import '../media/media_service.dart';
import '../media/media_widgets.dart';
import '../money.dart';
import '../theme.dart';
import 'add_expense.dart';
import 'meeting.dart';
import 'trip.dart' show RepoListener;

const _reactionSet = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '👌'];

class ChatTab extends StatefulWidget {
  const ChatTab({super.key, required this.b, this.channel = 0, this.search});
  final TripBundle b;

  /// 0 — «Чат», 1 — «Важное».
  final int channel;

  /// Строка поиска (управляет экран поездки); пустая — показываем всё.
  final ValueNotifier<String>? search;
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> with RepoListener<ChatTab> {
  List<Message> _msgs = [];
  Map<String, Message> _byId = {};
  Map<String, Expense> _expenses = {};
  List<Receipt> _rcpt = [];
  int? _unsentSince;
  Map<String, Media> _media = {};
  Map<String, Map<String, String>> _local = {};
  Map<String, Map<String, String>> _reactions = {};
  Map<String, Poll> _polls = {};
  Map<String, Map<String, List<int>>> _votes = {};
  final _text = TextEditingController();
  final _scroll = ScrollController();

  Message? _replyTo;
  Message? _editing;

  // голосовое
  final _rec = AudioRecorder();
  bool _recording = false;
  DateTime? _recStart;
  Timer? _recTick;

  String get _query => widget.search?.value.trim().toLowerCase() ?? '';

  @override
  void initState() {
    super.initState();
    // пустое поле — вместо «отправить» кнопка микрофона; «@» — подсказка участников
    _text.addListener(() {
      if (mounted) setState(() {});
    });
    widget.search?.addListener(_onSearch);
  }

  void _onSearch() {
    if (mounted) setState(() {});
  }

  @override
  Future<void> reload() async {
    final id = widget.b.trip.id;
    final all = await repo.messages(id);
    final msgs = all.where((m) => m.channel == widget.channel).toList();
    final ex = await repo.expenses(id);
    final rcpt = await repo.receipts(id);
    final unsent = await repo.oldestUnsent(id);
    final media = await repo.mediaList(tripId: id);
    final local = await repo.localMediaFiles();
    final reactions = await repo.reactions(id);
    final polls = await repo.polls(id);
    final votes = await repo.votes(id);
    if (!mounted) return;
    setState(() {
      _msgs = msgs;
      _byId = {for (final m in all) m.id: m};
      _expenses = {for (final e in ex) e.id: e};
      _rcpt = rcpt;
      _unsentSince = unsent;
      _media = {for (final m in media) m.id: m};
      _local = local;
      _reactions = reactions;
      _polls = polls;
      _votes = votes;
    });
    // открыли чат — отметить «прочитано»
    final s = App.read(context);
    s.direct.markRead(widget.b);
    if (widget.channel == 1) repo.markImportantSeen(id);
  }

  @override
  void dispose() {
    widget.search?.removeListener(_onSearch);
    _recTick?.cancel();
    _rec.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------- отправка ----------------

  /// Упомянутые в тексте участники (@Имя) → их телефоны.
  List<String> _mentionedDevices(String text) {
    final lower = text.toLowerCase();
    return [
      for (final m in widget.b.members)
        if (!m.isMe && m.device != null && lower.contains('@${m.name.toLowerCase()}')) m.device!,
    ];
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    final editing = _editing;
    if (editing != null) {
      setState(() => _editing = null);
      if (t != editing.text) await repo.editMessage(editing, t);
      return;
    }
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await repo.sendText(
      Message(
        id: newId(),
        tripId: widget.b.trip.id,
        authorId: widget.b.me?.id,
        kind: MsgKind.text,
        text: t,
        created: DateTime.now(),
        channel: widget.channel,
        replyTo: reply?.id,
      ),
      at: _mentionedDevices(t),
    );
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
      ListTile(
        leading: const Icon(Icons.poll_outlined),
        title: const Text('Опрос'),
        onTap: () {
          Navigator.pop(context);
          _newPoll();
        },
      ),
    ]);
  }

  Future<void> _newPoll() async {
    final q = TextEditingController();
    final opts = [TextEditingController(), TextEditingController()];
    var multi = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Опрос'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: q,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Вопрос', hintText: 'Например, где ужинаем?'),
              ),
              for (var i = 0; i < opts.length; i++)
                TextField(
                  controller: opts[i],
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: 'Вариант ${i + 1}'),
                ),
              if (opts.length < 10)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => set(() => opts.add(TextEditingController())),
                    icon: const Icon(Icons.add),
                    label: const Text('Ещё вариант'),
                  ),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: multi,
                onChanged: (v) => set(() => multi = v ?? false),
                title: const Text('Можно выбрать несколько'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Создать')),
          ],
        ),
      ),
    );
    final question = q.text.trim();
    final options = [for (final o in opts) if (o.text.trim().isNotEmpty) o.text.trim()];
    if (ok != true || question.isEmpty || options.length < 2) return;
    await repo.addPoll(widget.b.trip.id, widget.b.me?.id, question, options, multi: multi, channel: widget.channel);
  }

  // ---------------- статусы доставки ----------------

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

  // ---------------- меню сообщения ----------------

  Media? _mediaOf(Message m) =>
      m.refId != null && m.refId!.startsWith('media:') ? _media[m.refId!.substring(6)] : null;

  bool _isPlainText(Message m) => m.kind == MsgKind.text && m.refId == null;

  /// Долгое нажатие: реакции, ответить, переслать в «Важное», изменить, удалить, статус.
  void _messageMenu(Message m, bool mine) {
    final myReaction = _reactions[m.id]?[widget.b.me?.id ?? ''];
    final media = _mediaOf(m);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 4, children: [
                for (final e in _reactionSet)
                  ChoiceChip(
                    label: Text(e, style: const TextStyle(fontSize: 20)),
                    selected: myReaction == e,
                    showCheckmark: false,
                    onSelected: (_) {
                      Navigator.pop(ctx);
                      repo.react(widget.b.trip.id, m.id, widget.b.me?.id, myReaction == e ? '' : e);
                    },
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Ответить'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _editing = null;
                  _replyTo = m;
                });
              },
            ),
            if (widget.channel == 0 && _isPlainText(m))
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
            if (mine && _isPlainText(m))
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Изменить'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _replyTo = null;
                    _editing = m;
                    _text.text = m.text;
                  });
                },
              ),
            if (mine && media != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Удалить у всех'),
                onTap: () {
                  Navigator.pop(ctx);
                  confirmDeleteMedia(context, media);
                },
              )
            else if (mine && m.kind == MsgKind.text)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Удалить у всех'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDelete(m);
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
      ),
    );
  }

  Future<void> _confirmDelete(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить у всех?'),
        content: const Text('Сообщение пропадёт у всех участников беседы.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) await repo.deleteMessage(m);
  }

  // ---------------- экран ----------------

  /// Подсказка участников после «@».
  List<Member> get _mentionSuggestions {
    final t = _text.text;
    final at = t.lastIndexOf('@');
    if (at < 0 || (at > 0 && t[at - 1] != ' ' && t[at - 1] != '\n')) return [];
    final part = t.substring(at + 1).toLowerCase();
    if (part.contains(' ') && !widget.b.members.any((m) => m.name.toLowerCase().startsWith(part))) return [];
    return widget.b.members.where((m) => !m.isMe && m.name.toLowerCase().startsWith(part)).take(5).toList();
  }

  void _insertMention(Member m) {
    final t = _text.text;
    final at = t.lastIndexOf('@');
    final next = '${t.substring(0, at)}@${m.name} ';
    _text.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length));
  }

  String _snippet(Message m) {
    final media = _mediaOf(m);
    if (media != null) return media.label;
    if (m.refId != null && m.refId!.startsWith('poll:')) return m.text;
    return m.text.replaceAll('\n', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final t = widget.b.trip;
    final q = _query;
    final shown = q.isEmpty ? _msgs : _msgs.where((m) => m.text.toLowerCase().contains(q)).toList();
    final items = shown.reversed.toList();
    final suggestions = _recording ? <Member>[] : _mentionSuggestions;
    return Container(
      color: dark ? const Color(0xFF0D1412) : const Color(0xFFEEF2F0),
      child: Column(children: [
        if (t.meetingText != null && q.isEmpty)
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
                    onPressed: () => showOpenIn(context, t.meetingLat!, t.meetingLng!, t.meetingText!),
                  ),
                IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Изменить', onPressed: _setMeeting),
              ]),
            ),
          ),
        if (q.isNotEmpty)
          Material(
            color: cs.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                Icon(Icons.search, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text('Найдено: ${shown.length}', style: TextStyle(color: cs.onSurfaceVariant))),
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
        if (suggestions.isNotEmpty)
          Material(
            color: cs.surface,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final m in suggestions)
                ListTile(
                  dense: true,
                  leading: Avatar(m.name, size: 28),
                  title: Text(m.name),
                  onTap: () => _insertMention(m),
                ),
            ]),
          ),
        if (_replyTo != null || _editing != null) _composeBanner(cs),
        Material(
          color: cs.surface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
              child: _recording
                  ? _recordingRow(cs)
                  : Row(children: [
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
                      if (_text.text.trim().isEmpty && _editing == null)
                        IconButton.filled(icon: const Icon(Icons.mic), tooltip: 'Голосовое', onPressed: _startVoice)
                      else
                        IconButton.filled(
                          icon: Icon(_editing != null ? Icons.check : Icons.send),
                          tooltip: _editing != null ? 'Сохранить' : 'Отправить',
                          onPressed: _send,
                        ),
                    ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _composeBanner(ColorScheme cs) {
    final m = _editing ?? _replyTo!;
    final editing = _editing != null;
    final author = widget.b.member(m.authorId)?.name ?? '';
    return Material(
      color: cs.surface,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
        child: Row(children: [
          Icon(editing ? Icons.edit_outlined : Icons.reply, color: cs.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: cs.primary, width: 3))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(editing ? 'Изменить сообщение' : author,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
                Text(_snippet(m), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              ]),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              if (editing) _text.clear();
              _editing = null;
              _replyTo = null;
            }),
          ),
        ]),
      ),
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

  /// Текст с выделенными @упоминаниями и найденным словом.
  Widget _richText(String text, ColorScheme cs) {
    final q = _query;
    final names = [for (final m in widget.b.members) '@${m.name}'];
    final spans = <TextSpan>[];
    var i = 0;
    final lower = text.toLowerCase();
    while (i < text.length) {
      String? hit;
      for (final n in names) {
        if (lower.startsWith(n.toLowerCase(), i)) {
          hit = text.substring(i, i + n.length);
          break;
        }
      }
      if (hit != null) {
        spans.add(TextSpan(text: hit, style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)));
        i += hit.length;
        continue;
      }
      if (q.isNotEmpty && lower.startsWith(q, i)) {
        spans.add(TextSpan(text: text.substring(i, i + q.length), style: TextStyle(backgroundColor: cs.tertiaryContainer)));
        i += q.length;
        continue;
      }
      spans.add(TextSpan(text: text[i]));
      i++;
    }
    return Text.rich(TextSpan(children: spans), style: const TextStyle(fontSize: 15, height: 1.3));
  }

  Widget _quote(Message m, ColorScheme cs) {
    final orig = _byId[m.replyTo];
    final author = orig == null ? '' : (widget.b.member(orig.authorId)?.name ?? '');
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: cs.primary, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (author.isNotEmpty) Text(author, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
        Text(orig == null ? 'Сообщение удалено' : _snippet(orig),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _reactionRow(Message m, ColorScheme cs) {
    final r = _reactions[m.id];
    if (r == null || r.isEmpty) return const SizedBox.shrink();
    final counts = <String, int>{};
    for (final e in r.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final mine = r[widget.b.me?.id ?? ''];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(spacing: 4, runSpacing: 4, children: [
        for (final e in counts.entries)
          GestureDetector(
            onTap: () => repo.react(widget.b.trip.id, m.id, widget.b.me?.id, mine == e.key ? '' : e.key),
            onLongPress: () => _showReactors(m),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: mine == e.key ? cs.primaryContainer : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('${e.key} ${e.value}', style: const TextStyle(fontSize: 13)),
            ),
          ),
      ]),
    );
  }

  void _showReactors(Message m) {
    final r = _reactions[m.id] ?? {};
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final e in r.entries)
            ListTile(
              leading: Avatar(widget.b.member(e.key)?.name ?? '?', size: 32),
              title: Text(widget.b.member(e.key)?.name ?? '—'),
              trailing: Text(e.value, style: const TextStyle(fontSize: 22)),
            ),
        ]),
      ),
    );
  }

  Widget _pollBody(Poll p, ColorScheme cs) {
    final votes = _votes[p.id] ?? {};
    final me = widget.b.me?.id ?? '';
    final mine = votes[me] ?? const <int>[];
    final counts = List<int>.filled(p.options.length, 0);
    for (final v in votes.values) {
      for (final i in v) {
        if (i >= 0 && i < counts.length) counts[i]++;
      }
    }
    final voters = votes.values.where((v) => v.isNotEmpty).length;
    return SizedBox(
      width: 260,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.poll_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(child: Text(p.question, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
        ]),
        if (p.multi) Text('можно несколько', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 6),
        for (var i = 0; i < p.options.length; i++)
          InkWell(
            onTap: () {
              final next = p.multi ? (mine.contains(i) ? (mine.toList()..remove(i)) : [...mine, i]) : (mine.contains(i) ? <int>[] : [i]);
              repo.vote(widget.b.trip.id, p.id, widget.b.me?.id, next);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(mine.contains(i) ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text(p.options[i])),
                  Text('${counts[i]}', style: TextStyle(color: cs.onSurfaceVariant)),
                ]),
                const SizedBox(height: 3),
                LinearProgressIndicator(
                  value: voters == 0 ? 0 : counts[i] / voters,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => _showVoters(p),
          child: Text('Проголосовали: $voters', style: TextStyle(fontSize: 12, color: cs.primary)),
        ),
      ]),
    );
  }

  void _showVoters(Poll p) {
    final votes = _votes[p.id] ?? {};
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(p.question, style: const TextStyle(fontWeight: FontWeight.w600))),
          for (final e in votes.entries)
            if (e.value.isNotEmpty)
              ListTile(
                leading: Avatar(widget.b.member(e.key)?.name ?? '?', size: 32),
                title: Text(widget.b.member(e.key)?.name ?? '—'),
                subtitle: Text([for (final i in e.value) if (i < p.options.length) p.options[i]].join(', ')),
              ),
        ]),
      ),
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
    final me = widget.b.me;
    final mentionsMe = !mine && me != null && m.text.toLowerCase().contains('@${me.name.toLowerCase()}');
    final bg = mine ? (dark ? const Color(0xFF14544C) : const Color(0xFFD7EEE9)) : cs.surface;
    final media = _mediaOf(m);
    final poll = m.refId != null && m.refId!.startsWith('poll:') ? _polls[m.refId!.substring(5)] : null;
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
    } else if (media != null) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 2),
        MediaBubble(media: media, local: _local[media.id] ?? const {}, b: widget.b),
        if (media.caption != null && media.caption!.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(media.caption!, style: const TextStyle(fontSize: 15))),
      ]);
    } else if (poll != null) {
      body = _pollBody(poll, cs);
    } else {
      body = _richText(m.text, cs);
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _messageMenu(m, mine),
        onTap: mine && poll == null ? () => _showStatus(m) : null,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 290),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: bg,
            border: mentionsMe ? Border.all(color: cs.primary, width: 1.5) : null,
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
            if (m.replyTo != null) _quote(m, cs),
            body,
            _reactionRow(m, cs),
            Align(
              alignment: Alignment.centerRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (m.edited > 0) Text('изменено · ', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
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
