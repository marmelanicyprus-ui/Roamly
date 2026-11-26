import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app_state.dart';
import 'calls/call_screen.dart';
import 'data.dart';
import 'invite_code.dart';
import 'sync/push.dart';
import 'screens/home.dart';
import 'screens/join.dart';
import 'screens/onboarding.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  final repo = await Repo.open();
  final state = AppState(repo);
  await state.load();
  runApp(App(state: state, child: const RoamlyApp()));
}

class RoamlyApp extends StatefulWidget {
  const RoamlyApp({super.key});
  @override
  State<RoamlyApp> createState() => _RoamlyAppState();
}

class _RoamlyAppState extends State<RoamlyApp> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _links;
  InvitePayload? _pending; // ссылка пришла до ввода имени

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Связь запускаем после первого кадра: системе нужен экран для запроса разрешений.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = App.read(context);
      s.startSync();
      s.calls.incoming.addListener(_showIncoming);
      Push.init(onMessage: s.server.poke).then((token) {
        if (token != null) s.server.setPushToken(token);
      });
      Push.onTokenRefresh(s.server.setPushToken);
    });
    // Ссылка roamly://join?... из камеры телефона или мессенджера открывает экран присоединения.
    _links = AppLinks().uriLinkStream.listen((uri) {
      final p = parseInvite(uri.toString());
      if (p == null) return;
      _pending = p;
      _openPending();
    });
  }

  void _openPending() {
    final p = _pending;
    if (p == null) return;
    final s = App.read(context);
    if (s.myName.isEmpty) return; // откроем после онбординга
    _pending = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => JoinScreen(payload: p)));
    });
  }

  /// Вернулись в приложение — сразу забрать новое с сервера.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) App.read(context).server.poke();
  }

  Future<void> _showIncoming() async {
    final s = App.read(context);
    final c = s.calls.incoming.value;
    if (c == null) return;
    s.calls.incoming.value = null;
    String tripName = '';
    try {
      final b = await s.repo.bundle(c.tripId);
      tripName = b.trip.isDirect ? 'личный звонок' : b.trip.name;
    } catch (_) {}
    navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => IncomingCallScreen(tripId: c.tripId, tripName: tripName, room: c.room, name: c.name, video: c.video),
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = App.of(context);
    if (s.myName.isNotEmpty && _pending != null) _openPending();
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Roamly offline',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: s.themeMode,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: s.myName.isEmpty ? const OnboardingScreen() : const HomeScreen(),
    );
  }
}
