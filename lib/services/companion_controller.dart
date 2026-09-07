import 'dart:async';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/app_mode.dart';
import 'package:even_companion/models/companion_notification.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/capture_service.dart';
import 'package:even_companion/services/chat_service.dart';
import 'package:even_companion/services/glance_assistant_service.dart';
import 'package:even_companion/services/glance_service.dart';
import 'package:even_companion/services/navigate_service.dart';
import 'package:even_companion/services/notification_policy.dart';
import 'package:even_companion/services/notification_settings_store.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CompanionController extends ChangeNotifier {
  CompanionController._();
  static const _postConnectVoiceGuard = Duration(seconds: 2);
  static const _tiltUpIntentDelay = Duration(milliseconds: 500);

  static CompanionController? _instance;
  static CompanionController get get => _instance ??= CompanionController._();

  static const _eventNotifications = 'eventNotifications';
  static const _eventTelephony = 'eventTelephony';
  final EventChannel _notificationChannel =
      const EventChannel(_eventNotifications);
  final EventChannel _telephonyChannel =
      const EventChannel(_eventTelephony);
  bool _lastReportedHasActiveDisplay = false;
  int? _lastDoubleTapModeSwitchMs;

  bool _initialized = false;
  StreamSubscription<dynamic>? _notificationSubscription;
  StreamSubscription<dynamic>? _telephonySubscription;
  bool _telephonyActive = false;
  AppMode _activeMode = AppMode.glance;
  String _statusMessage = 'Ready';
  bool _notificationAccessEnabled = false;
  DateTime? _ignoreVoiceGesturesUntil;
  Timer? _pendingTiltUpIntentTimer;
  AppMode? _pendingTiltUpIntentMode;
  String? _pendingTiltUpIntentAction;

  AppMode get activeMode => _activeMode;
  String get statusMessage => _statusMessage;
  bool get notificationAccessEnabled => _notificationAccessEnabled;
  String get activeDisplayOwnerLabel => _activeDisplayOwner;
  bool get hasActiveDisplay =>
      GlanceAssistantService.get.isDisplayVisible ||
      GlanceService.get.isVisible ||
      CaptureService.get.isDisplayVisible ||
      NavigateService.get.isVisible ||
      ChatService.get.isDisplayVisible;

  String get _activeDisplayOwner {
    if (GlanceAssistantService.get.isDisplayVisible) {
      return 'GlanceAssistant';
    }
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
    AppLog.info('${DateTime.now()} init begin', tag: 'Companion');
    BleManager.get().setMethodCallHandler();
    BleManager.get().startListening();
    BleManager.get().onStatusChanged = () {
      _logDisplayStateIfChanged('BleStatusChanged');
      notifyListeners();
    };
    await NotificationSettingsStore.get.init();
    await _refreshNotificationAccess();
    await _hydrateNotifications();
    _notificationSubscription = _notificationChannel
        .receiveBroadcastStream(_eventNotifications)
        .listen(_handleNotificationEvent, onError: (Object error) {
      AppLog.error(
        '${DateTime.now()} notification stream error -> $error',
        tag: 'Companion',
      );
    });
    _telephonySubscription = _telephonyChannel
        .receiveBroadcastStream(_eventTelephony)
        .listen(_handleTelephonyEvent, onError: (Object error) {
      AppLog.error(
        '${DateTime.now()} telephony stream error -> $error',
        tag: 'Companion',
      );
    });
    _telephonyActive = await _requestTelephonyPermissions();
    await _startBackgroundFoundation();
    await BleManager.get().attemptAutoConnect();
    _logDisplayStateIfChanged('Controller.init.complete');
    AppLog.info('${DateTime.now()} init complete', tag: 'Companion');
  }

  Future<void> disposeController() async {
    _cancelPendingTiltUpIntent(reason: 'dispose');
    await _notificationSubscription?.cancel();
    await _telephonySubscription?.cancel();
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
    _cancelPendingTiltUpIntent(reason: 'mode-switch');
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

  void noteTransportConnected({required String source}) {
    _ignoreVoiceGesturesUntil = DateTime.now().add(_postConnectVoiceGuard);
    AppLog.debug(
      '${DateTime.now()} Transport: voice gesture guard armed -> source=$source until=$_ignoreVoiceGesturesUntil',
    );
  }

  // Tracks whether we've ever seen a link-proven connection this app run.
  // The first recovery event after cold launch is the initial connect; we
  // suppress the "Reconnected" flash for that case so the first thing the
  // glasses say each day isn't "Reconnected" before the user has done
  // anything. Subsequent recoveries are real reconnects.
  bool _hasEverConnectedThisSession = false;

  Future<void> handleTransportRecovered({
    required String source,
  }) async {
    AppLog.info(
      '${DateTime.now()} Transport: recovery begin -> source=$source mode=${_activeMode.label} owner=$_activeDisplayOwner everConnected=$_hasEverConnectedThisSession',
    );

    if (!_hasEverConnectedThisSession) {
      _hasEverConnectedThisSession = true;
      AppLog.info(
        '${DateTime.now()} Transport: first connect this session — skipping Reconnected flash',
      );
      return;
    }

    // Don't interrupt critical in-flight flows. NavigateService bootstrap is
    // a long interleaved replay; a QuickNote capture is mid-audio-stream.
    if (Proto.isQuickNoteCaptureActive) {
      AppLog.info(
        '${DateTime.now()} Transport: Reconnected flash skipped — QuickNote capture active',
      );
      return;
    }

    await Proto.showTitleCard(
      'Reconnected',
      duration: const Duration(seconds: 1),
    );

    // Conditional state-resume after the force-clear. Disconnects in practice
    // happen during glance/idle states (PCM feed keeps BLE alive during
    // recording, so mid-recording drops are rare). The primary path is
    // therefore: flash + clear + leave blank.
    if (CaptureService.get.isRecording) {
      await TextService.get.startSendText('REC');
      AppLog.info(
        '${DateTime.now()} Transport: REC indicator restored after reconnect',
      );
      return;
    }

    if (NavigateService.get.isVisible && NavigateService.get.hasInstruction) {
      await NavigateService.get.refreshVisibleView();
      AppLog.info(
        '${DateTime.now()} Transport: nav view refreshed after reconnect',
      );
      return;
    }

    if (await GlanceService.get.showIdleSurfaceIfAvailable()) {
      AppLog.info(
        '${DateTime.now()} Transport: call HUD restored after reconnect',
      );
      return;
    }

    AppLog.info(
      '${DateTime.now()} Transport: reconnect complete — display left blank',
    );
  }

  /// Cycle through the four app modes when the firmware emits `F5 20`.
  ///
  /// `F5 20` is fired by the glasses when a double-tap triggers the official
  /// app's configured "double-tap action" — currently observed only with that
  /// action set to "transcribe" (left or right temple). It only fires when the
  /// glasses display is idle; if a feature is active, the firmware emits
  /// `F5 00` instead and that close-active path is already handled.
  ///
  /// Debounced at 1500ms to avoid double-fires from a single user gesture.
  /// The 5–6 second latency between the physical tap and `F5 20` is firmware
  /// behaviour and is not something this method can mitigate.
  Future<void> handleDoubleTapModeSwitch() async {
    // Defensive guard for Capture v2: if a recording is active, never allow a
    // mode-switch to steal the double-tap. The comment above notes that F5 20
    // is expected to fire only when the display is idle, so this branch is
    // unreachable in normal operation — but losing a recording to a firmware
    // quirk would be very expensive, and this is a cheap insurance line.
    if (_activeMode == AppMode.capture && CaptureService.get.isRecording) {
      AppLog.info(
        '${DateTime.now()} DoubleTapModeSwitch: suppressed during active capture recording',
        tag: 'Companion',
      );
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastSwitchMs = _lastDoubleTapModeSwitchMs;
    final debounceMs = lastSwitchMs == null ? null : nowMs - lastSwitchMs;

    if (debounceMs != null && debounceMs < 1500) {
      AppLog.debug(
        '${DateTime.now()} DoubleTapModeSwitch: debounced mode=${_activeMode.label} deltaMs=$debounceMs',
        tag: 'Companion',
      );
      return;
    }

    final nextMode = _activeMode.nextMode;
    _lastDoubleTapModeSwitchMs = nowMs;
    AppLog.info(
      '${DateTime.now()} DoubleTapModeSwitch: from=${_activeMode.label} to=${nextMode.label}',
      tag: 'Companion',
    );
    await setMode(
      nextMode,
      source: 'F5_20_DoubleTap',
      passive: true,
    );
  }

  Future<void> _handleGlanceGesture(int eventId) async {
    switch (eventId) {
      case 0:
        _cancelPendingTiltUpIntent(reason: 'glance-close');
        if (GlanceAssistantService.get.isDisplayVisible) {
          await GlanceAssistantService.get.close();
          _statusMessage = 'Assistant closed';
          break;
        }
        await GlanceService.get.close();
        AppLog.debug(
          '${DateTime.now()} DisplayState: source=GestureClose service=Glance currentMode=${_activeMode.label}',
        );
        _statusMessage = 'Glance closed';
        break;
      case 2:
        final shouldGate = !GlanceService.get.isInActiveRecall;
        await _runTiltUpIntent(
          mode: AppMode.glance,
          action: shouldGate ? 'glance-enter-recall' : 'glance-advance',
          shouldGate: shouldGate,
          onConfirm: () async {
            await GlanceService.get.showLatestOrAdvance();
            _statusMessage = 'Glance updated';
          },
        );
        break;
      case 3:
        final intentCancelled = _cancelPendingTiltUpIntent(
          reason: 'glance-return-to-centre',
          mode: AppMode.glance,
        );
        GlanceService.get.startLookDownTimeout();
        _statusMessage = intentCancelled
            ? 'Glance intent cancelled'
            : 'Glance waiting';
        break;
      case 17:
        if (_shouldIgnoreVoiceGesture()) {
          _statusMessage = 'Glance ready';
          break;
        }
        AppLog.debug(
          '${DateTime.now()} F5 17 routed in Glance mode',
          tag: 'GlanceAssistant',
        );
        if (hasActiveDisplay) {
          AppLog.debug(
            '${DateTime.now()} start blocked -> activeDisplay owner=$_activeDisplayOwner',
            tag: 'GlanceAssistant',
          );
          _statusMessage = 'Glance busy';
          break;
        }
        _statusMessage = await GlanceAssistantService.get.startListening();
        break;
      case 18:
        if (_shouldIgnoreVoiceGesture()) {
          _statusMessage = 'Glance ready';
          break;
        }
        AppLog.debug(
          '${DateTime.now()} F5 18 routed in Glance mode',
          tag: 'GlanceAssistant',
        );
        _statusMessage =
            await GlanceAssistantService.get.stopListeningAndSubmit();
        break;
    }
  }

  bool _shouldIgnoreVoiceGesture() {
    final ignoreUntil = _ignoreVoiceGesturesUntil;
    if (ignoreUntil == null) {
      return false;
    }
    return DateTime.now().isBefore(ignoreUntil);
  }

  Future<void> _handleCaptureGesture(int eventId) async {
    switch (eventId) {
      case 0:
        _cancelPendingTiltUpIntent(reason: 'capture-close');
        if (CaptureService.get.isRecording) {
          final fileName = await CaptureService.get.stopAndSave();
          AppLog.debug(
            '${DateTime.now()} DisplayState: source=GestureClose service=Capture currentMode=${_activeMode.label}',
          );
          _statusMessage =
              fileName == null ? 'Capture stopped' : 'Saved $fileName';
        }
        break;
      case 2:
        if (_shouldIgnoreVoiceGesture()) {
          _statusMessage = 'Capture ready';
          break;
        }
        if (CaptureService.get.isRecording) {
          // Safer Stop (Capture v2): tilt-up while a recording is active is a
          // no-op. Natural head movement (e.g. drinking) was being read as a
          // stop gesture. Stop now requires the deliberate double-tap (F5 00),
          // handled by case 0 above which calls CaptureService.stopAndSave().
          AppLog.debug(
            '${DateTime.now()} GestureF502: mode=Capture branch=ignore-while-recording side=any',
          );
          _statusMessage = 'Recording — double-tap to stop';
          break;
        }
        await _runTiltUpIntent(
          mode: AppMode.capture,
          action: 'capture-start',
          shouldGate: true,
          onConfirm: () async {
            final started = await CaptureService.get.startRecording();
            _statusMessage = started
                ? 'Recording from glasses mic'
                : 'Capture start failed';
          },
        );
        break;
      case 3:
        if (_cancelPendingTiltUpIntent(
          reason: 'capture-return-to-centre',
          mode: AppMode.capture,
        )) {
          _statusMessage = 'Capture intent cancelled';
        }
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
        _cancelPendingTiltUpIntent(reason: 'chat-close');
        if (ChatService.get.shouldIgnoreCloseGesture()) {
          AppLog.debug(
            '${DateTime.now()} DisplayState: source=GestureCloseIgnored service=Chat currentMode=${_activeMode.label}',
          );
          _statusMessage =
              ChatService.get.isThinking ? 'Chat working' : 'Chat submitting';
          break;
        }
        await ChatService.get.closeVisibleDisplay();
        AppLog.debug(
          '${DateTime.now()} DisplayState: source=GestureClose service=Chat currentMode=${_activeMode.label}',
        );
        _statusMessage = 'Chat ready';
        break;
      case 2:
        if (_shouldIgnoreVoiceGesture()) {
          _statusMessage = 'Chat ready';
          break;
        }
        await _runTiltUpIntent(
          mode: AppMode.chat,
          action: 'chat-start-listening',
          shouldGate: true,
          onConfirm: () async {
            _statusMessage = await ChatService.get.startListening();
          },
        );
        break;
      case 3:
        if (_cancelPendingTiltUpIntent(
          reason: 'chat-return-to-centre',
          mode: AppMode.chat,
        )) {
          _statusMessage = 'Chat intent cancelled';
          break;
        }
        _statusMessage = await ChatService.get.stopListeningAndSubmit();
        break;
    }
  }

  Future<void> _runTiltUpIntent({
    required AppMode mode,
    required String action,
    required bool shouldGate,
    required Future<void> Function() onConfirm,
  }) async {
    if (!shouldGate) {
      _cancelPendingTiltUpIntent(reason: 'immediate-$action');
      await onConfirm();
      return;
    }

    _cancelPendingTiltUpIntent(reason: 'replace-$action');
    _pendingTiltUpIntentMode = mode;
    _pendingTiltUpIntentAction = action;
    AppLog.debug(
      '${DateTime.now()} TiltIntent: pending mode=${mode.label} action=$action delayMs=${_tiltUpIntentDelay.inMilliseconds}',
    );

    _pendingTiltUpIntentTimer = Timer(_tiltUpIntentDelay, () async {
      final pendingMode = _pendingTiltUpIntentMode;
      final pendingAction = _pendingTiltUpIntentAction;
      _pendingTiltUpIntentTimer = null;
      _pendingTiltUpIntentMode = null;
      _pendingTiltUpIntentAction = null;
      if (_activeMode != mode) {
        AppLog.debug(
          '${DateTime.now()} TiltIntent: dropped mode=${mode.label} action=$action reason=mode-changed currentMode=${_activeMode.label}',
        );
        return;
      }
      AppLog.debug(
        '${DateTime.now()} TiltIntent: confirmed mode=${pendingMode?.label ?? mode.label} action=${pendingAction ?? action}',
      );
      await onConfirm();
      _logDisplayStateIfChanged('TiltIntent.confirmed.$action');
      notifyListeners();
    });
  }

  bool _cancelPendingTiltUpIntent({
    required String reason,
    AppMode? mode,
  }) {
    final timer = _pendingTiltUpIntentTimer;
    final pendingMode = _pendingTiltUpIntentMode;
    final pendingAction = _pendingTiltUpIntentAction;
    if (timer == null) {
      return false;
    }
    if (mode != null && pendingMode != mode) {
      return false;
    }
    timer.cancel();
    _pendingTiltUpIntentTimer = null;
    _pendingTiltUpIntentMode = null;
    _pendingTiltUpIntentAction = null;
    AppLog.debug(
      '${DateTime.now()} TiltIntent: cancelled mode=${pendingMode?.label ?? 'unknown'} action=${pendingAction ?? 'unknown'} reason=$reason',
    );
    return true;
  }

  Future<void> _closeActiveView({required bool sendExit}) async {
    switch (_activeMode) {
      case AppMode.glance:
        if (GlanceAssistantService.get.isDisplayVisible ||
            GlanceAssistantService.get.hasEphemeralContext) {
          AppLog.debug(
            '${DateTime.now()} DisplayState: source=ModeSwitchClose service=GlanceAssistant currentMode=${_activeMode.label}',
          );
          await GlanceAssistantService.get.reset();
        }
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
        await Proto.showTitleCard('Glance');
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
          // Hard constraint: a Navigate title card mid-bootstrap can cancel
          // the session start. Awaiting the flash ensures the screen is back
          // to a known clean state before any concurrent notification handler
          // can trigger a bootstrap — otherwise the trailing clear would
          // land mid-bootstrap and kill the session.
          await Proto.showTitleCard('Navigate');
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
    await NotificationSettingsStore.get.noteNotification(notification);
    final classification = NotificationPolicy.classify(notification);
    _logNotificationPolicy(
      notification,
      classification: classification,
      routing: 'candidate',
    );
    final navigateEligible =
        NavigateService.get.acceptsNotification(notification);
    if (navigateEligible) {
      await NavigateService.get.ingestNotification(notification);
    }

    if (_activeMode == AppMode.navigate && navigateEligible) {
      await NavigateService.get.refreshVisibleView();
      if (!NavigateService.get.isVisible) {
        await NavigateService.get.showLatest();
      }
      _statusMessage = 'Navigation updated';
      notifyListeners();
      return;
    }

    if (classification == NotificationDisposition.callAbsorbed) {
      // The notification listener is the authoritative call-HUD driver: the
      // telephony CallStateListener is silent on some devices (Samsung One UI),
      // and the CallStyle notification reliably carries callType + connect time.
      GlanceService.get.updateCall(notification);
      _logNotificationPolicy(
        notification,
        classification: classification,
        routing: _telephonyActive ? 'call-absorbed (telephony live)' : 'call-absorbed',
      );
      notifyListeners();
      return;
    }

    if (classification == NotificationDisposition.mediaAbsorbed) {
      GlanceService.get.updateMedia(notification);
      _logNotificationPolicy(
        notification,
        classification: classification,
        routing: 'media-absorbed',
      );
      notifyListeners();
      return;
    }

    if (classification == NotificationDisposition.blocked ||
        classification == NotificationDisposition.suppressed) {
      _logNotificationPolicy(
        notification,
        classification: classification,
        routing: 'ignored',
      );
      return;
    }

    final shouldAutoPopGlance =
        _activeMode == AppMode.glance && !notification.isGoogleMaps;
    await GlanceService.get.ingestNotification(
      notification,
      autoPop: shouldAutoPopGlance,
    );
    _logNotificationPolicy(
      notification,
      classification: classification,
      routing: classification == NotificationDisposition.protected
          ? 'protected-only'
          : 'added-to-normal-queue',
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
          }).toList() ??
          const <CompanionNotification>[];
      if (rawNotifications != null) {
        for (final raw in rawNotifications.whereType<Map>()) {
          final notification = CompanionNotification.fromMap(raw);
          final classification = NotificationPolicy.classify(notification);
          _logNotificationPolicy(
            notification,
            classification: classification,
            routing: 'hydrate-candidate',
          );
        }
      }
      GlanceService.get.hydrateNotifications(notifications);
      for (final notification in notifications) {
        if (NavigateService.get.acceptsNotification(notification)) {
          await NavigateService.get.ingestNotification(notification);
        }
      }
      CompanionNotification? latestMedia;
      CompanionNotification? latestCall;
      for (final raw in rawNotifications?.whereType<Map>() ?? const <Map>[]) {
        final notification = CompanionNotification.fromMap(raw);
        final disposition = NotificationPolicy.classify(notification);
        if (disposition == NotificationDisposition.mediaAbsorbed) {
          if (latestMedia == null ||
              notification.postedAt.isAfter(latestMedia.postedAt)) {
            latestMedia = notification;
          }
        } else if (disposition == NotificationDisposition.callAbsorbed) {
          if (latestCall == null ||
              notification.postedAt.isAfter(latestCall.postedAt)) {
            latestCall = notification;
          }
        }
      }
      if (latestMedia != null) {
        GlanceService.get.updateMedia(latestMedia);
      }
      if (latestCall != null) {
        GlanceService.get.updateCall(latestCall);
      }
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} hydrate notifications failed -> $e',
        tag: 'Companion',
      );
    }
  }

  Future<void> _refreshNotificationAccess() async {
    try {
      final enabled = await BleManager.invokeMethod<bool>(
        'isNotificationAccessEnabled',
      );
      _notificationAccessEnabled = enabled ?? false;
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} notification access check failed -> $e',
        tag: 'Companion',
      );
    }
  }

  void _logNotificationPolicy(
    CompanionNotification notification, {
    required NotificationDisposition classification,
    required String routing,
  }) {
    AppLog.info(
      '${DateTime.now()} NotificationPolicy: package=${notification.packageName} key=${notification.key} title="${notification.title}" text="${notification.text}" subText="${notification.subText}" summaryText="${notification.summaryText}" category=${notification.category} ongoing=${notification.isOngoing} media=${notification.isMediaStyle} template="${notification.template}" liveScoreHint="${notification.liveScoreHint}" classification=${classification.name} routing=$routing canDismiss=${NotificationPolicy.isDismissibleInGlance(notification)}',
    );
  }

  Future<void> _startBackgroundFoundation() async {
    try {
      await BleManager.invokeMethod(
        'startCompanionService',
        {'modeLabel': _activeMode.label},
      );
      AppLog.info(
        '${DateTime.now()} foreground service started -> ${_activeMode.label}',
        tag: 'Companion',
      );
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} failed to start foreground service -> $e',
        tag: 'Companion',
      );
    }
  }

  Future<void> _handleNotificationRemoved(Map rawEvent) async {
    final key = (rawEvent['key'] as String?) ?? '';
    final packageName = (rawEvent['packageName'] as String?) ?? '';
    await GlanceService.get.removeNotificationByKey(key);
    GlanceService.get.clearMedia(key);
    GlanceService.get.clearCall(key);
    final cleared = await NavigateService.get.clearIfMatches(
      key: key,
      packageName: packageName,
    );
    if (cleared) {
      _statusMessage = 'Navigation ended';
      notifyListeners();
    }
  }

  void _handleTelephonyEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;
    final state = rawEvent['state'] as String? ?? 'unknown';
    final isOutgoing = rawEvent['isOutgoing'] as bool? ?? false;
    final number = rawEvent['number'] as String?;
    AppLog.info(
      '${DateTime.now()} telephony: state=$state outgoing=$isOutgoing',
      tag: 'Companion',
    );
    GlanceService.get.handleTelephonyState(
      state,
      isOutgoing: isOutgoing,
      number: number,
    );
    notifyListeners();
  }

  Future<bool> _requestTelephonyPermissions() async {
    try {
      final granted = await BleManager.invokeMethod<bool>(
        'requestTelephonyPermissions',
      );
      AppLog.info(
        '${DateTime.now()} telephony permissions: $granted',
        tag: 'Companion',
      );
      return granted ?? false;
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} telephony permission request failed: $e',
        tag: 'Companion',
      );
      return false;
    }
  }
}
