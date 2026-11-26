// Экранные части вложений: пузырь в чате, просмотр фото и видео, кружок, голосовое, запись.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../app_state.dart';
import '../data.dart';
import 'media_service.dart';

// ================= выбор и отправка =================

enum Attach { gallery, camera, videoGallery, videoCamera, note, file }

/// Выбрать и отправить вложение в беседу.
Future<void> pickAndSend(BuildContext context, TripBundle b, Attach what, {int channel = 0}) async {
  final s = App.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  final picker = ImagePicker();
  void busy(String t) => messenger.showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 2)));
  try {
    switch (what) {
      case Attach.gallery:
        final files = await picker.pickMultiImage();
        if (files.isEmpty) return;
        busy(files.length == 1 ? 'Отправляю фото…' : 'Отправляю ${files.length} фото…');
        for (final f in files) {
          await s.media.addPhoto(b, f.path, channel: channel);
        }
      case Attach.camera:
        final f = await picker.pickImage(source: ImageSource.camera);
        if (f == null) return;
        await s.media.addPhoto(b, f.path, channel: channel);
      case Attach.videoGallery:
      case Attach.videoCamera:
        final f = await picker.pickVideo(
          source: what == Attach.videoCamera ? ImageSource.camera : ImageSource.gallery,
          maxDuration: const Duration(minutes: 3),
        );
        if (f == null) return;
        final size = await File(f.path).length();
        if (size > 50 * 1024 * 1024) {
          busy('Видео ${formatSize(size)}: через интернет такое не уйдёт, только рядом по Wi‑Fi');
        } else {
          busy('Отправляю видео…');
        }
        await s.media.addVideo(b, f.path, durMs: await videoDuration(f.path), channel: channel);
      case Attach.note:
        final r = await nav.push<(String, int)>(MaterialPageRoute(builder: (_) => const NoteRecorderScreen()));
        if (r == null) return;
        await s.media.addVideo(b, r.$1, note: true, durMs: r.$2, channel: channel);
      case Attach.file:
        final f = await openFile();
        if (f == null) return;
        await s.media.addFile(b, f.path, f.name, mime: f.mimeType, channel: channel);
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Не получилось: $e')));
  }
}

Future<int> videoDuration(String path) async {
  final c = VideoPlayerController.file(File(path));
  try {
    await c.initialize();
    return c.value.duration.inMilliseconds;
  } catch (_) {
    return 0;
  } finally {
    await c.dispose();
  }
}

/// Меню «прикрепить» с вложениями (+ дополнительные пункты беседы сверху).
void showAttachSheet(BuildContext context, TripBundle b, {int channel = 0, List<Widget> extra = const []}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget item(IconData icon, String title, Attach a) => ListTile(
            leading: Icon(icon),
            title: Text(title),
            onTap: () {
              Navigator.pop(ctx);
              pickAndSend(context, b, a, channel: channel);
            },
          );
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ...extra,
            item(Icons.photo_library_outlined, 'Фото из галереи', Attach.gallery),
            item(Icons.photo_camera_outlined, 'Снять фото', Attach.camera),
            item(Icons.video_library_outlined, 'Видео из галереи', Attach.videoGallery),
            item(Icons.videocam_outlined, 'Снять видео', Attach.videoCamera),
            item(Icons.radio_button_checked, 'Видеосообщение (кружок)', Attach.note),
            item(Icons.description_outlined, 'Файл: билет, бронь, PDF', Attach.file),
          ]),
        ),
      );
    },
  );
}

// ================= пузырь в чате =================

Widget _thumbImage(Media m, {BoxFit fit = BoxFit.cover}) {
  if (m.thumb == null) return Container(color: Colors.black12);
  try {
    return Image.memory(base64Decode(m.thumb!), fit: fit, gaplessPlayback: true);
  } catch (_) {
    return Container(color: Colors.black12);
  }
}

/// Значок загрузки поверх миниатюры: крутилка, облачко с размером или причина.
class _LoadBadge extends StatelessWidget {
  const _LoadBadge(this.m, this.part);
  final Media m;
  final String part;
  @override
  Widget build(BuildContext context) {
    final svc = App.read(context).media;
    final busy = svc.isActive(m.id, part);
    final fail = svc.failure(m.id, part);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy)
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        else
          const Icon(Icons.download, size: 16, color: Colors.white),
        const SizedBox(width: 4),
        Text(fail ?? formatSize(m.parts[part]?.size ?? 0), style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]),
    );
  }
}

