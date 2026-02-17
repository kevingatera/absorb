import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Manages a persistent notification during audiobook downloads.
/// Shows progress bar, book title, and "Done" when complete.
class DownloadNotificationService {
  // Singleton
  static final DownloadNotificationService _instance = DownloadNotificationService._();
  factory DownloadNotificationService() => _instance;
  DownloadNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId = 'absorb_downloads';
  static const _channelName = 'Downloads';
  static const _channelDesc = 'Audiobook download progress';
  static const _notificationId = 9001;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings);

    // Create the notification channel (Android 8+)
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.low, // Low = no sound, still visible
          showBadge: false,
        ),
      );
      // Request notification permission (Android 13+)
      await androidPlugin.requestNotificationsPermission();
    }

    _initialized = true;
  }

  /// Show or update the download progress notification.
  Future<void> showProgress({
    required String title,
    required double progress,
    String? author,
  }) async {
    if (!_initialized) await init();

    final percent = (progress * 100).round().clamp(0, 100);
    final subtitle = author != null && author.isNotEmpty
        ? '$author • $percent%'
        : '$percent%';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      category: AndroidNotificationCategory.progress,
      icon: '@mipmap/ic_launcher',
    );

    await _plugin.show(
      _notificationId,
      'Downloading: $title',
      subtitle,
      NotificationDetails(android: androidDetails),
    );
  }

  /// Show a completion notification.
  Future<void> showComplete({required String title}) async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    await _plugin.show(
      _notificationId,
      'Download Complete',
      title,
      const NotificationDetails(android: androidDetails),
    );
  }

  /// Show an error notification.
  Future<void> showError({required String title, String? message}) async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    await _plugin.show(
      _notificationId,
      'Download Failed',
      message ?? title,
      const NotificationDetails(android: androidDetails),
    );
  }

  /// Dismiss the notification.
  Future<void> dismiss() async {
    await _plugin.cancel(_notificationId);
  }
}
