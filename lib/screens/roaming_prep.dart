import 'package:flutter/material.dart';

/// Чек-лист «Подготовить к роумингу». Автоматическая загрузка — в следующих сборках.
class RoamingPrepScreen extends StatefulWidget {
  const RoamingPrepScreen({super.key});
  @override
  State<RoamingPrepScreen> createState() => _RoamingPrepScreenState();
}

class _RoamingPrepScreenState extends State<RoamingPrepScreen> {
  final _done = <int>{};
  static const _items = [
    ('Офлайн-карта региона', 'загрузка карт — в следующей сборке'),
    ('Брони и билеты', 'добавьте их в план поездки'),
    ('Курсы валют', 'пока вводятся вручную в трате'),
    ('Участники и контакты', 'добавлены в поездку'),
    ('Номера экстренных служб', 'в Европе — 112'),
    ('Медкарта телефона', 'Medical ID / «Экстренная информация» в настройках телефона'),
    ('Спутниковый SOS', 'проверьте, есть ли он на вашем телефоне'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Подготовить к роумингу')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(value: _done.length / _items.length, strokeWidth: 6, backgroundColor: cs.surfaceContainerHighest),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('Готово ${_done.length} из ${_items.length}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              for (var i = 0; i < _items.length; i++)
                CheckboxListTile(
                  value: _done.contains(i),
                  onChanged: (v) => setState(() => v == true ? _done.add(i) : _done.remove(i)),
                  title: Text(_items[i].$1),
                  subtitle: Text(_items[i].$2),
                ),
            ]),
          ),
        ],
      ),
    );
  }
}
