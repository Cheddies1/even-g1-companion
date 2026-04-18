import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/models/glance_idle_score_card.dart';
import 'package:demo_ai_even/services/notification_policy.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class GlanceService {
  GlanceService._();

  static GlanceService? _instance;
  static GlanceService get get => _instance ??= GlanceService._();

  static const _displayDuration = Duration(seconds: 5);
  static const _idleScoreRotationDuration = Duration(seconds: 7);
  static const _maxNotifications = 20;

  final List<CompanionNotification> _notifications = [];
  final List<GlanceIdleScoreCard> _idleScoreCards = [];
  Timer? _clearTimer;
  Timer? _idleScoreRotationTimer;
  int _currentIndex = 0;
  int _idleScoreIndex = 0;
  bool _isVisible = false;
  bool _isShowingIdleLiveScore = false;
  bool _preferQueueView = false;
  String? _pendingDismissKey;
  Future<void> _renderChain = Future<void>.value();

  bool get isVisible => _isVisible;
  int get notificationCount => _notifications.length;
  bool get isShowingIdleLiveScore => _isShowingIdleLiveScore;
  bool get isInActiveRecall => _isVisible && !_isShowingIdleLiveScore;

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

  Future<void> setIdleScoreCards(
    List<GlanceIdleScoreCard> cards, {
    bool autoPop = true,
  }) async {
    final currentId = _currentIdleScoreCard()?.id;
    _idleScoreCards
      ..clear()
      ..addAll(cards);

    if (_idleScoreCards.isEmpty) {
      _idleScoreIndex = 0;
      _idleScoreRotationTimer?.cancel();
      _idleScoreRotationTimer = null;
      if (_isShowingIdleLiveScore && _notifications.isEmpty) {
        _isVisible = false;
        _isShowingIdleLiveScore = false;
        _preferQueueView = false;
        await TextService.get.stopTextSendingByOS();
        await Proto.exit();
        print('${DateTime.now()} Glance: cleared idle score surface');
      }
      return;
    }

    if (currentId != null) {
      final preservedIndex =
          _idleScoreCards.indexWhere((card) => card.id == currentId);
      _idleScoreIndex = preservedIndex >= 0 ? preservedIndex : 0;
    } else if (_idleScoreIndex >= _idleScoreCards.length) {
      _idleScoreIndex = 0;
    }

    print(
      '${DateTime.now()} Glance: idle score cards updated -> count=${_idleScoreCards.length}',
    );

    if (autoPop && !_isVisible && _notifications.isEmpty) {
      await showIdleSurfaceIfAvailable();
      return;
    }
    if (_isShowingIdleLiveScore) {
      await showIdleSurfaceIfAvailable();
      return;
    }
    _syncIdleScoreRotation();
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
      if (_isShowingIdleLiveScore) {
        _preferQueueView = true;
        await _enqueueRender(autoHide: true, markInteracted: false);
      } else if (_isVisible) {
        print(
          '${DateTime.now()} Glance: notification queued while visible -> ${notification.source}',
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
        final restored = await showIdleSurfaceIfAvailable();
        if (!restored) {
          _isVisible = false;
          _isShowingIdleLiveScore = false;
          _preferQueueView = false;
          _pendingDismissKey = null;
          await TextService.get.stopTextSendingByOS();
          await Proto.exit();
          print('${DateTime.now()} Glance: cleared after notification removal');
        }
      } else {
        await _enqueueRender(autoHide: false, markInteracted: false);
      }
    }
  }

  Future<void> showLatestOrAdvance() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    _preferQueueView = true;
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
    print('${DateTime.now()} Glance: tilt-down timeout started');
  }

  Future<void> close() async {
    final wasShowingIdleLiveScore = _isShowingIdleLiveScore;
    _clearTimer?.cancel();
    _clearTimer = null;
    _idleScoreRotationTimer?.cancel();
    _idleScoreRotationTimer = null;
    await _dismissPendingNotificationOnPhone();
    _isShowingIdleLiveScore = false;
    _preferQueueView = false;
    if (!wasShowingIdleLiveScore && await showIdleSurfaceIfAvailable()) {
      return;
    }
    _isVisible = false;
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Glance: closed');
  }

  Future<bool> showIdleSurfaceIfAvailable() async {
    if (_idleScoreCards.isEmpty || _notifications.isNotEmpty) {
      _syncIdleScoreRotation();
      return false;
    }
    final currentCard = _currentIdleScoreCard();
    if (currentCard == null) {
      _syncIdleScoreRotation();
      return false;
    }
    _clearTimer?.cancel();
    _clearTimer = null;
    _isVisible = true;
    _isShowingIdleLiveScore = true;
    _pendingDismissKey = null;
    _preferQueueView = false;
    await TextService.get.startSendText(currentCard.displayText);
    _syncIdleScoreRotation();
    print('${DateTime.now()} Glance: render -> idle-live-score');
    return true;
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
    _isShowingIdleLiveScore = _currentNotification() == null &&
        !_preferQueueView &&
        _currentIdleScoreCard() != null;
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
    _syncIdleScoreRotation();
    print(
      '${DateTime.now()} Glance: render -> index=$_currentIndex count=${_notifications.length}',
    );
  }

  String _buildDisplayText(DateTime now) {
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final current = _currentNotification();
    if (current == null) {
      final liveScore = _currentIdleScoreCard();
      if (liveScore != null && !_preferQueueView) {
        return liveScore.displayText;
      }
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

  GlanceIdleScoreCard? _currentIdleScoreCard() {
    if (_idleScoreCards.isEmpty) {
      return null;
    }
    if (_idleScoreIndex >= _idleScoreCards.length) {
      _idleScoreIndex = 0;
    }
    return _idleScoreCards[_idleScoreIndex];
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
    print(
      '${DateTime.now()} Glance: advanced protected notification without dismiss -> ${current.packageName}',
    );
  }

  void _restartClearTimer() {
    _clearTimer?.cancel();
    _clearTimer = Timer(_displayDuration, () {
      close();
    });
  }

  void _syncIdleScoreRotation() {
    final shouldRotate = _isShowingIdleLiveScore &&
        !_preferQueueView &&
        _currentNotification() == null &&
        _idleScoreCards.length > 1;
    if (!shouldRotate) {
      _idleScoreRotationTimer?.cancel();
      _idleScoreRotationTimer = null;
      return;
    }
    _idleScoreRotationTimer ??= Timer.periodic(
      _idleScoreRotationDuration,
      (_) async {
        if (!_isShowingIdleLiveScore ||
            _preferQueueView ||
            _currentNotification() != null ||
            _idleScoreCards.length <= 1) {
          _syncIdleScoreRotation();
          return;
        }
        _idleScoreIndex = (_idleScoreIndex + 1) % _idleScoreCards.length;
        await showIdleSurfaceIfAvailable();
      },
    );
  }
}
