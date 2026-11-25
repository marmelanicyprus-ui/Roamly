import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../data.dart';
import '../invite_code.dart';

/// QR приглашения: ссылка roamly://join с данными поездки.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.tripId});
  final String tripId;
  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  TripBundle? _b;
  bool _child = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_b != null) return;
    App.read(context).repo.bundle(widget.tripId).then((b) {
      if (mounted) setState(() => _b = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Пригласить в поездку')),
      body: b == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('${b.trip.name} · ${b.members.length} участников',
                    textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                const SizedBox(height: 16),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Участник')),
                    ButtonSegment(value: true, label: Text('Ребёнок с телефоном')),
                  ],
                  selected: {_child},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _child = s.first),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: QrImageView(
                      data: buildInviteLink(b, asChild: _child),
                      size: 230,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Новый участник открывает Roamly → «Присоединиться» и сканирует этот код. Интернет не нужен: поездка копируется прямо из кода.',
                    textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
                const SizedBox(height: 24),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Готово'),
                ),
              ],
            ),
    );
  }
}
