// Push через Firebase Cloud Messaging: будит телефон, когда пришло новое, а приложение закрыто.
// В push нет содержимого — только «есть новое в поездке» или «входящий звонок»;
// сами записи телефон забирает с сервера и расшифровывает у себя.
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Настройки проекта Firebase «Roamly offline» (не секрет: они есть в любом APK).
const firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCWkVcZ43CbgNozuW608Nb2kAa5nXPtehQ',
  appId: '1:66013988677:android:5f923bd27f375c9a2aa02c',
  messagingSenderId: '66013988677',
  projectId: 'roamly-offline',
);

/// Push в фоне: уведомление показывает сама система, здесь ничего делать не нужно.
@pragma('vm:entry-point')
Future<void> _onBackground(RemoteMessage m) async {}

class Push {
  /// Запуск: разрешение на уведомления и токен этого телефона (null — push недоступен).
  static Future<String?> init({required VoidCallback onMessage}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null; // iPhone — позже
    try {
      await Firebase.initializeApp(options: firebaseOptions);
      FirebaseMessaging.onBackgroundMessage(_onBackground);
      await FirebaseMessaging.instance.requestPermission();
      FirebaseMessaging.onMessage.listen((_) => onMessage());
      FirebaseMessaging.onMessageOpenedApp.listen((_) => onMessage());
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('push: недоступен: $e');
      return null;
    }
  }

  static void onTokenRefresh(void Function(String) cb) {
    try {
      FirebaseMessaging.instance.onTokenRefresh.listen(cb);
    } catch (_) {}
  }
}
