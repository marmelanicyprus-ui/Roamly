// Вложения: фото, видео, кружки, голосовые, файлы.
//
// Миниатюра и описание едут записью «media» в журнале поездки — даже в роуминге.
// Сами части (просмотр фото, видео, звук, файл) передаются отдельно:
//   • рядом — файлом через Nearby Connections (sync/nearby_sync.dart: want / file);
//   • через сервер — PUT/GET /blob/<хеш поездки>/<id>.<часть>, зашифрованные ключом поездки.
// Оригинал фото (часть «o») на сервер не уходит: только рядом и по запросу.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data.dart';
import '../sync/nearby_sync.dart';
import '../sync/server_sync.dart' show serverHost;

/// Что можно качать само, без кнопки.
enum Via { nearby, server, roaming }

const _serverMax = 50 * 1024 * 1024; // больше — только рядом
const _roamingFileMax = 2 * 1024 * 1024; // файлы до 2 МБ идут даже в роуминге

class MediaService extends ChangeNotifier {
  MediaService(this.repo, {required this.isRoaming, required this.serverOn}) {
    repo.ingestListeners.add((evs) {
      if (evs.any((e) => e.type == 'media')) schedule();
    });
    repo.localEventListeners.add((evs) {
      if (evs.any((e) => e.type == 'media')) schedule();
    });
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => schedule());
  }

  final Repo repo;
  final bool Function() isRoaming;
  final bool Function() serverOn;
  NearbySync? nearby;
  Timer? _timer;
  Timer? _soon;
  bool _pumping = false;

  /// Что сейчас качается: "mediaId:part" → доля 0..1 (или -1 — неизвестно).
  final Map<String, double> active = {};
  final Map<String, DateTime> _lastTry = {};
  final Map<String, String> _failed = {}; // "id:part" → причина (для подписи)

  String? failure(String mediaId, String part) => _failed['$mediaId:$part'];
  bool isActive(String mediaId, String part) => active.containsKey('$mediaId:$part');

  // ---------------- файлы ----------------

  Future<Directory> _dir(String tripId) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'media', tripId));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> _pathFor(String tripId, String mediaId, String part, String ext) async =>
      p.join((await _dir(tripId)).path, '$mediaId.$part$ext');

  static String _ext(String path, String fallback) {
    final e = p.extension(path).toLowerCase();
    return e.isEmpty || e.length > 6 ? fallback : e;
  }

  // ---------------- создание ----------------

  Future<String?> _thumbFromImage(String path) async {
    try {
      final b = await FlutterImageCompress.compressWithFile(path, minWidth: 200, minHeight: 200, quality: 50);
      return b == null ? null : base64Encode(b);
    } catch (e) {
      debugPrint('media: миниатюра: $e');
      return null;
    }
  }

  Future<String?> _thumbFromVideo(String path) async {
    try {
      final tmp = p.join((await getTemporaryDirectory()).path, 'th_${newId()}.jpg');
      final ok = await FcNativeVideoThumbnail()
          .saveThumbnailToFile(srcFile: path, destFile: tmp, width: 240, height: 240, format: 'jpeg', quality: 60);
      if (!ok) return null;
      final t = await _thumbFromImage(tmp);
      try {
        await File(tmp).delete();
      } catch (_) {}
      return t;
    } catch (e) {
      debugPrint('media: кадр видео: $e');
      return null;
    }
  }

  Future<MediaPart> _part(String path) async {
    final f = File(path);
    final size = await f.length();
    final h = await hash.sha256.bind(f.openRead()).first;
    return MediaPart(size, h.toString());
  }

  /// Фото из галереи или с камеры: миниатюра → журнал, просмотр 1600 px, оригинал остаётся у нас.
  Future<void> addPhoto(TripBundle b, String srcPath, {int channel = 0, String? caption}) async {
    final id = newId();
    final t = b.trip.id;
    final orig = await _pathFor(t, id, 'o', _ext(srcPath, '.jpg'));
    await File(srcPath).copy(orig);
    final prevPath = await _pathFor(t, id, 'p', '.jpg');
    final prev = await FlutterImageCompress.compressWithFile(orig, minWidth: 1600, minHeight: 1600, quality: 80);
    if (prev == null) throw 'Не удалось обработать фото';
    await File(prevPath).writeAsBytes(prev);
    final thumb = await _thumbFromImage(prevPath);
    final m = Media(
      id: id,
      tripId: t,
      authorId: b.me?.id,
      kind: MediaKind.photo,
      created: DateTime.now(),
      mime: 'image/jpeg',
      thumb: thumb,
      parts: {'p': await _part(prevPath), 'o': await _part(orig)},
      channel: channel,
      caption: caption,
    );
    await repo.addMedia(m, {'p': prevPath, 'o': orig});
  }

  /// Видео из галереи / с камеры или кружок.
  Future<void> addVideo(TripBundle b, String srcPath, {bool note = false, int durMs = 0, int channel = 0}) async {
    final id = newId();
    final t = b.trip.id;
    final path = await _pathFor(t, id, 'v', _ext(srcPath, '.mp4'));
    await File(srcPath).copy(path);
    final m = Media(
      id: id,
      tripId: t,
      authorId: b.me?.id,
      kind: note ? MediaKind.note : MediaKind.video,
      created: DateTime.now(),
      mime: 'video/mp4',
      durMs: durMs,
      thumb: await _thumbFromVideo(path),
      parts: {'v': await _part(path)},
      channel: channel,
    );
    await repo.addMedia(m, {'v': path});
  }

  Future<void> addVoice(TripBundle b, String srcPath, int durMs, {int channel = 0}) async {
    final id = newId();
    final path = await _pathFor(b.trip.id, id, 'a', _ext(srcPath, '.m4a'));
    await File(srcPath).copy(path);
    final m = Media(
      id: id,
      tripId: b.trip.id,
      authorId: b.me?.id,
      kind: MediaKind.voice,
      created: DateTime.now(),
      mime: 'audio/mp4',
      durMs: durMs,
      parts: {'a': await _part(path)},
      channel: channel,
    );
    await repo.addMedia(m, {'a': path});
  }

  Future<void> addFile(TripBundle b, String srcPath, String name, {String? mime, int channel = 0}) async {
    final id = newId();
    final path = await _pathFor(b.trip.id, id, 'f', _ext(name, ''));
    await File(srcPath).copy(path);
    final lower = name.toLowerCase();
    final isImage = lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp');
    final m = Media(
      id: id,
      tripId: b.trip.id,
      authorId: b.me?.id,
      kind: MediaKind.file,
      created: DateTime.now(),
      name: name,
      mime: mime,
      thumb: isImage ? await _thumbFromImage(path) : null,
      parts: {'f': await _part(path)},
      channel: channel,
    );
    await repo.addMedia(m, {'f': path});
  }

  // ---------------- что качать само ----------------

  /// Можно ли эту часть передавать без кнопки данным путём.
  static bool auto(Media m, String part, Via via) {
    final size = m.parts[part]?.size ?? 0;
    if (part == 'o') return false; // оригинал — только по кнопке
    switch (via) {
      case Via.nearby:
        return size <= 200 * 1024 * 1024;
      case Via.roaming:
        return part == 'a' || (part == 'f' && size <= _roamingFileMax);
      case Via.server:
        if (size > _serverMax) return false;
        if (m.kind == MediaKind.video || part == 'f') return size <= 25 * 1024 * 1024;
        return true;
    }
  }

  // ---------------- обмен ----------------

  void schedule([Duration d = const Duration(seconds: 2)]) {
    _soon?.cancel();
    _soon = Timer(d, pump);
  }

  /// Загрузить свои части на сервер и подтянуть недостающие чужие.
  Future<void> pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      await _uploadAll();
      await _downloadAll();
    } catch (e) {
      debugPrint('media: обмен: $e');
    } finally {
      _pumping = false;
    }
  }

  Future<void> _uploadAll() async {
    if (!serverOn()) return;
    final roaming = isRoaming();
    for (final (m, part, path) in await repo.pendingUploads()) {
      if (roaming && !auto(m, part, Via.roaming)) continue;
      if ((m.parts[part]?.size ?? 0) > _serverMax) {
        await repo.markUploaded(m.id, part); // только рядом
        continue;
      }
      try {
        await _upload(m, part, path);
        await repo.markUploaded(m.id, part);
      } catch (e) {
        debugPrint('media: загрузка ${m.id}.$part: $e');
      }
    }
  }

  Future<void> _downloadAll() async {
    final local = await repo.localMediaFiles();
    final wantNearby = <String, List<String>>{}; // tripId → ["id:part"]
    for (final m in await repo.mediaList()) {
      for (final part in m.parts.keys) {
        if (local[m.id]?.containsKey(part) ?? false) continue;
        final key = '${m.id}:$part';
        if (active.containsKey(key)) continue;
        final last = _lastTry[key];
        if (last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) continue;
        if ((nearby?.peersFor(m.tripId) ?? 0) > 0 && auto(m, part, Via.nearby)) {
          (wantNearby[m.tripId] ??= []).add(key);
          _lastTry[key] = DateTime.now();
          continue;
        }
        final via = isRoaming() ? Via.roaming : Via.server;
        if (serverOn() && auto(m, part, via)) {
          _lastTry[key] = DateTime.now();
          await _fetch(m, part);
        }
      }
    }
    for (final e in wantNearby.entries) {
      nearby?.want(e.key, e.value);
    }
  }

  /// Кнопка «Загрузить»: рядом, если есть свои; иначе через сервер (и в роуминге тоже).
  Future<void> request(Media m, String part) async {
    final key = '${m.id}:$part';
    _failed.remove(key);
    if ((nearby?.peersFor(m.tripId) ?? 0) > 0) {
      active[key] = -1;
      notifyListeners();
      nearby?.want(m.tripId, [key]);
      // если рядом никто не отдаст за 40 с — пробуем сервер
      Future.delayed(const Duration(seconds: 40), () async {
        if (await repo.mediaPath(m.id, part) != null) return;
        active.remove(key);
        if (serverOn() && part != 'o') await _fetch(m, part);
        notifyListeners();
      });
      return;
    }
    if (part == 'o') {
      _failed[key] = 'Оригинал передаётся только рядом';
      notifyListeners();
      return;
    }
    if (!serverOn()) {
      _failed[key] = isRoaming() ? 'Роуминг: интернет выключен' : 'Нет связи';
      notifyListeners();
      return;
    }
    await _fetch(m, part);
  }

  SecretKey _key(String tripId) => SecretKey(hash.sha256.convert(utf8.encode('roamly-key:$tripId')).bytes);

  Uri _blobUri(Media m, String part) => Uri.https(serverHost, '/blob/${NearbySync.tripHash(m.tripId)}/${m.id}.$part');

  Future<void> _upload(Media m, String part, String path) async {
    final key = '${m.id}:$part';
    active[key] = -1;
    notifyListeners();
    try {
      final plain = await File(path).readAsBytes();
      final k = await _key(m.tripId).extractBytes();
      final enc = await compute(_encrypt, [Uint8List.fromList(k), plain]);
      final r = await http.put(_blobUri(m, part), body: enc, headers: {'content-type': 'application/octet-stream'});
      if (r.statusCode != 200) throw 'сервер ответил ${r.statusCode}';
    } finally {
      active.remove(key);
      notifyListeners();
    }
  }

  Future<void> _fetch(Media m, String part) async {
    final key = '${m.id}:$part';
    active[key] = -1;
    notifyListeners();
    try {
      final r = await http.get(_blobUri(m, part));
      if (r.statusCode == 404) {
        _failed[key] = 'Ещё не загружено отправителем';
        return;
      }
      if (r.statusCode != 200) throw 'сервер ответил ${r.statusCode}';
      final k = await _key(m.tripId).extractBytes();
      final plain = await compute(_decrypt, [Uint8List.fromList(k), r.bodyBytes]);
      final tmp = p.join((await getTemporaryDirectory()).path, 'dl_${newId()}');
      await File(tmp).writeAsBytes(plain);
      await accept(m.id, part, tmp);
    } catch (e) {
      _failed[key] = 'Не загрузилось';
      debugPrint('media: скачивание $key: $e');
    } finally {
      active.remove(key);
      notifyListeners();
    }
  }

  /// Часть пришла (рядом или с сервера) во временный файл: проверить и положить на место.
  Future<bool> accept(String mediaId, String part, String tmpPath) async {
    final m = await repo.media(mediaId);
    final want = m?.parts[part];
    if (m == null || want == null) return false;
    final got = await _part(tmpPath);
    if (got.hash != want.hash) {
      debugPrint('media: $mediaId.$part — не совпала контрольная сумма');
      try {
        await File(tmpPath).delete();
      } catch (_) {}
      return false;
    }
    final ext = switch (part) {
      'p' => '.jpg',
      'a' => '.m4a',
      'v' => '.mp4',
      'f' => _ext(m.name ?? '', ''),
      _ => '.jpg',
    };
    final dest = await _pathFor(m.tripId, mediaId, part, ext);
    await File(tmpPath).copy(dest);
    try {
      await File(tmpPath).delete();
    } catch (_) {}
    _failed.remove('$mediaId:$part');
    active.remove('$mediaId:$part');
    await repo.setMediaFile(mediaId, part, dest);
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _soon?.cancel();
    super.dispose();
  }
}

// Шифрование в отдельном потоке: большие файлы не подвешивают экран.
Future<Uint8List> _encrypt(List<Uint8List> a) async {
  final box = await AesGcm.with256bits().encrypt(a[1], secretKey: SecretKey(a[0]));
  return Uint8List.fromList(box.concatenation());
}

Future<Uint8List> _decrypt(List<Uint8List> a) async {
  final box = SecretBox.fromConcatenation(a[1], nonceLength: 12, macLength: 16);
  return Uint8List.fromList(await AesGcm.with256bits().decrypt(box, secretKey: SecretKey(a[0])));
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} КБ';
  return '${(bytes / 1024 / 1024).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} МБ';
}

String formatDur(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
