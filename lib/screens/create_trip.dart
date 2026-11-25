import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data.dart';
import '../money.dart';
import '../theme.dart';
import 'home.dart' show dateRange;
import 'invite.dart';

class _DraftMember {
  String name;
  bool isChild;
  int wallet; // индекс кошелька в _wallets
  final bool isMe;
  _DraftMember(this.name, this.isChild, this.wallet, {this.isMe = false});
}

class CreateTripScreen extends StatefulWidget {
  const CreateTripScreen({super.key});
  @override
  State<CreateTripScreen> createState() => _CreateTripScreenState();
}

class _CreateTripScreenState extends State<CreateTripScreen> {
  final _name = TextEditingController();
  TripType _type = TripType.yacht;
  late DateTimeRange _dates;
  String _currency = 'EUR';
  int _childPercent = 50;
  final List<String> _wallets = [];
  final List<_DraftMember> _members = [];
  bool _inited = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inited) return;
    _inited = true;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _dates = DateTimeRange(start: today, end: today.add(const Duration(days: 6)));
    final me = App.read(context).myName;
    _wallets.add('Кошелёк: $me');
    _members.add(_DraftMember(me, false, 0, isMe: true));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickDates() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      initialDateRange: _dates,
    );
    if (r != null) setState(() => _dates = r);
  }

  Future<void> _addMember() async {
    final nameC = TextEditingController();
    var isChild = false;
    var wallet = -1; // -1 = новый свой кошелёк
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Участник'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: nameC,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Имя'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ребёнок'),
              subtitle: Text('платит $_childPercent% доли'),
              value: isChild,
              onChanged: (v) => setD(() {
                isChild = v;
                if (v && wallet == -1) wallet = 0;
              }),
            ),
            const SizedBox(height: 4),
            const Text('Кошелёк — кто платит вместе', style: TextStyle(fontSize: 13)),
            DropdownButton<int>(
              isExpanded: true,
              value: wallet,
              items: [
                const DropdownMenuItem(value: -1, child: Text('Свой кошелёк')),
                for (var i = 0; i < _wallets.length; i++) DropdownMenuItem(value: i, child: Text(_wallets[i])),
              ],
              onChanged: (v) => setD(() => wallet = v ?? -1),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
          ],
        ),
      ),
    );
    final name = nameC.text.trim();
    if (ok != true || name.isEmpty) return;
    setState(() {
      var w = wallet;
      if (w == -1) {
        _wallets.add('Кошелёк: $name');
        w = _wallets.length - 1;
      }
      _members.add(_DraftMember(name, isChild, w));
    });
  }

  Future<void> _create() async {
    final name = _name.text.trim().isEmpty ? '${_type.label}: ${dateRange(_dates.start, _dates.end)}' : _name.text.trim();
    final repo = App.read(context).repo;
    final tripId = newId();
    final trip = Trip(
      id: tripId,
      name: name,
      type: _type,
      start: _dates.start,
      end: _dates.end,
      currency: _currency,
      childPercent: _childPercent,
      created: DateTime.now(),
    );
    // Пустые кошельки (все участники ушли в другие) не создаём.
    final used = _members.map((m) => m.wallet).toSet();
    final wallets = <int, Wallet>{
      for (var i = 0; i < _wallets.length; i++)
        if (used.contains(i)) i: Wallet(id: newId(), tripId: tripId, name: _wallets[i]),
    };
    final members = [
      for (final m in _members)
        Member(
          id: newId(),
          tripId: tripId,
          name: m.name,
          isChild: m.isChild,
          walletId: wallets[m.wallet]!.id,
          isMe: m.isMe,
        ),
    ];
    await repo.createTrip(trip, wallets.values.toList(), members);
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => InviteScreen(tripId: tripId)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Новая поездка')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Название', hintText: 'Например, Кипр: яхта'),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pickDates,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Даты'),
                    child: Text(dateRange(_dates.start, _dates.end)),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Text('Тип поездки — настроит функции и списки', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Row(children: [
            for (final t in TripType.values)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: t == TripType.values.last ? 0 : 8),
                  child: _TypeCard(type: t, selected: _type == t, onTap: () => setState(() => _type = t)),
                ),
              ),
          ]),
          const SizedBox(height: 6),
          Text('Автобус, вело, горы и другие типы — позже.', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(children: [
                Row(children: [
                  const Expanded(child: Text('Валюта поездки')),
                  DropdownButton<String>(
                    value: _currency,
                    underline: const SizedBox(),
                    items: [for (final c in currencies) DropdownMenuItem(value: c, child: Text(c))],
                    onChanged: (v) => setState(() => _currency = v ?? 'EUR'),
                  ),
                ]),
                Row(children: [
                  const Expanded(child: Text('Дети платят')),
                  DropdownButton<int>(
                    value: _childPercent,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('бесплатно')),
                      DropdownMenuItem(value: 50, child: Text('50%')),
                      DropdownMenuItem(value: 100, child: Text('полную долю')),
                    ],
                    onChanged: (v) => setState(() => _childPercent = v ?? 50),
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text('Участники · ${_members.length}', style: const TextStyle(fontWeight: FontWeight.w600))),
            TextButton.icon(onPressed: _addMember, icon: const Icon(Icons.person_add_alt), label: const Text('Добавить')),
          ]),
          Card(
            child: Column(children: [
              for (final m in _members)
                ListTile(
                  leading: Avatar(m.name, size: 36),
                  title: Text(m.isMe ? '${m.name} (вы)' : m.name),
                  subtitle: Text('${m.isChild ? 'ребёнок · ' : ''}${_wallets[m.wallet]}'),
                  trailing: m.isMe
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Убрать',
                          onPressed: () => setState(() => _members.remove(m)),
                        ),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          Text('Остальных можно пригласить по QR после создания. Free: до 4 телефонов, дети без телефона не считаются.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 88),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _create,
            child: const Text('Создать и пригласить'),
          ),
        ),
      ),
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({required this.type, required this.selected, required this.onTap});
  final TripType type;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.14) : cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          height: 92,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(tripIcon(type), size: 28, color: selected ? cs.primary : tripColor(type)),
            const SizedBox(height: 8),
            Text(type.label, style: TextStyle(fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}
