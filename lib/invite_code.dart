// Код приглашения: вся поездка (без чата и трат) в одной ссылке roamly://join?d=...
// Так присоединиться можно без интернета — достаточно отсканировать QR.
import 'dart:convert';

import 'data.dart';

const inviteScheme = 'roamly';

class InvitePayload {
  final Trip trip;
  final List<Wallet> wallets;
  final List<Member> members; // isMe везде false
  final bool asChild;
  InvitePayload(this.trip, this.wallets, this.members, this.asChild);
}

String buildInviteLink(TripBundle b, {bool asChild = false}) {
  final t = b.trip;
  final walletIdx = {for (var i = 0; i < b.wallets.length; i++) b.wallets[i].id: i};
  final data = {
    'v': 1,
    'c': asChild ? 1 : 0,
    't': [t.id, t.name, t.type.index, t.start.millisecondsSinceEpoch, t.end.millisecondsSinceEpoch, t.currency, t.childPercent],
    'w': [for (final w in b.wallets) [w.id, w.name]],
    'm': [for (final m in b.members) [m.id, m.name, m.isChild ? 1 : 0, walletIdx[m.walletId] ?? 0]],
  };
  final d = base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
  return '$inviteScheme://join?d=$d';
}

/// Принимает ссылку roamly://join?d=... (или просто строку из QR). null — не наш код.
InvitePayload? parseInvite(String raw) {
  try {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != inviteScheme || uri.host != 'join') return null;
    var d = uri.queryParameters['d'];
    if (d == null || d.isEmpty) return null;
    while (d!.length % 4 != 0) {
      d += '=';
    }
    final j = jsonDecode(utf8.decode(base64Url.decode(d))) as Map<String, dynamic>;
    if (j['v'] != 1) return null;
    final t = j['t'] as List;
    final trip = Trip(
      id: t[0] as String,
      name: t[1] as String,
      type: TripType.values[(t[2] as int).clamp(0, TripType.values.length - 1)],
      start: DateTime.fromMillisecondsSinceEpoch(t[3] as int),
      end: DateTime.fromMillisecondsSinceEpoch(t[4] as int),
      currency: t[5] as String,
      childPercent: t[6] as int,
      created: DateTime.now(),
    );
    final wallets = [
      for (final w in j['w'] as List) Wallet(id: (w as List)[0] as String, tripId: trip.id, name: w[1] as String),
    ];
    final members = [
      for (final m in j['m'] as List)
        Member(
          id: (m as List)[0] as String,
          tripId: trip.id,
          name: m[1] as String,
          isChild: m[2] == 1,
          walletId: wallets[(m[3] as int).clamp(0, wallets.length - 1)].id,
        ),
    ];
    return InvitePayload(trip, wallets, members, j['c'] == 1);
  } catch (_) {
    return null;
  }
}