class MediaBubble extends StatelessWidget {
  const MediaBubble({super.key, required this.media, required this.local, required this.b});
  final Media media;
  final Map<String, String> local;
  final TripBundle b;

  @override
  Widget build(BuildContext context) {
    final svc = App.of(context).media;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => switch (media.kind) {
        MediaKind.photo => _photo(context),
        MediaKind.video => _video(context),
        MediaKind.note => NoteBubble(media: media, path: local['v']),
        MediaKind.voice => VoiceBubble(media: media, path: local['a']),
        MediaKind.file => _file(context),
      },
    );
  }

  Widget _photo(BuildContext context) {
    final path = local['p'] ?? local['o'];
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewer(media: media, b: b))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 240,
          height: 200,
          child: Stack(fit: StackFit.expand, children: [
            path != null ? Image.file(File(path), fit: BoxFit.cover, gaplessPlayback: true) : _thumbImage(media),
            if (path == null) Positioned(left: 8, bottom: 8, child: _LoadBadge(media, 'p')),
          ]),
        ),
      ),
    );
  }

  Widget _video(BuildContext context) {
    final path = local['v'];
    final svc = App.read(context).media;
    return GestureDetector(
      onTap: () {
        if (path != null) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => VideoScreen(media: media, path: path, b: b)));
        } else {
          svc.request(media, 'v');
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 240,
          height: 180,
          child: Stack(fit: StackFit.expand, children: [
            _thumbImage(media),
            Center(
              child: Container(
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                padding: const EdgeInsets.all(10),
                child: Icon(path != null ? Icons.play_arrow : Icons.download, color: Colors.white, size: 32),
              ),
            ),
            Positioned(
              left: 8,
              bottom: 8,
              child: path == null
                  ? _LoadBadge(media, 'v')
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                      child: Text(formatDur(media.durMs), style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _file(BuildContext context) {
    final path = local['f'];
    final svc = App.read(context).media;
    final cs = Theme.of(context).colorScheme;
    final busy = svc.isActive(media.id, 'f');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        if (path != null) {
          await OpenFilex.open(path);
        } else {
          await svc.request(media, 'f');
        }
      },
      child: SizedBox(
        width: 250,
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(10)),
            child: busy
                ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(path != null ? Icons.description_outlined : Icons.download, color: cs.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(media.name ?? 'Файл', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              Text(svc.failure(media.id, 'f') ?? formatSize(media.mainSize), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ================= кружок =================

class NoteBubble extends StatefulWidget {
  const NoteBubble({super.key, required this.media, required this.path});
  final Media media;
  final String? path;
  @override
  State<NoteBubble> createState() => _NoteBubbleState();
}

class _NoteBubbleState extends State<NoteBubble> {
  VideoPlayerController? _c;

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _tap() async {
    final path = widget.path;
    if (path == null) {
      await App.read(context).media.request(widget.media, 'v');
      return;
    }
    if (_c == null) {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      c.addListener(() {
        if (c.value.position >= c.value.duration && !c.value.isPlaying && mounted) setState(() {});
      });
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
      await c.play();
      return;
    }
    final c = _c!;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final playing = c != null && c.value.isPlaying;
    return GestureDetector(
      onTap: _tap,
      child: SizedBox(
        width: 200,
        height: 200,
        child: Stack(fit: StackFit.expand, children: [
          ClipOval(
            child: c != null && c.value.isInitialized
                ? FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)),
                  )
                : _thumbImage(widget.media),
          ),
          if (!playing)
            Center(
              child: Container(
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                padding: const EdgeInsets.all(8),
                child: Icon(widget.path != null ? Icons.play_arrow : Icons.download, color: Colors.white, size: 30),
              ),
            ),
          Positioned(
            right: 12,
            bottom: 8,
            child: widget.path == null
                ? _LoadBadge(widget.media, 'v')
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Text(formatDur(widget.media.durMs), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
          ),
        ]),
      ),
    );
  }
}

// ================= голосовое =================

class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.media, required this.path});
  final Media media;
  final String? path;
  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  VideoPlayerController? _c;

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final path = widget.path;
    if (path == null) {
      await App.read(context).media.request(widget.media, 'a');
      return;
    }
    if (_c == null) {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      c.addListener(() {
        if (mounted) setState(() {});
      });
      if (!mounted) {
        await c.dispose();
        return;
      }
      _c = c;
    }
    final c = _c!;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final svc = App.read(context).media;
    final c = _c;
    final total = c?.value.duration.inMilliseconds ?? widget.media.durMs;
    final pos = c?.value.position.inMilliseconds ?? 0;
    final playing = c?.value.isPlaying ?? false;
    final busy = svc.isActive(widget.media.id, 'a');
    return SizedBox(
      width: 240,
      child: Row(children: [
        IconButton.filled(
          onPressed: _toggle,
          icon: busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(widget.path == null ? Icons.download : (playing ? Icons.pause : Icons.play_arrow)),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(
              value: total > 0 ? (pos / total).clamp(0.0, 1.0) : 0,
              backgroundColor: cs.outlineVariant,
              minHeight: 3,
            ),
            const SizedBox(height: 4),
            Text(
              svc.failure(widget.media.id, 'a') ?? (playing || pos > 0 ? '${formatDur(pos)} / ${formatDur(total)}' : formatDur(total)),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ================= просмотр фото =================

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.media, required this.b});
  final Media media;
  final TripBundle b;
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  Map<String, String> _local = {};
  Repo? _repo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_repo == null) {
      _repo = App.read(context).repo;
      _repo!.addListener(_load); // подхватить пришедший оригинал или просмотр
      _load();
    }
  }

  @override
  void dispose() {
    _repo?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final all = await _repo!.localMediaFiles();
    if (mounted) setState(() => _local = all[widget.media.id] ?? {});
  }

  @override
  Widget build(BuildContext context) {
    final s = App.of(context);
    final m = widget.media;
    final path = _local['o'] ?? _local['p'];
    final mine = widget.b.me?.id != null && widget.b.me?.id == m.authorId;
    final author = widget.b.member(m.authorId)?.name ?? '';
    return ListenableBuilder(
      listenable: s.media,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(author, style: const TextStyle(fontSize: 16)),
            actions: [
              if (_local['o'] == null && m.parts.containsKey('o'))
                IconButton(
                  tooltip: 'Скачать оригинал (${formatSize(m.parts['o']!.size)}) — только рядом',
                  icon: s.media.isActive(m.id, 'o')
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.hd_outlined),
                  onPressed: () => s.media.request(m, 'o'),
                ),
              if (path != null)
                IconButton(
                  tooltip: 'Сохранить в галерею',
                  icon: const Icon(Icons.save_alt),
                  onPressed: () => _save(path),
                ),
              if (mine)
                IconButton(
                  tooltip: 'Удалить у всех',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => confirmDeleteMedia(context, m, closeScreen: true),
                ),
            ],
          ),
          body: Column(children: [
            Expanded(
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: path != null ? Image.file(File(path), fit: BoxFit.contain, gaplessPlayback: true) : _thumbImage(m, fit: BoxFit.contain),
                ),
              ),
            ),
            if (path == null || s.media.failure(m.id, 'o') != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  s.media.failure(m.id, 'o') ?? s.media.failure(m.id, 'p') ?? 'Загружается…',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ]),
        );
      },
    );
  }

  Future<void> _save(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Gal.putImage(path, album: 'Roamly');
      messenger.showSnackBar(const SnackBar(content: Text('Сохранено в галерею')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не сохранилось: $e')));
    }
  }
}

