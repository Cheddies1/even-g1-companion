import 'dart:async';

import 'package:demo_ai_even/services/dashboard_bitmap_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';
import 'package:flutter/services.dart';

enum DashboardState {
  dashboardClosed,
  dashboardOpen,
}

class DashboardNotification {
  const DashboardNotification({
    required this.source,
    required this.message,
  });

  final String source;
  final String message;
}

class DashboardService {
  DashboardService._() {
    if (_customDashboardRenderingEnabled) {
      _startWarmCacheLoop();
      unawaited(_warmDashboardCache(reason: 'init'));
    }
  }

  static const _autoCloseDelay = Duration(seconds: 8);
  static const _cacheWarmInterval = Duration(seconds: 15);
  static const _channel = MethodChannel('method.bluetooth');
  static const _customDashboardRenderingEnabled = false;

  static DashboardService? _instance;
  static DashboardService get get => _instance ??= DashboardService._();

  List<DashboardNotification> _notifications = const [
    DashboardNotification(
      source: 'Calendar',
      message: 'Standup in 15 minutes',
    ),
    DashboardNotification(
      source: 'Messages',
      message: 'Alex: Can you review the BLE logs?',
    ),
    DashboardNotification(
      source: 'Email',
      message: 'Design sync moved to 3:30 PM',
    ),
  ];

  DashboardState state = DashboardState.dashboardClosed;
  int currentNotificationIndex = 0;
  Timer? _autoCloseTimer;
  Timer? _cacheWarmTimer;
  String? _lastPrimedMinuteKey;
  String? _lastPrimedFeedSignature;
  bool _isWarmingCache = false;

  bool get isOpen => state == DashboardState.dashboardOpen;

  void setNotifications(List<DashboardNotification> notifications) {
    _notifications = List<DashboardNotification>.from(notifications);
    if (_notifications.isEmpty) {
      currentNotificationIndex = 0;
    } else if (currentNotificationIndex >= _notifications.length) {
      currentNotificationIndex = 0;
    }
    print(
      '${DateTime.now()} Dashboard: feed updated -> count=${_notifications.length}',
    );
    if (_customDashboardRenderingEnabled) {
      unawaited(_warmDashboardCache(reason: 'feed-update'));
    }
  }

  Future<void> openOrAdvanceDashboard() async {
    cancelAutoCloseCountdown();

    if (!isOpen) {
      if (_customDashboardRenderingEnabled) {
        await _warmDashboardCache(reason: 'open');
      }
      final now = DateTime.now();
      currentNotificationIndex = 0;
      state = DashboardState.dashboardOpen;
      print(
        '${DateTime.now()} Dashboard: opened -> notificationIndex=$currentNotificationIndex',
      );
      await _renderCurrentCard(now: now);
      return;
    }

    if (_notifications.isNotEmpty) {
      currentNotificationIndex =
          (currentNotificationIndex + 1) % _notifications.length;
    }
    print(
      '${DateTime.now()} Dashboard: tilt-up next -> notificationIndex=$currentNotificationIndex',
    );
    await _renderCurrentCard();
  }

  Future<void> _syncNotificationsFromNative() async {
    try {
      final rawNotifications = await _channel.invokeMethod<List<dynamic>>(
        'getRecentNotifications',
      );
      if (rawNotifications == null) {
        return;
      }
      final notifications = rawNotifications
          .whereType<Map>()
          .map(
            (raw) => DashboardNotification(
              source: (raw['source'] as String?)?.trim().isNotEmpty == true
                  ? raw['source'] as String
                  : 'Notification',
              message: (raw['message'] as String?)?.trim().isNotEmpty == true
                  ? raw['message'] as String
                  : 'Open your phone for details',
            ),
          )
          .toList();
      setNotifications(notifications);
    } on PlatformException catch (e) {
      print(
        '${DateTime.now()} Dashboard: notification sync unavailable -> ${e.message}',
      );
    }
  }

