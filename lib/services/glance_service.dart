import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/device_status_service.dart';
import 'package:demo_ai_even/services/notification_policy.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class GlanceService {
  GlanceService._();

  static GlanceService? _instance;
  static GlanceService get get => _instance ??= GlanceService._();

  static const _displayDuration = Duration(seconds: 5);
  static const _maxNotifications = 20;

  final List<CompanionNotification> _notifications = [];
  Timer? _clearTimer;
  int _currentIndex = 0;
  bool _isVisible = false;
  String? _pendingDismissKey;
  Future<void> _renderChain = Future<void>.value();

  bool get isVisible => _isVisible;
  int get notificationCount => _notifications.length;
  bool get isInActiveRecall => _isVisible;

  List<CompanionNotification> get notifications =>
      List<CompanionNotification>.unmodifiable(_notifications);

  void hydrateNotifications(List<CompanionNotification> notifications) {
    _notifications
      ..clear()
      ..addAll(notifications.take(_maxNotifications));
    if (_notifications.isEmpty) {
      _currentIndex = 0;
    } else if (_currentIndex >= _notifications.length) {
      _currentIndex = 0;
    }
    AppLog.debug(
      '${DateTime.now()} hydrated notifications -> count=${_notifications.length}',
      tag: 'Glance',
    );
  }

  Future<void> ingestNotification(
    CompanionNotification notification, {
    bool autoPop = true,
  }) async {
    _notifications.removeWhere((item) => item.key == notification.key);
    _notifications.insert(0, notification);
    if (_notifications.length > _maxNotifications) {
      _notifications.removeRange(_maxNotifications, _notifications.length);
    }
    _currentIndex = 0;
    AppLog.debug(
      '${DateTime.now()} notification received -> ${notification.source}',
      tag: 'Glance',
    );
    if (autoPop) {
      if (_isVisible) {
        AppLog.debug(
          '${DateTime.now()} notification queued while visible -> ${notification.source}',
          tag: 'Glance',
        );
      } else {
        await _enqueueRender(autoHide: true, markInteracted: false);
      }
    }
  }

  Future<void> removeNotificationByKey(String key) async {
    var shouldRefresh = false;
    final current = _currentNotification();
    if (current?.key == key) {
      shouldRefresh = _isVisible;
    }
    _notifications.removeWhere((item) => item.key == key);
    if (_notifications.isEmpty) {
      _currentIndex = 0;
    } else if (_currentIndex >= _notifications.length) {
      _currentIndex = 0;
    }
    if (shouldRefresh) {
      if (_currentNotification() == null) {
        _isVisible = false;
        _pendingDismissKey = null;
        await TextService.get.stopTextSendingByOS();
        await Proto.exit();
        AppLog.info(
          '${DateTime.now()} cleared after notification removal',
          tag: 'Glance',
        );
      } else {
        await _enqueueRender(autoHide: false, markInteracted: false);
      }
    }
  }

  Future<void> showLatestOrAdvance() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    if (!_isVisible) {
      _currentIndex = 0;
    } else if (_notifications.isNotEmpty) {
      await _advanceFromCurrentInteraction();
      if (_notifications.isEmpty) {
        _currentIndex = 0;
      } else if (_currentIndex >= _notifications.length) {
        _currentIndex = 0;
      }
    }
    await _enqueueRender(autoHide: false, markInteracted: true);
  }

  void startLookDownTimeout() {
    if (!_isVisible) {
      return;
    }
    _restartClearTimer();
    AppLog.debug(
      '${DateTime.now()} tilt-down timeout started',
      tag: 'Glance',
    );
  }

  Future<void> close() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    await _dismissPendingNotificationOnPhone();
    _isVisible = false;
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    AppLog.info('${DateTime.now()} closed', tag: 'Glance');
  }

  Future<bool> showIdleSurfaceIfAvailable() async {
    return false;
  }

  Future<void> _enqueueRender({
    required bool autoHide,
    required bool markInteracted,
  }) {
    _renderChain = _renderChain.then((_) {
      return _renderCurrent(autoHide: autoHide, markInteracted: markInteracted);
    });
    return _renderChain;
  }

  Future<void> _renderCurrent({
    required bool autoHide,
    required bool markInteracted,
  }) async {
    final now = DateTime.now();
    final text = _buildDisplayText(now);
    _isVisible = true;
    await TextService.get.startSendText(text);
    if (markInteracted) {
      final current = _currentNotification();
      _pendingDismissKey =
          current != null && NotificationPolicy.canDismissFromGlance(current)
              ? current.key
              : null;
    } else {
      _pendingDismissKey = null;
    }
    if (autoHide) {
      _restartClearTimer();
    } else {
      _clearTimer?.cancel();
      _clearTimer = null;
    }
    AppLog.debug(
      '${DateTime.now()} render -> index=$_currentIndex count=${_notifications.length}',
      tag: 'Glance',
    );
  }

  String _buildDisplayText(DateTime now) {
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final batteryLabel = DeviceStatusService.get.glassesBatteryLabel;
    final timeLine = batteryLabel == null
        ? '$hour:$minute'
        : '$hour:$minute  $batteryLabel';
    final current = _currentNotification();
    if (current == null) {
      return '$timeLine\n--\nNo notifications';
    }
    return '$timeLine\n--\n${current.source}\n${current.message}';
  }

  CompanionNotification? _currentNotification() {
    if (_notifications.isEmpty) {
      return null;
    }
    return _notifications[_currentIndex];
  }

  Future<void> _dismissPendingNotificationOnPhone() async {
    final key = _pendingDismissKey;
    _pendingDismissKey = null;
    if (key == null || key.isEmpty) {
      return;
    }
    try {
      await BleManager.invokeMethod(
        'dismissNotification',
        {'key': key},
      );
      _notifications.removeWhere((item) => item.key == key);
      if (_notifications.isEmpty) {
        _currentIndex = 0;
      } else if (_currentIndex >= _notifications.length) {
        _currentIndex = 0;
      }
      AppLog.info(
        '${DateTime.now()} dismissed notification on phone -> $key',
        tag: 'Glance',
      );
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} dismiss notification failed -> $e',
        tag: 'Glance',
      );
    }
  }

  Future<void> _advanceFromCurrentInteraction() async {
    final current = _currentNotification();
    if (current == null) {
      _pendingDismissKey = null;
      return;
    }

    if (NotificationPolicy.canDismissFromGlance(current)) {
      await _dismissPendingNotificationOnPhone();
      return;
    }

    _pendingDismissKey = null;
    if (_notifications.length <= 1) {
      return;
    }
    _currentIndex = (_currentIndex + 1) % _notifications.length;
    AppLog.debug(
      '${DateTime.now()} advanced protected notification without dismiss -> ${current.packageName}',
      tag: 'Glance',
    );
  }

  void _restartClearTimer() {
    _clearTimer?.cancel();
    _clearTimer = Timer(_displayDuration, () {
      close();
    });
  }
}