Future<void> confirmDeleteMedia(BuildContext context, Media m, {bool closeScreen = false}) async {
  final repo = App.read(context).repo;
  final nav = Navigator.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Удалить у всех?'),
      content: const Text('Вложение пропадёт у всех участников беседы.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
      ],
    ),
  );
  if (ok != true) return;
  await repo.deleteMedia(m);
  if (closeScreen && nav.canPop()) nav.pop();
}

// ================= видео =================

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.media, required this.path, required this.b});
  final Media media;
  final String path;
  final TripBundle b;
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late final VideoPlayerController _c = VideoPlayerController.file(File(widget.path));

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _c.play();
    });
    _c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.b.me?.id != null && widget.b.me?.id == widget.media.authorId;
    final v = _c.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Сохранить в галерею',
            icon: const Icon(Icons.save_alt),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await Gal.putVideo(widget.path, album: 'Roamly');
                messenger.showSnackBar(const SnackBar(content: Text('Сохранено в галерею')));
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('Не сохранилось: $e')));
              }
            },
          ),
          if (mine)
            IconButton(
              tooltip: 'Удалить у всех',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => confirmDeleteMedia(context, widget.media, closeScreen: true),
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Center(
            child: v.isInitialized
                ? AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_c))
                : const CircularProgressIndicator(),
          ),
        ),
        if (v.isInitialized)
          SafeArea(
            top: false,
            child: Row(children: [
              IconButton(
                color: Colors.white,
                icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
              ),
              Expanded(child: VideoProgressIndicator(_c, allowScrubbing: true)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('${formatDur(v.position.inMilliseconds)} / ${formatDur(v.duration.inMilliseconds)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            ]),
          ),
      ]),
    );
  }
}

