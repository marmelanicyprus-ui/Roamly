import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_state.dart';
import '../data.dart';
import '../invite_code.dart';
import '../theme.dart';
import 'home.dart' show dateRange;
import 'trip.dart';

/// Камера для QR-приглашения.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _handled = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      final p = parseInvite(raw);
      if (p != null) {
        _handled = true;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => JoinScreen(payload: p)));
        return;
      }
      setState(() => _hint = 'Это не приглашение Roamly');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Сканировать приглашение'),
        actions: [
          IconButton(
            tooltip: 'Фонарик',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(12)),
            child: Text(
              _hint ?? 'Наведите камеру на QR-код в телефоне организатора',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Подтверждение: кто вы в этой поездке.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, required this.payload});
  final InvitePayload payload;
  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  String? _picked; // id участника из списка, или null — я новый
  bool _exists = false;
  bool _checked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checked) return;
    _checked = true;
    final s = App.read(context);
    s.repo.hasTrip(widget.payload.trip.id).then((v) {
      if (!mounted) return;
      setState(() {
        _exists = v;
        // если имя совпадает с участником — предлагаем его
        final same = widget.payload.members.where((m) => m.name.toLowerCase() == s.myName.toLowerCase()).toList();
        _picked = same.isNotEmpty ? same.first.id : null;
      });
    });
  }

  Future<void> _join() async {
    final s = App.read(context);
    final p = widget.payload;
    final members = [for (final m in p.members) Member(id: m.id, tripId: m.tripId, name: m.name, isChild: m.isChild, walletId: m.walletId)];
    final wallets = [...p.wallets];
    Wallet? newWallet;
    Member? newMember;
    if (_picked != null) {
      members.firstWhere((m) => m.id == _picked).isMe = true;
    } else {
      newWallet = Wallet(id: newId(), tripId: p.trip.id, name: 'Кошелёк: ${s.myName}');
      newMember = Member(id: newId(), tripId: p.trip.id, name: s.myName, isChild: p.asChild, walletId: newWallet.id, isMe: true);
      wallets.add(newWallet);
      members.add(newMember);
    }
    await s.repo.joinTrip(p.trip, wallets, members, s.myName, newWallet: newWallet, newMember: newMember);
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: p.trip.id)));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final cs = Theme.of(context).colorScheme;
    final me = App.of(context).myName;
    return Scaffold(
      appBar: AppBar(title: const Text('Присоединиться')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: CircleAvatar(radius: 26, backgroundColor: tripColor(p.trip.type), child: Icon(tripIcon(p.trip.type), color: Colors.white)),
              title: Text(p.trip.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
              subtitle: Text('${p.trip.type.label} · ${dateRange(p.trip.start, p.trip.end)} · ${p.members.length} участников'),
            ),
          ),
          const SizedBox(height: 16),
          if (_exists)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Эта поездка уже есть на телефоне.'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => TripScreen(tripId: p.trip.id))),
                    child: const Text('Открыть поездку'),
                  ),
                ]),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text('Кто вы в этой поездке?', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface)),
            ),
            Card(
              child: Column(children: [
                for (final m in p.members)
                  ListTile(
                    leading: Avatar(m.name, size: 36),
                    title: Text(m.name),
                    subtitle: m.isChild ? const Text('ребёнок') : null,
                    trailing: _picked == m.id ? Icon(Icons.check_circle, color: cs.primary) : const Icon(Icons.radio_button_unchecked),
                    onTap: () => setState(() => _picked = m.id),
                  ),
                ListTile(
                  leading: const CircleAvatar(radius: 18, child: Icon(Icons.person_add_alt, size: 18)),
                  title: Text('Меня нет в списке — добавить «$me»'),
                  subtitle: Text(p.asChild ? 'как ребёнка со своим телефоном' : 'со своим кошельком'),
                  trailing: _picked == null ? Icon(Icons.check_circle, color: cs.primary) : const Icon(Icons.radio_button_unchecked),
                  onTap: () => setState(() => _picked = null),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Text(
              'Поездка копируется на ваш телефон. Дальше чат, траты и план сами обмениваются с телефонами группы, когда они рядом.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
      bottomNavigationBar: _exists
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  onPressed: _join,
                  child: const Text('Присоединиться'),
                ),
              ),
            ),
    );
  }
}
