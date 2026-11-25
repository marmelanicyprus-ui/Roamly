import 'data.dart';

const currencies = ['EUR', 'USD', 'GBP', 'RUB', 'TRY', 'CHF'];

String money(int cents, String currency) {
  final neg = cents < 0;
  final abs = cents.abs();
  final whole = (abs ~/ 100).toString();
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(' ');
    buf.write(whole[i]);
  }
  final frac = (abs % 100).toString().padLeft(2, '0');
  final sym = switch (currency) {
    'EUR' => '€',
    'USD' => '\$',
    'GBP' => '£',
    'RUB' => '₽',
    'TRY' => '₺',
    _ => '$currency ',
  };
  return '${neg ? '−' : ''}$sym$buf,$frac';
}

/// "86,40" / "86.4" -> 8640
int? parseCents(String s) {
  final t = s.replaceAll(' ', '').replaceAll(' ', '').replaceAll(',', '.');
  final v = double.tryParse(t);
  if (v == null || v < 0) return null;
  return (v * 100).round();
}

/// Вес участника при делении по правилам поездки.
double weightOf(Member m, int childPercent) => m.isChild ? childPercent / 100.0 : 1.0;

/// Делит сумму между кошельками пропорционально весам; копейки-остаток уходят
/// кошелькам с наибольшими дробными частями, чтобы сумма сходилась точно.
Map<String, int> splitByWeights(int total, Map<String, double> weights) {
  final sum = weights.values.fold<double>(0, (a, b) => a + b);
  if (sum <= 0) return {};
  final raw = {for (final e in weights.entries) e.key: total * e.value / sum};
  final out = {for (final e in raw.entries) e.key: e.value.floor()};
  var rest = total - out.values.fold<int>(0, (a, b) => a + b);
  final order = raw.keys.toList()..sort((a, b) => (raw[b]! - raw[b]!.floor()).compareTo(raw[a]! - raw[a]!.floor()));
  for (var i = 0; rest > 0 && order.isNotEmpty; i++, rest--) {
    final k = order[i % order.length];
    out[k] = out[k]! + 1;
  }
  return out;
}

/// Баланс кошелька: + ему должны, − он должен.
Map<String, int> balances(TripBundle b, List<Expense> expenses, List<Transfer> transfers) {
  final bal = {for (final w in b.wallets) w.id: 0};
  for (final e in expenses) {
    final payer = b.member(e.payerId);
    if (payer != null) bal[payer.walletId] = (bal[payer.walletId] ?? 0) + e.tripCents;
    for (final part in e.parts.entries) {
      bal[part.key] = (bal[part.key] ?? 0) - part.value;
    }
  }
  for (final t in transfers) {
    bal[t.fromWallet] = (bal[t.fromWallet] ?? 0) + t.cents;
    bal[t.toWallet] = (bal[t.toWallet] ?? 0) - t.cents;
  }
  return bal;
}

class Settlement {
  final String fromWallet;
  final String toWallet;
  final int cents;
  Settlement(this.fromWallet, this.toWallet, this.cents);
}

/// Минимум переводов: жадно сводим самого большого должника с самым большим кредитором.
List<Settlement> settle(Map<String, int> bal) {
  final debtors = bal.entries.where((e) => e.value < 0).map((e) => [e.key, -e.value]).toList();
  final creditors = bal.entries.where((e) => e.value > 0).map((e) => [e.key, e.value]).toList();
  final out = <Settlement>[];
  while (debtors.isNotEmpty && creditors.isNotEmpty) {
    debtors.sort((a, b) => (b[1] as int).compareTo(a[1] as int));
    creditors.sort((a, b) => (b[1] as int).compareTo(a[1] as int));
    final d = debtors.first;
    final c = creditors.first;
    final amt = (d[1] as int) < (c[1] as int) ? d[1] as int : c[1] as int;
    if (amt > 0) out.add(Settlement(d[0] as String, c[0] as String, amt));
    d[1] = (d[1] as int) - amt;
    c[1] = (c[1] as int) - amt;
    if (d[1] == 0) debtors.removeAt(0);
    if (c[1] == 0) creditors.removeAt(0);
  }
  return out;
}
