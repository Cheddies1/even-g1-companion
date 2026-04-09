import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/companion_notification.dart';
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
    print(
      '${DateTime.now()} Glance: hydrated notifications -> count=${_notifications.length}',
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
    print(
      '${DateTime.now()} Glance: notification received -> ${notification.source}',
    );
    if (autoPop) {
      if (_isVisible) {
        print(
          '${DateTime.now()} Glance: notification queued while visible -> ${notification.source}',
        );
      } else {
        await _enqueueRender(autoHide: true, markInteracted: false);
      }
    }
  }

  Future<void> showLatestOrAdvance() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    if (!_isVisible) {
      _currentIndex = 0;
    } else if (_notifications.isNotEmpty) {
      await _dismissPendingNotificationOnPhone();
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
    print('${DateTime.now()} Glance: tilt-down timeout started');
  }

  Future<void> close() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    _isVisible = false;
    await _dismissPendingNotificationOnPhone();
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Glance: closed');
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
      _pendingDismissKey = _currentNotification()?.key;
    } else {
      _pendingDismissKey = null;
    }
    if (autoHide) {
      _restartClearTimer();
    }
    print(
      '${DateTime.now()} Glance: render -> index=$_currentIndex count=${_notifications.length}',
    );
  }

  String _buildDisplayText(DateTime now) {
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final current = _currentNotification();
    if (current == null) {
      return '$hour:$minute\n--\nNo notifications';
    }
    return '$hour:$minute\n--\n${current.source}\n${current.message}';
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
      print(
        '${DateTime.now()} Glance: dismissed notification on phone -> $key',
      );
    } catch (e) {
      print('${DateTime.now()} Glance: dismiss notification failed -> $e');
    }
  }

  void _restartClearTimer() {
    _clearTimer?.cancel();
    _clearTimer = Timer(_displayDuration, () {
      close();
    });
  }
}
