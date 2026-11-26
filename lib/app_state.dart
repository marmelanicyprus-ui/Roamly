import 'package:flutter/material.dart';

import 'calls/call_service.dart';
import 'data.dart';
import 'media/media_service.dart';
import 'sync/nearby_sync.dart';
import 'sync/direct.dart';
import 'sync/server_sync.dart';

enum TrafficMode { normal, economy, essential, roaming }

extension TrafficModeX on TrafficMode {
  String get label => switch (this) {
        TrafficMode.normal => 'Обычный',
        TrafficMode.economy => 'Экономия',
        TrafficMode.essential => 'Только важное',
        TrafficMode.roaming => 'Роуминг',
      };
}

/// Глобальные настройки и доступ к хранилищу.
class AppState extends ChangeNotifier {
  AppState(this.repo)
      : sync = NearbySync(repo),
        server = ServerSync(repo),
        calls = CallService(repo),
        direct = DirectService(repo) {
    media = MediaService(repo,
        isRoaming: () => traffic == TrafficMode.roaming, serverOn: () => server.state == ServerState.online);
    media.nearby = sync;
    sync.onFile = media.accept;
    sync.localFile = repo.mediaPath;
    sync.onPeer = media.schedule;
    server.addListener(() {
      if (server.state == ServerState.online) media.schedule();
    });
  }
  final Repo repo;

  /// Вложения: фото, видео, кружки, голосовые, файлы.
  late final MediaService media;

  /// Автоматический обмен с телефонами группы рядом.
  final NearbySync sync;

  /// Обмен через сервер-«почту», когда телефоны не рядом.
  final ServerSync server;

  /// Звонки (LiveKit).
  final CallService calls;

  /// Личные чаты, ключ телефона, отметки «доставлено/прочитано».
  final DirectService direct;

  /// Запуск связи после ввода имени: рядом — всегда, сервер — если не режим «Роуминг».
  void startSync() {
    direct.myName = myName;
    if (myName.isEmpty) return;
    direct.ensureIdent().catchError((_) => 0);
    sync.start();
    server.setEnabled(traffic != TrafficMode.roaming);
  }

  String myName = '';
  ThemeMode themeMode = ThemeMode.system;
  TrafficMode traffic = TrafficMode.normal;

  Future<void> load() async {
    myName = await repo.getSetting('my_name') ?? '';
    themeMode = ThemeMode.values[int.tryParse(await repo.getSetting('theme') ?? '') ?? 0];
    traffic = TrafficMode.values[int.tryParse(await repo.getSetting('traffic') ?? '') ?? 0];
  }

  Future<void> setName(String v) async {
    myName = v.trim();
    await repo.setSetting('my_name', myName);
    notifyListeners();
    startSync();
  }

  Future<void> setTheme(ThemeMode m) async {
    themeMode = m;
    await repo.setSetting('theme', m.index.toString());
    notifyListeners();
  }

  Future<void> setTraffic(TrafficMode m) async {
    traffic = m;
    await repo.setSetting('traffic', m.index.toString());
    notifyListeners();
    server.setEnabled(myName.isNotEmpty && m != TrafficMode.roaming);
  }
}

/// Даёт доступ к AppState из любого экрана: App.of(context).
class App extends InheritedNotifier<AppState> {
  const App({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<App>()!.notifier!;

  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<App>()!.notifier!;
}
