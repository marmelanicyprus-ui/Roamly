import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data.dart';
import 'home.dart' show dateRange;

/// SOS: звонок 112 — штатно через телефон. Тревога группе по Bluetooth — в следующей сборке.
class SosScreen extends StatefulWidget {
  const SosScreen({super.key, required this.tripId});
  final String tripId;
  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  TripBundle? _b;
  List<PlanItem> _plan = [];
  final _started = DateTime.now();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_b != null) return;
    final repo = App.read(context).repo;
    repo.bundle(widget.tripId).then((b) async {
      final plan = await repo.plan(widget.tripId);
      if (mounted) setState(() {
        _b = b;
        _plan = plan;
      });
    });
  }

  Future<void> _call() async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: '112'));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть звонилку — наберите 112 вручную')));
    }
  }

  String _package() {
    final b = _b!;
    final buf = StringBuffer()
      ..writeln('SOS · Roamly offline')
      ..writeln('Время: ${DateFormat('d MMMM y, HH:mm', 'ru').format(DateTime.now())}')
      ..writeln('Поездка: ${b.trip.name} (${b.trip.type.label}), ${dateRange(b.trip.start, b.trip.end)}')
      ..writeln('Группа: ${b.adults} взрослых, ${b.children} детей')
      ..writeln('Участники: ${b.members.map((m) => m.isChild ? '${m.name} (ребёнок)' : m.name).join(', ')}');
    if (b.trip.meetingText != null) buf.writeln('Точка сбора: ${b.trip.meetingText} ${b.trip.meetingTime ?? ''}');
    if (_plan.isNotEmpty) {
      buf.writeln('План маршрута:');
      for (final p in _plan.take(12)) {
        buf.writeln('  ${DateFormat('d MMM', 'ru').format(p.day)} ${p.time} — ${p.title}');
      }
    }
    buf.writeln('Координаты: появятся в следующей сборке');
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    const red = Color(0xFFB91C1C);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: red,
        foregroundColor: Colors.white,
        title: Text('SOS включён · ${DateFormat('HH:mm').format(_started)}'),
      ),
      body: b == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: red, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(60)),
                  icon: const Icon(Icons.call),
                  label: const Text('Позвонить 112', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  onPressed: _call,
                ),
                const SizedBox(height: 8),
                Text('Звонок идёт штатно через телефон. Координаты оператору телефон передаёт сам, где это работает.',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                const SizedBox(height: 16),
                Card(
                  child: Column(children: const [
                    ListTile(
                      leading: Icon(Icons.bluetooth),
                      title: Text('Тревога группе рядом'),
                      subtitle: Text('по Bluetooth и Wi‑Fi — в следующей сборке'),
                    ),
                    ListTile(
                      leading: Icon(Icons.satellite_alt_outlined),
                      title: Text('Спутниковый SOS'),
                      subtitle: Text('нет сотовой сети? Телефон предложит его сам'),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Пакет для спасателей', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      const SizedBox(height: 8),
                      SelectableText(_package(), style: const TextStyle(fontSize: 13, height: 1.4)),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Скопировать'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _package()));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
                        },
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Отменить тревогу'),
                ),
              ],
            ),
    );
  }
}
