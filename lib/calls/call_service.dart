// Звонки (Premium по ТЗ; на этапе теста — для всех).
//
// Любой звонок — «комната» в LiveKit, привязанная к поездке. Начать — значит создать запись
// «звонок» в журнале поездки: она дойдёт до остальных (рядом или через сервер), у них появится
// входящий звонок и строка в чате «присоединиться». Вдвоём или всей группой — одно и то же:
// любой участник может войти в ту же комнату в любой момент.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data.dart';
import '../sync/nearby_sync.dart' show NearbySync;
import '../sync/server_sync.dart' show serverHost;

class IncomingCall {
  IncomingCall({required this.tripId, required this.room, required this.name, required this.video});
  final String tripId;
  final String room;
  final String name;
  final bool video;
}

class CallService extends ChangeNotifier {
  CallService(this.repo) {
    repo.ingestListeners.add(_onIngested);
  }

  final Repo repo;

  /// Входящий звонок, который ещё не показан (экран забирает и обнуляет).
  final incoming = ValueNotifier<IncomingCall?>(null);

  /// Комната, в которой сейчас идёт наш звонок.
  String? activeRoom;

  void _onIngested(List<SyncEvent> events) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in events) {
      if (e.type != 'call' || e.device == repo.deviceId) continue;
      if (now - e.ts > 90 * 1000) continue; // старый звонок — только строка в чате
      final room = e.data['room'] as String?;
      if (room == null || room == activeRoom) continue;
      incoming.value = IncomingCall(
        tripId: e.tripId,
        room: room,
        name: e.data['name'] as String? ?? '',
        video: e.data['video'] == true,
      );
    }
  }

  /// Начать звонок в поездке: запись в журнал (дойдёт до всех) и id комнаты.
  Future<String> start(TripBundle b, {required bool video, required String myName}) async {
    final room = newId().substring(0, 13);
    await repo.startCall(b.trip.id, room: room, memberId: b.me?.id, name: b.me?.name ?? myName, video: video);
    return room;
  }

  /// Пропуск в комнату от сервера: (url LiveKit, token).
  Future<(String, String)> token(String tripId, String room, String name) async {
    final r = await http
        .post(
          Uri.https(serverHost, '/call-token'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'t': NearbySync.tripHash(tripId), 'room': room, 'id': repo.deviceId, 'name': name}),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw 'Сервер звонков ответил ${r.statusCode}';
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['url'] as String, j['token'] as String);
  }
}
