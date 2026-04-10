import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/app_mode.dart';
import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/capture_service.dart';
import 'package:demo_ai_even/services/chat_service.dart';
import 'package:demo_ai_even/services/glance_service.dart';
import 'package:demo_ai_even/services/navigate_service.dart';
import 'package:demo_ai_even/services/notification_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CompanionController extends ChangeNotifier {
  CompanionController._();

  static CompanionController? _instance;
  static CompanionController get get => _instance ??= CompanionController._();

  static const _eventNotifications = 'eventNotifications';
  final EventChannel _notificationChannel = const EventChannel(_eventNotifications);
  bool _lastReportedHasActiveDisplay = false;

  bool _initialized = false;
  StreamSubscription<dynamic>? _notificationSubscription;
  AppMode _activeMode = AppMode.glance;
  String _statusMessage = 'Ready';
  bool _notificationAccessEnabled = false;

  AppMode get activeMode => _activeMode;
  String get statusMessage => _statusMessage;
  bool get notificationAccessEnabled => _notificationAccessEnabled;
  bool get hasActiveDisplay =>
      GlanceService.get.isVisible ||
      CaptureService.get.isDisplayVisible ||
      NavigateService.get.isVisible ||
      ChatService.get.isDisplayVisible;

  String get _activeDisplayOwner {
    if (GlanceService.get.isVisible) {
      return 'Glance';
    }
    if (CaptureService.get.isDisplayVisible) {
      return 'Capture';
    }
    if (NavigateService.get.isVisible) {
      return 'Navigate';
    }
    if (ChatService.get.isDisplayVisible) {
      return 'Chat';
    }
    return 'none';
  }

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    print('${DateTime.now()} Companion: init begin');
    BleManager.get().setMethodCallHandler();
    BleManager.get().startListening();
    BleManager.get().onStatusChanged = () {
      _logDisplayStateIfChanged('BleStatusChanged');
      notifyListeners();
    };
    await _refreshNotificationAccess();
    await _hydrateNotifications();
    _notificationSubscription = _notificationChannel
        .receiveBroadcastStream(_eventNotifications)
        .listen(_handleNotificationEvent, onError: (Object error) {
      print('${DateTime.now()} Companion: notification stream error -> $error');
    });
    await _startBackgroundFoundation();
    _logDisplayStateIfChanged('Controller.init.complete');
    print('${DateTime.now()} Companion: init complete');
  }

  Future<void> disposeController() async {
    await _notificationSubscription?.cancel();
  }

  Future<void> refreshCompanionState() async {
    await _refreshNotificationAccess();
    await _hydrateNotifications();
    _logDisplayStateIfChanged('Controller.refreshCompanionState');
    notifyListeners();
  }

  Future<void> setMode(
    AppMode mode, {
    required String source,
    bool passive = false,
  }) async {
    if (_activeMode == mode) {
      AppLog.debug(
        '${DateTime.now()} ModeSwitch: source=$source from=${_activeMode.label} to=${mode.label} passive=$passive noop=true',
      );
      _logDisplayStateIfChanged('ModeSwitch.noop');
      return;
    }

    final fromMode = _activeMode;
    await _closeActiveView(sendExit: false);

    _activeMode = mode;
    _statusMessage = '${mode.label} mode active';
    await BleManager.invokeMethod(
      'updateCompanionMode',
      {'modeLabel': mode.label},
    );

    AppLog.debug(
      '${DateTime.now()} ModeSwitch: source=$source from=${fromMode.label} to=${mode.label} passive=$passive',
    );

    if (mode == AppMode.chat) {
      await ChatService.get.enterMode(showReadyCard: true);
      _statusMessage = 'Chat ready';
    }

    await _restoreModeEntryState(mode);

    _logDisplayStateIfChanged('ModeSwitch.complete');
    notifyListeners();
  }

  Future<void> handleGlassesGesture(int eventId, String side) async {
    if (eventId == 0) {
      final activeBefore = hasActiveDisplay;
      final ownerBefore = _activeDisplayOwner;
      if (hasActiveDisplay) {
        AppLog.debug(
          '${DateTime.now()} GestureF500: mode=${_activeMode.label} hasActiveDisplay=$activeBefore owner=$ownerBefore branch=close-active side=$side',
        );
        await _handleCloseGesture();
      } else {
        AppLog.debug(
          '${DateTime.now()} GestureF500: mode=${_activeMode.label} hasActiveDisplay=$activeBefore owner=$ownerBefore branch=idle-noop side=$side',
        );
        _statusMessage = '${_activeMode.label} mode active';
      }
      _logDisplayStateIfChanged('GestureF500.complete');
      notifyListeners();
      return;
    }

    switch (_activeMode) {
      case AppMode.glance:
        await _handleGlanceGesture(eventId);
        break;
      case AppMode.capture:
        await _handleCaptureGesture(eventId);
        break;
      case AppMode.navigate:
        await _handleNavigateGesture(eventId);
        break;
      case AppMode.chat:
        await _handleChatGesture(eventId);
        break;
    }
    _logDisplayStateIfChanged('HandleGlassesGesture.event=$eventId');
    notifyListeners();
  }

  Future<void> openNotificationAccessSettings() async {
    await BleManager.invokeMethod('openNotificationAccessSettings');
  }

  Future<void> handleNotificationModeSwitch(String modeLabel) async {
    final mode = AppModeParseX.fromLabel(modeLabel);
    await setMode(
      mode,
      source: 'NotificationAction',
      passive: true,
    );
    _statusMessage = '${mode.label} mode active';
    _logDisplayStateIfChanged('NotificationModeSwitch');
    notifyListeners();
  }

  Future<void> _handleGlanceGesture(int eventId) async {
    switch (eventId) {
      case 0:
        await GlanceService.get.close();
        AppLog.debug(
          '${DateTime.now()} DisplayState: source=GestureClose service=Glance currentMode=${_activeMode.label}',
        );
        _statusMessage = 'Glance closed';
        break;
      case 2:
        await GlanceService.get.showLatestOrAdvance();
        _statusMessage = 'Glance updated';
        break;
      case 3:
        GlanceService.get.startLookDownTimeout();
        _statusMessage = 'Glance waiting';
        break;
    }
  }

  Future<void> _handleCaptureGesture(int eventId) async {
    switch (eventId) {
      case 0:
        if (CaptureService.get.isRecording) {
          final fileName = await CaptureService.get.stopAndSave();
          AppLog.debug(
            '${DateTime.now()} DisplayState: source=GestureClose service=Capture currentMode=${_activeMode.label}',
          );
          _statusMessage = fileName == null
              ? 'Capture stopped'
              : 'Saved $fileName';
        }
        break;
      case 2:
        if (CaptureService.get.isRecording) {
          final fileName = await CaptureService.get.stopAndSave();
          _statusMessage = fileName == null
              ? 'Capture stopped'
              : 'Saved $fileName';
        } else {
          final started = await CaptureService.get.startRecording();
          _statusMessage =
              started ? 'Recording from glasses mic' : 'Capture start failed';
        }
        break;
      case 3:
        break;
    }
  }

  Future<void> _handleNavigateGesture(int eventId) async {
    switch (eventId) {
      case 0:
        await NavigateService.get.close();
        AppLog.debug(
          '${DateTime.now()} DisplayState: source=GestureClose service=Navigate currentMode=${_activeMode.label}',
        );
        _statusMessage = 'Navigation card closed';
        break;
      case 2:
        if (NavigateService.get.hasInstruction) {
          await NavigateService.get.showDetail();
          _statusMessage = 'Navigation details';
        } else {
          await NavigateService.get.showLatest();
          _statusMessage = 'Waiting for Google Maps';
        }
        break;
      case 3:
        if (NavigateService.get.hasInstruction) {
          await NavigateService.get.returnToPrimary();
          _statusMessage = 'Navigation forward view';
        }
        break;
    }
  }

  Future<void> _handleChatGesture(int eventId) async {
    switch (eventId) {
      case 0:
        if (ChatService.get.shouldIgnoreCloseGesture()) {
          AppLog.debug(
            '${DateTime.now()} DisplayState: source=GestureCloseIgnored service=Chat currentMode=${_activeMode.label}',
          );
          _statusMessage = ChatService.get.isThinking
              ? 'Chat working'
              : 'Chat submitting';
          break;
        }
        await ChatService.get.resetSession();
        AppLog.debug(
          '${DateTime.now()} DisplayState: source=GestureClose service=Chat currentMode=${_activeMode.label}',
        );
        _statusMessage = 'Chat closed';
        break;
      case 2:
        _statusMessage = await ChatService.get.startListening();
        break;
      case 3:
        _statusMessage = await ChatService.get.stopListeningAndSubmit();
        break;
    }
  }

  Future<void> _closeActiveView({required bool sendExit}) async {
    switch (_activeMode) {
      case AppMode.glance:
        if (GlanceService.get.isVisible) {
          AppLog.debug(
            '${DateTime.now()} DisplayState: source=ModeSwitchClose service=Glance currentMode=${_activeMode.label}',
          );
          await GlanceService.get.close();
        }
        break;
      case AppMode.capture:
        if (CaptureService.get.isRecording) {
          AppLog.debug(
            '${DateTime.now()} DisplayState: source=ModeSwitchClose service=Capture currentMode=${_activeMode.label}',
          );
          await CaptureService.get.cancel();
        }
        break;
      case AppMode.navigate:
        AppLog.debug(
          '${DateTime.now()} DisplayState: source=ModeSwitchClose service=Navigate currentMode=${_activeMode.label}',
        );
        await NavigateService.get.leaveMode();
        break;
      case AppMode.chat:
        AppLog.debug(
          '${DateTime.now()} DisplayState: source=ModeSwitchClose service=Chat currentMode=${_activeMode.label}',
        );
        await ChatService.get.resetSession();
        break;
    }
    _logDisplayStateIfChanged('CloseActiveView');
  }

  Future<void> _handleCloseGesture() async {
    switch (_activeMode) {
      case AppMode.glance:
        await _handleGlanceGesture(0);
        break;
      case AppMode.capture:
        await _handleCaptureGesture(0);
        break;
      case AppMode.navigate:
        await _handleNavigateGesture(0);
        break;
      case AppMode.chat:
        await _handleChatGesture(0);
        break;
    }
  }

  Future<void> _restoreModeEntryState(AppMode mode) async {
    if (_activeMode != mode) {
      return;
    }

    switch (mode) {
      case AppMode.glance:
        return;
      case AppMode.capture:
        if (!CaptureService.get.isRecording) {
          await CaptureService.get.showReadyIndicator();
        }
        break;
      case AppMode.navigate:
        if (NavigateService.get.hasInstruction) {
          await NavigateService.get.showLatest();
        } else {
          await NavigateService.get.showIdlePrompt();
        }
        break;
      case AppMode.chat:
        await ChatService.get.showReadyPrompt();
        break;
    }
    _logDisplayStateIfChanged('ModeEntryRestore.$mode');
  }

  void _logDisplayStateIfChanged(String source) {
    final current = hasActiveDisplay;
    if (current == _lastReportedHasActiveDisplay) {
      return;
    }
    AppLog.debug(
      '${DateTime.now()} DisplayState: source=$source old=$_lastReportedHasActiveDisplay new=$current owner=$_activeDisplayOwner mode=${_activeMode.label}',
    );
    _lastReportedHasActiveDisplay = current;
  }

  Future<void> _handleNotificationEvent(dynamic rawEvent) async {
    if (rawEvent is! Map) {
      return;
    }

    final type = rawEvent['type'] as String? ?? 'posted';
    if (type == 'removed') {
      await _handleNotificationRemoved(rawEvent);
      return;
    }
    if (type != 'posted') {
      return;
    }

    final notification = CompanionNotification.fromMap(rawEvent);
    await NavigateService.get.ingestNotification(notification);

    if (_activeMode == AppMode.navigate && notification.isGoogleMaps) {
      await NavigateService.get.refreshVisibleView();
      if (!NavigateService.get.isVisible) {
        await NavigateService.get.showLatest();
      }
      _statusMessage = 'Navigation updated';
      notifyListeners();
      return;
    }

    if (NotificationPolicy.shouldBlockFromGlance(notification)) {
      AppLog.debug(
        '${DateTime.now()} Companion: blocked notification skipped for Glance -> ${notification.packageName}',
      );
      return;
    }

    final shouldAutoPopGlance =
        _activeMode == AppMode.glance && !notification.isGoogleMaps;
    await GlanceService.get.ingestNotification(
      notification,
      autoPop: shouldAutoPopGlance,
    );
    if (shouldAutoPopGlance) {
      _statusMessage = 'New notification shown in Glance';
      notifyListeners();
    }
  }

  Future<void> _hydrateNotifications() async {
    try {
      final rawNotifications = await BleManager.invokeMethod<List<dynamic>>(
        'getRecentNotifications',
      );
      final notifications = rawNotifications
              ?.whereType<Map>()
              .map(CompanionNotification.fromMap)
              .where((notification) {
                return !NotificationPolicy.shouldBlockFromGlance(notification);
              })
              .toList() ??
          const <CompanionNotification>[];
      GlanceService.get.hydrateNotifications(notifications);
      for (final notification in notifications) {
        await NavigateService.get.ingestNotification(notification);
      }
    } catch (e) {
      print('${DateTime.now()} Companion: hydrate notifications failed -> $e');
    }
  }

  Future<void> _refreshNotificationAccess() async {
    try {
      final enabled = await BleManager.invokeMethod<bool>(
        'isNotificationAccessEnabled',
      );
      _notificationAccessEnabled = enabled ?? false;
    } catch (e) {
      print('${DateTime.now()} Companion: notification access check failed -> $e');
    }
  }

  Future<void> _startBackgroundFoundation() async {
    try {
      await BleManager.invokeMethod(
        'startCompanionService',
        {'modeLabel': _activeMode.label},
      );
      print(
        '${DateTime.now()} Companion: foreground service started -> ${_activeMode.label}',
      );
    } catch (e) {
      print('${DateTime.now()} Companion: failed to start foreground service -> $e');
    }
  }

  Future<void> _handleNotificationRemoved(Map rawEvent) async {
    final key = (rawEvent['key'] as String?) ?? '';
    final packageName = (rawEvent['packageName'] as String?) ?? '';
    final cleared = await NavigateService.get.clearIfMatches(
      key: key,
      packageName: packageName,
    );
    if (cleared) {
      _statusMessage = 'Navigation ended';
      notifyListeners();
    }
  }
}
