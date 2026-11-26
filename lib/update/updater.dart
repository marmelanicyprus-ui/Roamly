// Обновление приложения прямо из Roamly.
// CI кладёт рядом с APK файл version.json {version, build, notes, size, sha256}.
// Приложение проверяет его при запуске и раз в 6 часов; новую версию скачивает по кнопке
// и открывает системную установку (Android вне Google Play всегда спрашивает «Установить?»).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _base = 'https://github.com/marmelanicyprus-ui/Roamly/releases/download/android';

class UpdateInfo {
  final String version;
  final int build;
  final String notes;
  final int size;
  final String? sha256;
  UpdateInfo(this.version, this.build, this.notes, this.size, this.sha256);
}

class Updater extends ChangeNotifier {
  Updater({required this.isRoaming});
  final bool Function() isRoaming;

  String current = '';
  int currentBuild = 0;
  UpdateInfo? available; // новее установленной
  double? progress; // 0..1 — качается
  String? error;
  bool installing = false;
  DateTime? _lastCheck;
  bool dismissed = false; // «позже» — до следующего запуска

  /// Проверить, есть ли новая версия. [force] — вручную из меню (и в роуминге тоже).
  Future<bool> check({bool force = false}) async {
    if (!force) {
      if (isRoaming()) return false;
      if (_lastCheck != null && DateTime.now().difference(_lastCheck!) < const Duration(hours: 6)) return available != null;
    }
    _lastCheck = DateTime.now();
    try {
      if (currentBuild == 0) {
        final p = await PackageInfo.fromPlatform();
        current = p.version;
        currentBuild = int.tryParse(p.buildNumber) ?? 0;
      }
      final r = await http
          .get(Uri.parse('$_base/version.json?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'сервер ответил ${r.statusCode}';
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final info = UpdateInfo(
        j['version'] as String? ?? '',
        (j['build'] as num?)?.toInt() ?? 0,
        j['notes'] as String? ?? '',
        (j['size'] as num?)?.toInt() ?? 0,
        j['sha256'] as String?,
      );
      available = info.build > currentBuild ? info : null;
      error = null;
    } catch (e) {
      debugPrint('update: $e');
      if (force) error = 'Не удалось проверить: нет связи';
    }
    notifyListeners();
    return available != null;
  }

  /// Скачать и открыть установку.
  void install() {
    final info = available;
    if (info == null || progress != null) return;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      OtaUpdate()
          .execute('$_base/roamly-${info.version}.apk', destinationFilename: 'roamly.apk', sha256checksum: info.sha256)
          .listen(
        (OtaEvent e) {
          switch (e.status) {
            case OtaStatus.DOWNLOADING:
              progress = (double.tryParse(e.value ?? '') ?? 0) / 100;
            case OtaStatus.INSTALLING:
              progress = null;
              installing = true;
            case OtaStatus.INSTALLATION_DONE:
              progress = null;
              installing = false;
            default:
              progress = null;
              installing = false;
              error = switch (e.status) {
                OtaStatus.PERMISSION_NOT_GRANTED_ERROR => 'Разрешите Roamly устанавливать приложения (спросит Android)',
                OtaStatus.CHECKSUM_ERROR => 'Файл скачался с ошибкой, попробуйте ещё раз',
                OtaStatus.DOWNLOAD_ERROR => 'Не скачалось: нет связи',
                _ => 'Не получилось обновить: ${e.value ?? e.status.name}',
              };
          }
          notifyListeners();
        },
        onError: (Object err) {
          progress = null;
          error = 'Не получилось обновить: $err';
          notifyListeners();
        },
      );
    } catch (e) {
      progress = null;
      error = 'Не получилось обновить: $e';
      notifyListeners();
    }
  }

  void later() {
    dismissed = true;
    notifyListeners();
  }
}
