// Вкладка «Фото»: общий альбом поездки по дням — фото и видео из чатов.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../data.dart';
import '../media/media_service.dart';
import '../media/media_widgets.dart';
import 'trip.dart' show RepoListener;

class PhotosTab extends StatefulWidget {
  const PhotosTab({super.key, required this.b});
  final TripBundle b;
  @override
  State<PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<PhotosTab> with RepoListener<PhotosTab> {
  List<Media> _items = [];
  Map<String, Map<String, String>> _local = {};
  bool _loaded = false;

  @override
  Future<void> reload() async {
    final items = await repo.mediaList(tripId: widget.b.trip.id, kinds: {MediaKind.photo, MediaKind.video});
    final local = await repo.localMediaFiles();
    if (!mounted) return;
    setState(() {
      _items = items;
      _local = local;
      _loaded = true;
    });
  }

  void _add() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget item(IconData i, String t, Attach a) => ListTile(
              leading: Icon(i),
              title: Text(t),
              onTap: () {
                Navigator.pop(ctx);
                pickAndSend(context, widget.b, a);
              },
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            item(Icons.photo_library_outlined, 'Фото из галереи', Attach.gallery),
            item(Icons.photo_camera_outlined, 'Снять фото', Attach.camera),
            item(Icons.video_library_outlined, 'Видео из галереи', Attach.videoGallery),
            item(Icons.videocam_outlined, 'Снять видео', Attach.videoCamera),
          ]),
        );
      },
    );
  }

  void _open(Media m) {
    final local = _local[m.id] ?? {};
    if (m.kind == MediaKind.video) {
      final path = local['v'];
      if (path == null) {
        App.read(context).media.request(m, 'v');
        return;
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => VideoScreen(media: m, path: path, b: widget.b)));
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewer(media: m, b: widget.b)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final byDay = <DateTime, List<Media>>{};
    for (final m in _items) {
      final d = DateTime(m.created.year, m.created.month, m.created.day);
      (byDay[d] ??= []).add(m);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'photos-add',
        onPressed: _add,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('Добавить'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Здесь собираются фото и видео поездки из всех чатов. '
                      'Рядом они передаются без интернета, в роуминге сначала приходят миниатюры.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : ListenableBuilder(
                  listenable: App.of(context).media,
                  builder: (context, _) => CustomScrollView(slivers: [
                    for (final d in days) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Text(
                            '${DateFormat('d MMMM, EEEE', 'ru').format(d)} · ${byDay[d]!.length}',
                            style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant),
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        sliver: SliverGrid(
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 2,
                            crossAxisSpacing: 2,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (_, i) => _tile(byDay[d]![i]),
                            childCount: byDay[d]!.length,
                          ),
                        ),
                      ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 96)),
                  ]),
                ),
    );
  }

  Widget _tile(Media m) {
    final local = _local[m.id] ?? {};
    final path = m.kind == MediaKind.photo ? local['p'] ?? local['o'] : null;
    Widget img;
    if (path != null) {
      img = Image.file(File(path), fit: BoxFit.cover, cacheWidth: 400, gaplessPlayback: true);
    } else if (m.thumb != null) {
      img = Image.memory(base64Decode(m.thumb!), fit: BoxFit.cover, gaplessPlayback: true);
    } else {
      img = Container(color: Colors.black12);
    }
    final missing = m.kind == MediaKind.photo ? path == null : local['v'] == null;
    final busy = App.read(context).media.isActive(m.id, m.main);
    return GestureDetector(
      onTap: () => _open(m),
      child: Stack(fit: StackFit.expand, children: [
        img,
        if (m.kind == MediaKind.video)
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.play_arrow, color: Colors.white, size: 14),
                Text(formatDur(m.durMs), style: const TextStyle(color: Colors.white, fontSize: 11)),
              ]),
            ),
          ),
        if (missing)
          Positioned(
            right: 4,
            top: 4,
            child: busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.cloud_download_outlined, color: Colors.white, size: 18),
          ),
      ]),
    );
  }
}
