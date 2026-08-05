import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kPrefKey = 'notifications_enabled';

/// Abstração sobre flutter_local_notifications com toggle via SharedPreferences.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  /// Inicializa o plugin. Chamar uma vez em main() antes de runApp.
  static Future<void> initialize() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const linux = LinuxInitializationSettings(defaultActionName: 'Abrir SafeChannel');
    const darwin = DarwinInitializationSettings();

    const settings = InitializationSettings(
      android: android,
      linux: linux,
      iOS: darwin,
      macOS: darwin,
    );

    await _plugin.initialize(settings);
    _initialized = true;
  }

  /// Notifica que um peer entrou no canal.
  static Future<void> notifyPeerJoined(String channelName) async {
    if (!await _shouldNotify()) return;
    await _show(
      id: channelName.hashCode & 0x7FFFFFFF,
      title: 'SafeChannel',
      body: 'Um peer entrou em "$channelName"',
    );
  }

  /// Notifica nova mensagem recebida.
  static Future<void> notifyNewMessage(String channelName, String preview) async {
    if (!await _shouldNotify()) return;
    await _show(
      id: (channelName.hashCode ^ preview.hashCode) & 0x7FFFFFFF,
      title: channelName,
      body: preview,
    );
  }

  /// Retorna true se notificações estão habilitadas pelo usuário.
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPrefKey) ?? true;
  }

  /// Grava a preferência de notificações.
  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefKey, value);
  }

  // ─── Internos ─────────────────────────────────────────────────────────────

  static Future<bool> _shouldNotify() async {
    if (!_initialized) return false;
    return isEnabled();
  }

  static Future<void> _show({required int id, required String title, required String body}) async {
    try {
      NotificationDetails details;

      if (_isDesktop) {
        const linux = LinuxNotificationDetails(
          urgency: LinuxNotificationUrgency.normal,
        );
        details = const NotificationDetails(linux: linux);
      } else if (!kIsWeb && Platform.isAndroid) {
        const android = AndroidNotificationDetails(
          'safechannel_messages',
          'Mensagens',
          importance: Importance.high,
          priority: Priority.high,
          showWhen: true,
        );
        details = const NotificationDetails(android: android);
      } else {
        const darwin = DarwinNotificationDetails();
        details = const NotificationDetails(iOS: darwin, macOS: darwin);
      }

      await _plugin.show(id, title, body, details);
    } catch (e) {
      debugPrint('[NotificationService] show error: $e');
    }
  }
}
