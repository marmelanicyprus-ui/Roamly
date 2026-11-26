// Контакты: все, с кем вы были в одной беседе, + приглашения в Roamly по ссылке.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../calls/call_screen.dart';
import '../data.dart';
import '../theme.dart';
import 'trip.dart';

const _apkLink = 'https://github.com/marmelanicyprus-ui/Roamly/releases/download/android/roamly.apk';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> with RepoListener<ContactsScreen> {
  List<Contact> _list = [];
  bool _loaded = false;

  @override
  Future<void> reload() async {
    final list = await repo.contacts();
    if (mounted) {
      setState(() {
        _list = list;
        _loaded = true;
      });
    }
  }

  Future<void> _open(Contact c, {bool call = false}) async {
    if (c.directTripId != null) {
      final s = App.read(context);
      final nav = Navigator.of(context);
      if (call) {
        final b = await s.repo.bundle(c.directTripId!);
        final room = await s.calls.start(b, video: false, myName: s.myName);
        nav.push(MaterialPageRoute(builder: (_) => CallScreen(tripId: b.trip.id, room: room, video: false, title: c.name)));
      } else {
        nav.push(MaterialPageRoute(builder: (_) => TripScreen(tripId: c.directTripId!)));
      }
      return;
    }
    if (c.viaTripId == null || c.viaMemberId == null) return;
    if (c.pub == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Ключ телефона ${c.name} ещё не пришёл. Пусть ${c.name} обновит Roamly до 0.5.1, откроет его '
            'рядом с вами или в интернете и нажмёт ⟳ в Контактах.'),
      ));
      return;
    }
    await openDirect(context, viaTripId: c.viaTripId!, memberId: c.viaMemberId!, call: call);
  }

  Future<void> _invite() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Пригласить в Roamly'),
        content: TextField(
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Как зовут', hintText: 'Например, Иван'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Дальше')),
        ],
      ),
    );
    final n = name.text.trim();
    if (ok != true || n.isEmpty || !mounted) return;
    final s = App.read(context);
    final link = await s.direct.inviteLink(n, 'EUR');
    final text = 'Привет! Давай общаться в Roamly offline — сообщения и звонки, рядом работает даже без интернета.\n'
        '1) Установи приложение: $_apkLink\n'
        '2) Открой эту ссылку (или отсканируй в приложении): $link';
    if (!mounted) return;
    _share(n, text, link);
  }

  Future<void> _refresh() async {
    final s = App.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await s.direct.ensureIdent(force: true);
      s.server.poke();
      messenger.showSnackBar(SnackBar(content: Text('Ключ отправлен в беседы: $n. Остальные увидят вас, когда будут на связи.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(duration: const Duration(seconds: 8), content: Text('Ошибка ключа: $e')));
    }
    reload();
  }

  void _share(String name, String text, String link) {
    Future<void> go(Uri u) async {
      if (!await launchUrl(u, mode: LaunchMode.externalApplication) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть приложение')));
      }
    }

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text('Приглашение для $name', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Ссылка личная: кто её откроет, попадёт в личный чат с вами. Отправьте её только этому человеку.'),
          ),
          ListTile(
            leading: const Icon(Icons.sms_outlined),
            title: const Text('SMS'),
            onTap: () => go(Uri(scheme: 'sms', queryParameters: {'body': text})),
          ),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: const Text('WhatsApp'),
            onTap: () => go(Uri.https('wa.me', '/', {'text': text})),
          ),
          ListTile(
            leading: const Icon(Icons.send_outlined),
            title: const Text('Telegram'),
            onTap: () => go(Uri.https('t.me', '/share/url', {'url': _apkLink, 'text': text})),
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Скопировать текст'),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _diag(ColorScheme cs) {
    final err = App.read(context).direct.lastError;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Text(
        err == null ? 'Ключ этого телефона в порядке' : 'Ошибка ключа: $err',
        style: TextStyle(fontSize: 12, color: err == null ? cs.onSurfaceVariant : cs.error),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Контакты'), actions: [
        IconButton(icon: const Icon(Icons.refresh), tooltip: 'Отправить свой ключ заново', onPressed: _refresh),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _invite,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Пригласить'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                        'Здесь появятся все, с кем вы в одной поездке, и те, кто принял ваше приглашение. '
                        'Им можно написать и позвонить лично.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                      _diag(cs),
                    ]),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: _list.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (_, i) {
                    if (i == _list.length) return _diag(cs);
                    final c = _list[i];
                    return ListTile(
                      leading: Avatar(c.name, size: 44),
                      title: Text(c.name),
                      subtitle: Text(c.directTripId != null
                          ? 'личный чат'
                          : c.pub != null
                              ? 'из общей поездки · можно писать'
                              : c.device != null
                                  ? 'ждём ключ с его телефона'
                                  : 'телефон пока не на связи'),
                      onTap: () => _open(c),
                      trailing: IconButton(icon: const Icon(Icons.call_outlined), tooltip: 'Позвонить', onPressed: () => _open(c, call: true)),
                    );
                  },
                ),
    );
  }
}
