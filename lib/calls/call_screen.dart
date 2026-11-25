import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_state.dart';
import '../theme.dart';

/// Экран звонка: участники плиткой, микрофон, камера, завершить.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.tripId, required this.room, required this.video, required this.title});
  final String tripId;
  final String room;
  final bool video;
  final String title;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final AppState _s;
  Room? _room;
  String? _error;
  bool _connecting = true;
  bool _mic = true;
  bool _cam = false;

  @override
  void initState() {
    super.initState();
    _s = App.read(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final s = _s;
    s.calls.activeRoom = widget.room;
    try {
      final perms = [Permission.microphone, if (widget.video) Permission.camera];
      final res = await perms.request();
      if (res[Permission.microphone]?.isGranted != true) throw 'Нужно разрешение на микрофон';
      final (url, token) = await s.calls.token(widget.tripId, widget.room, s.myName);
      final room = Room();
      room.addListener(_onRoom);
      await room.connect(url, token);
      _room = room;
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (widget.video && res[Permission.camera]?.isGranted == true) {
        await room.localParticipant?.setCameraEnabled(true);
        _cam = true;
      }
    } catch (e) {
      _error = 'Не удалось подключиться: $e';
    }
    if (mounted) setState(() => _connecting = false);
  }

  void _onRoom() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleMic() async {
    _mic = !_mic;
    await _room?.localParticipant?.setMicrophoneEnabled(_mic);
    setState(() {});
  }

  Future<void> _toggleCam() async {
    if (!_cam && !(await Permission.camera.request()).isGranted) return;
    _cam = !_cam;
    await _room?.localParticipant?.setCameraEnabled(_cam);
    setState(() {});
  }

  Future<void> _hangUp() async {
    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    if (_s.calls.activeRoom == widget.room) _s.calls.activeRoom = null;
    _room?.removeListener(_onRoom);
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final tiles = <Widget>[];
    if (room != null) {
      final me = room.localParticipant;
      if (me != null) tiles.add(_tile(me, 'Вы'));
      for (final p in room.remoteParticipants.values) {
        tiles.add(_tile(p, p.name.isNotEmpty ? p.name : p.identity));
      }
    }
    final others = room?.remoteParticipants.length ?? 0;
    return Scaffold(
      backgroundColor: const Color(0xFF101816),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error ??
                  (_connecting
                      ? 'Подключаюсь…'
                      : others == 0
                          ? 'Ждём остальных…'
                          : 'В звонке: ${others + 1}'),
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: tiles.length <= 1 ? 1 : 2,
              padding: const EdgeInsets.all(8),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: tiles.length <= 2 ? 0.75 : 1,
              children: tiles,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _round(_mic ? Icons.mic : Icons.mic_off, _mic ? 'Выключить микрофон' : 'Включить микрофон', _toggleMic),
              _round(_cam ? Icons.videocam : Icons.videocam_off, _cam ? 'Выключить камеру' : 'Включить камеру', _toggleCam),
              _round(Icons.call_end, 'Завершить', _hangUp, color: sosColor(context)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _tile(Participant p, String name) {
    final video = p.videoTrackPublications.map((t) => t.track).whereType<VideoTrack>().firstOrNull;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: const Color(0xFF1E2A27),
        child: Stack(fit: StackFit.expand, children: [
          if (video != null) VideoTrackRenderer(video) else Center(child: Avatar(name, size: 72)),
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _round(IconData icon, String tip, VoidCallback onTap, {Color? color}) => IconButton.filled(
        iconSize: 30,
        style: IconButton.styleFrom(
          backgroundColor: color ?? Colors.white24,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 64),
        ),
        tooltip: tip,
        icon: Icon(icon),
        onPressed: onTap,
      );
}

/// Входящий звонок: ответить (без видео или с видео) или отклонить.
class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({super.key, required this.tripId, required this.tripName, required this.room, required this.name, required this.video});
  final String tripId;
  final String tripName;
  final String room;
  final String name;
  final bool video;

  void _answer(BuildContext context, bool withVideo) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => CallScreen(tripId: tripId, room: room, video: withVideo, title: tripName)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101816),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            Avatar(name, size: 96),
            const SizedBox(height: 16),
            Text(name, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('${video ? 'Видеозвонок' : 'Звонок'} · $tripName', style: const TextStyle(color: Colors.white70)),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _btn(context, Icons.call_end, 'Отклонить', sosColor(context), () => Navigator.pop(context)),
              _btn(context, Icons.call, 'Ответить', const Color(0xFF16A34A), () => _answer(context, false)),
              if (video) _btn(context, Icons.videocam, 'С видео', const Color(0xFF16A34A), () => _answer(context, true)),
            ]),
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }

  Widget _btn(BuildContext context, IconData icon, String label, Color color, VoidCallback onTap) => Column(children: [
        IconButton.filled(
          iconSize: 32,
          style: IconButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, minimumSize: const Size(72, 72)),
          icon: Icon(icon),
          onPressed: onTap,
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ]);
}
