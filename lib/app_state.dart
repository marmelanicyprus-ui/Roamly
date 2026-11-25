import 'package:flutter/material.dart';

import 'calls/call_service.dart';
import 'data.dart';
import 'sync/nearby_sync.dart';
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
        calls = CallService(repo);
  final Repo repo;

  /// Автоматический обмен с телефонами группы рядом.
  final NearbySync sync;

  /// Обмен через сервер-«почту», когда телефоны не рядом.
  final ServerSync server;

  /// Звонки (LiveKit).
  final CallService calls;

  /// Запуск связи после ввода имени: рядом — всегда, сервер — если не режим «Роуминг».
  void startSync() {
    if (myName.isEmpty) return;
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