  Future<void> closeDashboard({bool sendExitCommand = false}) async {
    if (!isOpen) {
      print('${DateTime.now()} Dashboard: close ignored -> dashboard closed');
      return;
    }

    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
    state = DashboardState.dashboardClosed;
    currentNotificationIndex = 0;
    print('${DateTime.now()} Dashboard: closed -> idle');
    if (_customDashboardRenderingEnabled) {
      await TextService.get.stopTextSendingByOS();
    }
    if (_customDashboardRenderingEnabled && sendExitCommand) {
      final didExit = await Proto.exit();
      print('${DateTime.now()} Dashboard: sent exit command -> success=$didExit');
    }
  }

  void reset() {
    cancelAutoCloseCountdown();
    state = DashboardState.dashboardClosed;
    currentNotificationIndex = 0;
    print('${DateTime.now()} Dashboard: reset');
  }

  void startAutoCloseCountdownOnTiltDown() {
    if (!isOpen) {
      print(
        '${DateTime.now()} Dashboard: tilt-down ignored -> dashboard closed',
      );
      return;
    }
    _restartAutoCloseTimer();
    print(
      '${DateTime.now()} Dashboard: tilt-down -> auto-close countdown started',
    );
  }

  void cancelAutoCloseCountdown() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
  }

  Future<void> _renderCurrentCard({DateTime? now}) async {
    if (!_customDashboardRenderingEnabled) {
      print(
        '${DateTime.now()} Dashboard: custom rendering disabled -> firmware dashboard left untouched',
      );
      return;
    }

    final renderTime = now ?? DateTime.now();
    final notification = _currentNotification();
    print(
      '${DateTime.now()} Dashboard: render -> notificationIndex=$currentNotificationIndex',
    );
    try {
      await DashboardBitmapService.get.renderAndSend(
        now: renderTime,
        notification: notification,
      );
    } catch (e) {
      final hour = renderTime.hour.toString().padLeft(2, '0');
      final minute = renderTime.minute.toString().padLeft(2, '0');
      final text = notification == null
          ? 'Time\n$hour:$minute\n\nNo notifications'
          : 'Time\n$hour:$minute\n\n${notification.source}\n${notification.message}';
      print('${DateTime.now()} Dashboard: bitmap render failed -> $e');
      await TextService.get.startSendText(text);
    }
  }

  DashboardNotification? _currentNotification() {
    if (_notifications.isEmpty) {
      return null;
    }
    return _notifications[currentNotificationIndex];
  }

  void _restartAutoCloseTimer() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(_autoCloseDelay, () {
      print('${DateTime.now()} Dashboard: auto-close after inactivity');
      closeDashboard(sendExitCommand: true);
    });
  }

  void _startWarmCacheLoop() {
    _cacheWarmTimer?.cancel();
    _cacheWarmTimer = Timer.periodic(_cacheWarmInterval, (_) {
      unawaited(_warmDashboardCache(reason: 'timer'));
    });
  }

  Future<void> _warmDashboardCache({required String reason}) async {
    if (!_customDashboardRenderingEnabled) {
      return;
    }

    if (_isWarmingCache) {
      return;
    }

    final now = DateTime.now();
    final minuteKey = _minuteKey(now);
    final feedSignature = _feedSignature(_notifications);
    final shouldRefresh =
        reason == 'open' ||
        reason == 'init' ||
        _lastPrimedMinuteKey != minuteKey ||
        _lastPrimedFeedSignature != feedSignature;

    if (!shouldRefresh) {
      return;
    }

    _isWarmingCache = true;
    try {
      await _syncNotificationsFromNative();
      final refreshedNow = DateTime.now();
      await DashboardBitmapService.get.primeCache(
        now: refreshedNow,
        notifications: _notifications,
      );
      _lastPrimedMinuteKey = _minuteKey(refreshedNow);
      _lastPrimedFeedSignature = _feedSignature(_notifications);
      print(
        '${DateTime.now()} Dashboard: cache warmed -> reason=$reason, minute=$_lastPrimedMinuteKey, count=${_notifications.length}',
      );
    } finally {
      _isWarmingCache = false;
    }
  }

  String _minuteKey(DateTime now) =>
      '${now.year}-${now.month}-${now.day}-${now.hour}-${now.minute}';

  String _feedSignature(List<DashboardNotification> notifications) {
    return notifications
        .map((notification) => '${notification.source}|${notification.message}')
        .join('||');
  }
}