// ================= запись кружка =================

class NoteRecorderScreen extends StatefulWidget {
  const NoteRecorderScreen({super.key});
  @override
  State<NoteRecorderScreen> createState() => _NoteRecorderScreenState();
}

class _NoteRecorderScreenState extends State<NoteRecorderScreen> {
  static const _max = Duration(seconds: 60);
  CameraController? _c;
  String? _error;
  bool _rec = false;
  DateTime? _start;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw 'камеры нет';
      final front = cams.where((c) => c.lensDirection == CameraLensDirection.front).firstOrNull ?? cams.first;
      final c = CameraController(front, ResolutionPreset.medium, enableAudio: true, videoBitrate: 500000, audioBitrate: 48000);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
    } catch (e) {
      if (mounted) setState(() => _error = 'Камера не открылась: $e');
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _c?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final c = _c;
    if (c == null) return;
    if (!_rec) {
      await c.startVideoRecording();
      _start = DateTime.now();
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        setState(() {});
        if (DateTime.now().difference(_start!) >= _max) _stop();
      });
      setState(() => _rec = true);
    } else {
      await _stop();
    }
  }

  Future<void> _stop() async {
    final c = _c;
    if (c == null || !_rec) return;
    _tick?.cancel();
    _rec = false;
    final file = await c.stopVideoRecording();
    final dur = DateTime.now().difference(_start!).inMilliseconds;
    final dir = await getTemporaryDirectory();
    final dest = p.join(dir.path, 'note_${DateTime.now().millisecondsSinceEpoch}.mp4');
    await File(file.path).copy(dest);
    if (mounted) Navigator.pop(context, (dest, dur));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final elapsed = _start == null || !_rec ? Duration.zero : DateTime.now().difference(_start!);
    final size = MediaQuery.of(context).size.width * 0.8;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Видеосообщение')),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white))
            : Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: size,
                  height: size,
                  child: Stack(fit: StackFit.expand, children: [
                    ClipOval(
                      child: c == null || !c.value.isInitialized
                          ? Container(color: Colors.white10)
                          : FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: c.value.previewSize?.height ?? size,
                                height: c.value.previewSize?.width ?? size,
                                child: CameraPreview(c),
                              ),
                            ),
                    ),
                    CircularProgressIndicator(
                      value: elapsed.inMilliseconds / _max.inMilliseconds,
                      strokeWidth: 4,
                      color: Colors.redAccent,
                    ),
                  ]),
                ),
                const SizedBox(height: 24),
                Text(_rec ? formatDur(elapsed.inMilliseconds) : 'До 60 секунд',
                    style: const TextStyle(color: Colors.white70, fontSize: 16)),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: _toggle,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: _rec ? 30 : 58,
                        height: _rec ? 30 : 58,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(_rec ? 6 : 29),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(_rec ? 'Нажмите, чтобы отправить' : 'Нажмите, чтобы начать',
                    style: const TextStyle(color: Colors.white54)),
              ]),
      ),
    );
  }
}
