import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/app_mode.dart';
import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/capture_service.dart';
import 'package:demo_ai_even/services/chat_service.dart';
import 'package:demo_ai_even/services/glance_service.dart';
import 'package:demo_ai_even/services/navigate_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CompanionController extends ChangeNotifier {
  CompanionController._();

  static CompanionController? _instance;
  static CompanionController get get => _instance ??= CompanionController._();

  static const _eventNotifications = 'eventNotifications';
  final EventChannel _notificationChannel = const EventChannel(_eventNotifications);

  bool _initialized = false;
  StreamSubscription<dynamic>? _notificationSubscription;
  AppMode _activeMode = AppMode.glance;
  String _statusMessage = 'Ready';
  bool _notificationAccessEnabled = false;

  AppMode get activeMode => _activeMode;
  String get statusMessage => _statusMessage;
  bool get notificationAccessEnabled => _notificationAccessEnabled;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    BleManager.get().setMethodCallHandler();
    BleManager.get().startListening();
    BleManager.get().onStatusChanged = () {
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
  }

  Future<void> disposeController() async {
    await _notificationSubscription?.cancel();
  }

  Future<void> refreshCompanionState() async {
    await _refreshNotificationAccess();
    await _hydrateNotifications();
    notifyListeners();
  }

  Future<void> setMode(AppMode mode) async {
    if (_activeMode == mode) {
      return;
    }

    await _closeActiveView(sendExit: false);
    if (_activeMode == AppMode.chat) {
      ChatService.get.resetSession();
    }

    _activeMode = mode;
    _statusMessage = '${mode.label} mode active';
    await BleManager.invokeMethod(
      'updateCompanionMode',
      {'modeLabel': mode.label},
    );

    if (mode == AppMode.navigate && NavigateService.get.hasInstruction) {
      await NavigateService.get.showLatest();
    }

    notifyListeners();
  }

  Future<void> handleGlassesGesture(int eventId, String side) async {
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
    notifyListeners();
  }

  Future<void> openNotificationAccessSettings() async {
    await BleManager.invokeMethod('openNotificationAccessSettings');
  }

  Future<void> _handleGlanceGesture(int eventId) async {
    switch (eventId) {
      case 0:
        await GlanceService.get.close();
        _statusMessage = 'Glance closed';
        break;
      case 2:
        await GlanceService.get.showLatestOrAdvance();
        _statusMessage = 'Glance updated';
        break;
      case 3:
        _statusMessage = 'Glance waiting';
        break;
    }
  }

  Future<void> _handleCaptureGesture(int eventId) async {
    switch (eventId) {
      case 0:
        if (CaptureService.get.isRecording) {
          final fileName = await CaptureService.get.stopAndSave();
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
        _statusMessage = 'Navigation card closed';
        break;
      case 2:
        await NavigateService.get.showLatest();
        _statusMessage = NavigateService.get.hasInstruction
            ? 'Navigation refreshed'
            : 'Waiting for Google Maps';
        break;
      case 3:
        break;
    }
  }

  Future<void> _handleChatGesture(int eventId) async {
    switch (eventId) {
      case 0:
        ChatService.get.resetSession();
        _statusMessage = 'Chat mode coming soon';
        break;
      case 2:
      case 3:
        _statusMessage = 'Chat mode scaffolded only in this phase';
        break;
    }
  }

  Future<void> _closeActiveView({required bool sendExit}) async {
    switch (_activeMode) {
      case AppMode.glance:
        if (GlanceService.get.isVisible) {
          await GlanceService.get.close();
        }
        break;
      case AppMode.capture:
        if (CaptureService.get.isRecording) {
          await CaptureService.get.cancel();
        }
        break;
      case AppMode.navigate:
        await NavigateService.get.leaveMode();
        break;
      case AppMode.chat:
        ChatService.get.resetSession();
        break;
    }
  }

  Future<void> _handleNotificationEvent(dynamic rawEvent) async {
    if (rawEvent is! Map) {
      return;
    }

    final type = rawEvent['type'] as String? ?? 'posted';
    if (type != 'posted') {
      return;
    }

    final notification = CompanionNotification.fromMap(rawEvent);
    await NavigateService.get.ingestNotification(notification);

    if (_activeMode == AppMode.navigate && notification.isGoogleMaps) {
      await NavigateService.get.showLatest();
      _statusMessage = 'Navigation updated';
      notifyListeners();
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
}
