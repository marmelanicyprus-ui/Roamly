import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data.dart';
import '../money.dart';
import '../theme.dart';

const categories = ['Еда', 'Жильё', 'Транспорт', 'Топливо', 'Развлечения', 'Другое'];

IconData categoryIcon(String c) => switch (c) {
      'Еда' => Icons.shopping_cart_outlined,
      'Жильё' => Icons.bed_outlined,
      'Транспорт' => Icons.directions_bus_outlined,
      'Топливо' => Icons.local_gas_station_outlined,
      'Развлечения' => Icons.local_activity_outlined,
      _ => Icons.receipt_long_outlined,
    };

class AddExpenseScreen extends StatefulWidget {
  const AddExpenseScreen({super.key, required this.tripId});
  final String tripId;
  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  TripBundle? _b;
  final _amount = TextEditingController();
  final _title = TextEditingController();
  final _rate = TextEditingController(text: '1');
  String _category = 'Еда';
  String _currency = 'EUR';
  String? _payer;
  SplitMode _mode = SplitMode.rules;
  final Set<String> _included = {};
  final Map<String, TextEditingController> _manual = {};
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    App.read(context).repo.bundle(widget.tripId).then((b) {
      if (!mounted) return;
      setState(() {
        _b = b;
        _currency = b.trip.currency;
        _payer = b.me?.id ?? b.members.first.id;
        _included.addAll(b.wallets.map((w) => w.id));
        for (final w in b.wallets) {
          _manual[w.id] = TextEditingController();
        }
      });
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _title.dispose();
    _rate.dispose();
    for (final c in _manual.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _amountCents => parseCents(_amount.text) ?? 0;
  double get _rateValue => double.tryParse(_rate.text.replaceAll(',', '.')) ?? 0;
  int get _tripCents => _currency == _b!.trip.currency ? _amountCents : (_amountCents * _rateValue).round();

  Map<String, int> _parts() {
    final b = _b!;
    final total = _tripCents;
    switch (_mode) {
      case SplitMode.rules:
        return splitByWeights(total, {
          for (final w in b.wallets)
            if (_included.contains(w.id))
              w.id: b.membersOf(w.id).fold<double>(0, (a, m) => a + weightOf(m, b.trip.childPercent)),
        });
      case SplitMode.equal:
        return splitByWeights(total, {
          for (final w in b.wallets)
            if (_included.contains(w.id)) w.id: b.membersOf(w.id).length.toDouble(),
        });
      case SplitMode.manual:
        return {
          for (final w in b.wallets)
            if ((parseCents(_manual[w.id]!.text) ?? 0) > 0) w.id: parseCents(_manual[w.id]!.text)!,
        };
    }
  }

  String? get _error {
    if (_amountCents <= 0) return 'Введите сумму';
    if (_currency != _b!.trip.currency && _rateValue <= 0) return 'Укажите курс';
    final parts = _parts();
    if (parts.isEmpty) return 'Отметьте, на кого делим';
    final sum = parts.values.fold<int>(0, (a, v) => a + v);
    if (_mode == SplitMode.manual && sum != _tripCents) {
      return 'Сумма долей ${money(sum, _b!.trip.currency)} ≠ ${money(_tripCents, _b!.trip.currency)}';
    }
    return null;
  }

  Future<void> _save() async {
    if (_error != null) return;
    final b = _b!;
    final e = Expense(
      id: newId(),
      tripId: b.trip.id,
      title: _title.text.trim().isEmpty ? _category : _title.text.trim(),
      category: _category,
      amountCents: _amountCents,
      currency: _currency,
      rate: _currency == b.trip.currency ? 1 : _rateValue,
      tripCents: _tripCents,
      payerId: _payer!,
      mode: _mode,
      created: DateTime.now(),
      parts: _parts(),
    );
    await App.read(context).repo.addExpense(e, b.me?.id);
    if (mounted) Navigator.pop(context);
  }

  String _walletSubtitle(Wallet w) {
    final ms = _b!.membersOf(w.id);
    final kids = ms.where((m) => m.isChild).length;
    final adults = ms.length - kids;
    final shares = _mode == SplitMode.equal
        ? ms.length.toDouble()
        : ms.fold<double>(0, (a, m) => a + weightOf(m, _b!.trip.childPercent));
    final s = shares == shares.roundToDouble() ? shares.toInt().toString() : shares.toStringAsFixed(1).replaceAll('.', ',');
    return '${ms.map((m) => m.name).join(', ')} · $adults взр.${kids > 0 ? ' + $kids дет.' : ''} · $s дол.';
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final cs = Theme.of(context).colorScheme;
    final cur = b.trip.currency;
    final parts = _parts();
    final err = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Новая трата')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
                      decoration: const InputDecoration(hintText: '0,00', border: InputBorder.none),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  DropdownButton<String>(
                    value: _currency,
                    items: [for (final c in currencies) DropdownMenuItem(value: c, child: Text(c))],
                    onChanged: (v) => setState(() => _currency = v ?? cur),
                  ),
                ]),
                if (_currency != cur) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _rate,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: 'Курс: 1 $_currency = ? $cur', helperText: 'Курс вводится вручную, автоматический — в следующей сборке'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 4),
                  Text('В валюте поездки: ${money(_tripCents, cur)}', style: TextStyle(color: cs.onSurfaceVariant)),
                ],
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in categories)
                    ChoiceChip(
                      avatar: Icon(categoryIcon(c), size: 18),
                      label: Text(c),
                      selected: _category == c,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: _title,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: 'Описание', hintText: _category),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Text('Платил', style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _payer,
                      items: [
                        for (final m in b.members)
                          DropdownMenuItem(
                            value: m.id,
                            child: Row(children: [Avatar(m.name, size: 26), const SizedBox(width: 8), Text(m.isMe ? '${m.name} (вы)' : m.name)]),
                          ),
                      ],
                      onChanged: (v) => setState(() => _payer = v),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SegmentedButton<SplitMode>(
                  segments: const [
                    ButtonSegment(value: SplitMode.rules, label: Text('По правилам')),
                    ButtonSegment(value: SplitMode.equal, label: Text('Поровну')),
                    ButtonSegment(value: SplitMode.manual, label: Text('Вручную')),
                  ],
                  selected: {_mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  switch (_mode) {
                    SplitMode.rules => 'Правило поездки: дети платят ${b.trip.childPercent}%',
                    SplitMode.equal => 'Каждый участник — одна доля, дети тоже',
                    SplitMode.manual => 'Впишите сумму каждого кошелька в $cur',
                  },
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                for (final w in b.wallets)
                  _mode == SplitMode.manual
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Expanded(child: Text(w.name)),
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: _manual[w.id],
                                textAlign: TextAlign.right,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(hintText: '0,00'),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ]),
                        )
                      : CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _included.contains(w.id),
                          onChanged: (v) => setState(() => v == true ? _included.add(w.id) : _included.remove(w.id)),
                          title: Text(w.name),
                          subtitle: Text(_walletSubtitle(w), style: const TextStyle(fontSize: 12)),
                          secondary: Text(money(parts[w.id] ?? 0, cur), style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
              ]),
            ),
          ),
          const SizedBox(height: 88),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (err != null && _amount.text.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(err, style: TextStyle(color: cs.error))),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: err == null ? _save : null,
              child: const Text('Сохранить'),
            ),
            const SizedBox(height: 4),
            Text('Появится в чате поездки', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}
