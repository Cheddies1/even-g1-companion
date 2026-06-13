import 'dart:async';
import 'package:even_companion/models/app_mode.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/ble.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/capture_service.dart';
import 'package:even_companion/services/chat_service.dart';
import 'package:even_companion/services/companion_controller.dart';
import 'package:even_companion/services/device_status_service.dart';
import 'package:even_companion/services/evenai.dart';
import 'package:even_companion/services/glance_assistant_service.dart';
import 'package:even_companion/services/glance_service.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/notes_store.dart';
import 'package:even_companion/services/quick_note_capture_service.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef SendResultParse = bool Function(Uint8List value);

enum LegHealthStatus {
  disconnected,
  degraded,
  healthy,
}

class LegConnectionState {
  const LegConnectionState({
    required this.lr,
    this.deviceName = '',
    this.connected = false,
    this.status = LegHealthStatus.disconnected,
    this.lastHeartbeatAt,
    this.lastAckAt,
    this.lastRecoveryAt,
    this.heartbeatFailures = 0,
    this.reconnectAttempts = 0,
    this.reconnectInFlight = false,
  });

  final String lr;
  final String deviceName;
  final bool connected;
  final LegHealthStatus status;
  final DateTime? lastHeartbeatAt;
  final DateTime? lastAckAt;
  final DateTime? lastRecoveryAt;
  final int heartbeatFailures;
  final int reconnectAttempts;
  final bool reconnectInFlight;

  bool get isHealthy => connected && status == LegHealthStatus.healthy;
  bool get isAvailable => connected && status != LegHealthStatus.disconnected;

  LegConnectionState copyWith({
    String? deviceName,
    bool? connected,
    LegHealthStatus? status,
    DateTime? lastHeartbeatAt,
    DateTime? lastAckAt,
    DateTime? lastRecoveryAt,
    int? heartbeatFailures,
    int? reconnectAttempts,
    bool? reconnectInFlight,
    bool clearHeartbeatAt = false,
    bool clearAckAt = false,
    bool clearRecoveryAt = false,
  }) {
    return LegConnectionState(
      lr: lr,
      deviceName: deviceName ?? this.deviceName,
      connected: connected ?? this.connected,
      status: status ?? this.status,
      lastHeartbeatAt:
          clearHeartbeatAt ? null : (lastHeartbeatAt ?? this.lastHeartbeatAt),
      lastAckAt: clearAckAt ? null : (lastAckAt ?? this.lastAckAt),
      lastRecoveryAt:
          clearRecoveryAt ? null : (lastRecoveryAt ?? this.lastRecoveryAt),
      heartbeatFailures: heartbeatFailures ?? this.heartbeatFailures,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      reconnectInFlight: reconnectInFlight ?? this.reconnectInFlight,
    );
  }
}

class BleManager {
  Function()? onStatusChanged;
  BleManager._() {}

  static BleManager? _instance;
  static BleManager get() {
    if (_instance == null) {
      _instance ??= BleManager._();
      _instance!._init();
    }
    return _instance!;
  }

  static const methodSend = "send";
  static const _eventBleReceive = "eventBleReceive";
  static const _channel = MethodChannel('method.bluetooth');

  final eventBleReceive = const EventChannel(_eventBleReceive)
      .receiveBroadcastStream(_eventBleReceive)
      .map((ret) => BleReceive.fromMap(ret));

  Timer? beatHeartTimer;
  Timer? _timeSyncTimer;
  Timer? _reconnectMonitorTimer;
  int? _lastF5EventMs;
  int? _lastCmd21EventMs;
  int? _lastCmd22EventMs;
  int? _lastRightCmd21EventMs;
  Uint8List? _previousCmd21Payload;
  bool _cmd21PayloadLoaded = false;
  bool _autoSyncDone = false;
  bool _resyncInFlight = false;
  int _heartbeatPauseDepth = 0;
  bool _settingsReconcileFired = false;
  final Map<String, LegConnectionState> _legStates =
      <String, LegConnectionState>{
    'L': const LegConnectionState(lr: 'L'),
    'R': const LegConnectionState(lr: 'R'),
  };
  static const _maxReconnectAttempts = 5;
  final Map<String, DateTime?> _lastReconnectAttemptAt = {'L': null, 'R': null};
  static const _heartbeatDegradeThreshold = 8;
  static const _heartbeatWarningAge = Duration(seconds: 20);

  Timer? _autoReconnectTimer;
  int _autoReconnectAttempt = 0;
  String? _pendingAutoConnectChannel;
  static const _autoReconnectDelays = [
    Duration.zero,
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];

  final List<Map<String, String>> pairedGlasses = [];
  bool isConnected = false;
  String connectionStatus = 'Not connected';
  String? _lastConnectedChannelNumber;

  LegConnectionState legState(String lr) => _legStates[lr]!;
  String? get lastConnectedChannelNumber => _lastConnectedChannelNumber;

  void _init() {}

  void startListening() {
    eventBleReceive.listen((res) {
      _handleReceivedData(res);
    });
  }

  Future<void> startScan() async {
    _cancelAutoReconnect(source: 'manualScan');
    try {
      AppLog.info('${DateTime.now()} scan requested', tag: 'BLE');
      await _channel.invokeMethod('startScan');
    } catch (e) {
      AppLog.error('startScan failed: $e', tag: 'BLE');
    }
  }

  Future<void> stopScan() async {
    try {
      AppLog.info('${DateTime.now()} stop scan requested', tag: 'BLE');
      await _channel.invokeMethod('stopScan');
    } catch (e) {
      AppLog.error('stopScan failed: $e', tag: 'BLE');
    }
  }

  Future<void> connectToGlasses(String deviceName) async {
    try {
      if (deviceName.startsWith('Pair_')) {
        _lastConnectedChannelNumber = deviceName.substring('Pair_'.length);
      }
      final reconnectAttempt =
          connectionStatus != 'Not connected' || pairedGlasses.isNotEmpty;
      AppLog.info(
        '${DateTime.now()} connect requested for $deviceName, reconnectAttempt=$reconnectAttempt',
        tag: 'BLE',
      );
      await _channel
          .invokeMethod('connectToGlasses', {'deviceName': deviceName});
      connectionStatus = 'Connecting...';
    } catch (e) {
      AppLog.error('connectToGlasses failed: $e', tag: 'BLE');
    }
  }

  void setMethodCallHandler() {
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  Future<void> _methodCallHandler(MethodCall call) async {
    switch (call.method) {
      case 'glassesConnected':
        _onGlassesConnected(call.arguments);
        break;
      case 'glassesConnecting':
        _onGlassesConnecting();
        break;
      case 'glassesDisconnected':
        _onGlassesDisconnected();
        break;
      case 'glassesConnectionStateChanged':
        _onGlassesConnectionStateChanged(call.arguments);
        break;
      case 'foundPairedGlasses':
        _onPairedGlassesFound(Map<String, String>.from(call.arguments));
        break;
      case 'companionModeSwitchRequested':
        final modeLabel =
            (call.arguments as Map?)?['modeLabel'] as String? ?? 'Glance';
        await CompanionController.get.handleNotificationModeSwitch(modeLabel);
        break;
      case 'quickNoteAudioReady':
        final args = call.arguments as Map?;
        final noteUid = args?['noteUid'] as Uint8List?;
        final audio = args?['audio'] as Uint8List?;
        if (noteUid != null && audio != null) {
          unawaited(QuickNoteCaptureService.get.handleAudioReady(noteUid, audio));
        } else {
          AppLog.error(
            'quickNoteAudioReady: missing noteUid or audio in arguments',
            tag: 'QuickNoteCapture',
          );
        }
        break;
      default:
        AppLog.error('Unknown method: ${call.method}', tag: 'BLE');
    }
  }

  void _onGlassesConnected(dynamic arguments) {
    _cancelAutoReconnect(source: 'glassesConnected');
    _pendingAutoConnectChannel = null;
    AppLog.debug('_onGlassesConnected arguments=$arguments', tag: 'BLE');
    AppLog.info(
      '${DateTime.now()} both connected -> ${arguments['leftDeviceName']} | ${arguments['rightDeviceName']}',
      tag: 'BLE',
    );
    _applyConnectionPayload(Map<String, dynamic>.from(arguments as Map));
    CompanionController.get.noteTransportConnected(source: 'glassesConnected');

    onStatusChanged?.call();
    startSendBeatHeart();
    _scheduleSettingsReconcile();
  }

  void _scheduleSettingsReconcile() {
    if (_settingsReconcileFired) {
      return;
    }
    _settingsReconcileFired = true;
    unawaited(_runSettingsReconcileAfterSettle());
  }

  Future<void> _runSettingsReconcileAfterSettle() async {
    const tag = 'SettingsReconcile';
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!isConnected) {
      AppLog.info(
        '${DateTime.now()} reconcile skipped — no legs available after settle delay',
        tag: tag,
      );
      return;
    }

    final store = AppSettingsStore.get;
    await store.init();

    // 1. Brightness — only if the user has interacted at least once.
    final persistedLevel = store.brightnessLevel;
    if (persistedLevel != null) {
      final persistedAuto = store.autoBrightness;
      AppLog.info(
        '${DateTime.now()} brightness: pushing level=$persistedLevel auto=$persistedAuto',
        tag: tag,
      );
      await Proto.setBrightness(persistedLevel, persistedAuto);
    } else {
      AppLog.info(
        '${DateTime.now()} brightness: skipped (not yet picked)',
        tag: tag,
      );
    }

    // 2. Head-up mode — only if the user has picked a value.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final persistedHeadUp = store.headUpMode;
    final headUpWire = persistedHeadUp.wireValue;
    if (headUpWire != null) {
      AppLog.info(
        '${DateTime.now()} head-up mode: pushing ${persistedHeadUp.name} (0x${headUpWire.toRadixString(16).padLeft(2, '0')})',
        tag: tag,
      );
      await Proto.setHeadUpMode(headUpWire);
    } else {
      AppLog.info(
        '${DateTime.now()} head-up mode: skipped (not yet picked)',
        tag: tag,
      );
    }

    // 3. Double-tap action — only if the user has picked a value.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final persistedAction = store.doubleTapAction;
    final actionWire = persistedAction.wireValue;
    if (actionWire != null) {
      AppLog.info(
        '${DateTime.now()} double-tap action: pushing ${persistedAction.name} (0x${actionWire.toRadixString(16).padLeft(2, '0')})',
        tag: tag,
      );
      await Proto.setDoubleTapAction(actionWire);
    } else {
      AppLog.info(
        '${DateTime.now()} double-tap action: skipped (not yet picked)',
        tag: tag,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 50));
    AppLog.info('${DateTime.now()} time sync: initial push', tag: tag);
    await Proto.setTimeAndWeather();
  }

  void startSendBeatHeart() async {
    beatHeartTimer?.cancel();
    beatHeartTimer = null;
    _reconnectMonitorTimer?.cancel();
    _reconnectMonitorTimer = null;

    beatHeartTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final futures = <Future<void>>[];
      for (final lr in ['L', 'R']) {
        final state = legState(lr);
        if (!state.connected) continue;
        futures.add(
          Proto.sendHeartBeatToLeg(lr).then((success) {
            if (success) {
              _recordHeartbeatSuccess(lr);
            } else {
              _recordHeartbeatFailure(lr, reason: 'timeout');
            }
          }),
        );
      }
      await Future.wait(futures);
    });

    _reconnectMonitorTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _monitorLegHealth();
    });

    _timeSyncTimer?.cancel();
    _timeSyncTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!isConnected) return;
      await Proto.setTimeAndWeather();
    });
  }

  void _onGlassesConnecting() {
    AppLog.info('${DateTime.now()} connecting', tag: 'BLE');
    connectionStatus = 'Connecting...';

    onStatusChanged?.call();
  }

  void _onGlassesDisconnected() {
    AppLog.info('${DateTime.now()} disconnected', tag: 'BLE');
    connectionStatus = 'Not connected';
    isConnected = false;
    beatHeartTimer?.cancel();
    beatHeartTimer = null;
    _timeSyncTimer?.cancel();
    _timeSyncTimer = null;
    _reconnectMonitorTimer?.cancel();
    _reconnectMonitorTimer = null;
    _settingsReconcileFired = false;
    DeviceStatusService.get.reset(source: 'GlassesDisconnected');
    GlanceAssistantService.get.handleTransportLost();
    ChatService.get.handleTransportLost();
    CaptureService.get.handleTransportLost();
    GlanceService.get.handleTransportLost();
    _updateLegState(
      'L',
      legState('L').copyWith(
        connected: false,
        status: LegHealthStatus.disconnected,
        heartbeatFailures: 0,
        reconnectAttempts: 0,
        reconnectInFlight: false,
        clearHeartbeatAt: true,
        clearAckAt: true,
      ),
      source: 'NativeDisconnect',
    );
    _updateLegState(
      'R',
      legState('R').copyWith(
        connected: false,
        status: LegHealthStatus.disconnected,
        heartbeatFailures: 0,
        reconnectAttempts: 0,
        reconnectInFlight: false,
        clearHeartbeatAt: true,
        clearAckAt: true,
      ),
      source: 'NativeDisconnect',
    );
    _lastReconnectAttemptAt['L'] = null;
    _lastReconnectAttemptAt['R'] = null;

    onStatusChanged?.call();
  }

  void _onGlassesConnectionStateChanged(dynamic arguments) {
    if (arguments is! Map) {
      return;
    }
    _applyConnectionPayload(Map<String, dynamic>.from(arguments));
    if (legState('L').connected && legState('R').connected) {
      CompanionController.get.noteTransportConnected(
        source: 'glassesConnectionStateChanged',
      );
    }
    if (isConnected && beatHeartTimer == null) {
      startSendBeatHeart();
    }
    onStatusChanged?.call();
  }

  void _onPairedGlassesFound(Map<String, String> deviceInfo) {
    AppLog.info(
      '${DateTime.now()} pair discovered -> channel=${deviceInfo['channelNumber']}, left=${deviceInfo['leftDeviceName']}, right=${deviceInfo['rightDeviceName']}',
      tag: 'BLE',
    );
    final String channelNumber = deviceInfo['channelNumber']!;
    final isAlreadyPaired = pairedGlasses
        .any((glasses) => glasses['channelNumber'] == channelNumber);

    if (!isAlreadyPaired) {
      pairedGlasses.add(deviceInfo);
    }

    final pending = _pendingAutoConnectChannel;
    if (pending != null && channelNumber == pending) {
      _pendingAutoConnectChannel = null;
      AppLog.info(
        '${DateTime.now()} auto-connect: target channel $pending found, connecting',
        tag: 'BLE',
      );
      unawaited(connectToGlasses('Pair_$channelNumber'));
    }

    onStatusChanged?.call();
  }

  void _handleReceivedData(BleReceive res) {
    if (res.type == "VoiceChunk") {
      return;
    }

    _recordLegAck(res.lr, cmd: res.getCmd());

    String cmd = "${res.lr}${res.getCmd().toRadixString(16).padLeft(2, '0')}";
    if (res.getCmd() != 0xf1) {
      AppLog.debug(
        "${DateTime.now()} BleManager receive cmd: $cmd, len: ${res.data.length}, data = ${res.data.hexString}",
        tag: 'BleRx',
      );
    }

    if (res.getCmd() == 0x21) {
      _logCmd21(res);
    }

    if (res.getCmd() == 0x22) {
      _logCmd22(res);
    }

    if (res.getCmd() == 0x25) {
      _recordHeartbeatSuccess(res.lr);
    }

    if (res.data[0].toInt() == 0xF5) {
      final notifyIndex = res.data[1].toInt();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final deltaMs = _lastF5EventMs == null ? null : nowMs - _lastF5EventMs!;
      _lastF5EventMs = nowMs;
      final payload = res.data
          .skip(2)
          .take(6)
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      final eventLabel = _describeF5Event(notifyIndex, res);

      AppLog.debug(
        "${DateTime.now()} F5 event: lr=${res.lr}, id=$notifyIndex, label=$eventLabel, payload=[$payload], deltaMs=${deltaMs ?? 'n/a'}",
      );
      _logRightHoldF5Probe(
        res: res,
        notifyIndex: notifyIndex,
        eventLabel: eventLabel,
        payload: payload,
      );
      DeviceStatusService.get.ingestF5Event(
        subCode: notifyIndex,
        rawData: res.data,
        side: res.lr,
      );

      switch (notifyIndex) {
        case 0:
          CompanionController.get.handleGlassesGesture(notifyIndex, res.lr);
          break;
        case 1:
          if (EvenAI.isRunning) {
            if (res.lr == 'L') {
              EvenAI.get.lastPageByTouchpad();
            } else {
              EvenAI.get.nextPageByTouchpad();
            }
          }
          break;
        case 2:
          CompanionController.get.handleGlassesGesture(notifyIndex, res.lr);
          break;
        case 3:
          CompanionController.get.handleGlassesGesture(notifyIndex, res.lr);
          break;
        case 6:
        case 8:
        case 10:
        case 11:
        case 15:
        case 18:
          // Handled above by DeviceStatusService.ingestF5Event (wear state,
          // battery percentages, brightness echo). Empty case prevents the
          // default-branch "Unhandled Ble Event" info log from firing on
          // every push.
          break;
        case 17:
          AppLog.debug(
            '${DateTime.now()} F5 17 received from ${res.lr}',
            tag: 'GlanceAssistant',
          );
          CompanionController.get.handleGlassesGesture(notifyIndex, res.lr);
          break;
        case 23: //BleEvent.evenaiStart:
          AppLog.debug(
            '${DateTime.now()} F5 23 legacy EvenAI start received from ${res.lr}',
            tag: 'GlanceAssistant',
          );
          CompanionController.get.handleGlassesGesture(17, res.lr);
          break;
        case 24: //BleEvent.evenaiRecordOver:
          AppLog.debug(
            '${DateTime.now()} F5 24 legacy EvenAI stop received from ${res.lr}',
            tag: 'GlanceAssistant',
          );
          CompanionController.get.handleGlassesGesture(18, res.lr);
          break;
        case 32:
          // F5 0x20 — fired by the firmware when a double-tap triggers the
          // official app's configured double-tap action (currently observed
          // only when that action is set to "transcribe"). See
          // docs/even-g1-event-mapping.md and logs/bluetooth/FINDINGS-taps.md.
          unawaited(CompanionController.get.handleDoubleTapModeSwitch());
          break;
        default:
          AppLog.info(
            'Unhandled Ble Event: $notifyIndex ($eventLabel)',
            tag: 'BLE',
          );
      }
      return;
    }
    _reqListen.remove(cmd)?.complete(res);
    _reqTimeout.remove(cmd)?.cancel();
    if (_nextReceive != null) {
      _nextReceive?.complete(res);
      _nextReceive = null;
    }
  }

  String _describeF5Event(int notifyIndex, BleReceive res) {
    switch (notifyIndex) {
      case 0:
        return 'close-active-feature-or-home';
      case 1:
        return res.lr == 'L'
            ? 'left-tap-feature-navigation'
            : 'right-tap-feature-navigation';
      case 2:
        return 'dashboard-open-start';
      case 3:
        return 'dashboard-close-start';
      case 6:
        return 'wear-state-worn';
      case 7:
        return 'wear-state-transitioning';
      case 8:
        return 'wear-state-cradle-open';
      case 9:
        return 'suspected-tilt-or-headup-state-9';
      case 10:
        return 'glasses-battery-push';
      case 11:
        return 'wear-state-cradle-closed';
      case 14:
        return 'cradle-cable-state';
      case 15:
        return 'case-battery-push';
      case 17:
        return 'voice-start-or-state-17';
      case 18:
        return 'brightness-state-push';
      case 30:
        return 'dashboard-open-confirm-or-state-up';
      case 31:
        return 'dashboard-close-confirm-or-state-down';
      case 23:
        return 'app-mapped-evenai-start';
      case 24:
        return 'app-mapped-evenai-record-over';
      case 32:
        return 'double-tap-feature-open';
      default:
        return 'unknown-f5-event';
    }
  }

  Future<void> _logCmd21(BleReceive res) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final deltaMs =
        _lastCmd21EventMs == null ? null : nowMs - _lastCmd21EventMs!;
    _lastCmd21EventMs = nowMs;
    if (res.lr == 'R') {
      _lastRightCmd21EventMs = nowMs;
    }

    final lengthField = res.data.length > 1 ? res.data[1].toInt() : -1;
    final sequenceGuess = res.data.length > 3 ? res.data[3].toInt() : -1;
    final grouped = _groupHexBytes(res.data, 7);
    final rawPayload = res.data.hexString;
    final probeContext = _probeContext();

    AppLog.debug(
      '${DateTime.now()} lr=${res.lr} len=${res.data.length} lengthField=$lengthField sequenceGuess=$sequenceGuess deltaMs=${deltaMs ?? 'n/a'} raw=$rawPayload mode=${probeContext.modeLabel} hasActiveDisplay=${probeContext.hasActiveDisplay} owner=${probeContext.activeDisplayOwner}',
      tag: 'R21Probe',
    );
    if (res.lr == 'R') {
      AppLog.debug(
        '${DateTime.now()} candidate=R21-primary lr=${res.lr} len=${res.data.length} raw=$rawPayload groups=[$grouped] mode=${probeContext.modeLabel} hasActiveDisplay=${probeContext.hasActiveDisplay} owner=${probeContext.activeDisplayOwner}',
        tag: 'QuickNoteProbe',
      );

      // Load persisted baseline on first 0x21 after app launch.
      if (!_cmd21PayloadLoaded) {
        _cmd21PayloadLoaded = true;
        await _loadPersistedCmd21Payload();
      }

      // QuickNote audio trigger — the firmware stores notes in a circular
      // buffer. The 42-byte `0x21` lists all stored notes (typically 4).
      // To find the JUST-RECORDED note, we diff against the previous `0x21`
      // payload: the record whose 8-byte data changed is the new one.
      final noteIndex = _detectChangedNoteIndex(res.data);
      AppLog.info(
        '${DateTime.now()} requesting audio for note index $noteIndex (detected via diff)',
        tag: 'QuickNoteCapture',
      );
      _previousCmd21Payload = Uint8List.fromList(res.data);
      unawaited(_persistCmd21Payload(res.data));
      unawaited(Proto.quickNoteRequestAudio(lr: 'R', noteIndex: noteIndex));

      // On first 0x21 after launch, also check for any notes on the glasses
      // that aren't in our local store (e.g. recorded via the official app
      // or while our app was closed). Fire-and-forget — runs after the
      // primary fetch completes.
      if (!_autoSyncDone) {
        _autoSyncDone = true;
        unawaited(_syncUnknownNotes(res.data, skipIndex: noteIndex));
      }
    }

    AppLog.debug(
      "${DateTime.now()} CMD21 event: lr=${res.lr}, len=${res.data.length}, lengthField=$lengthField, sequenceGuess=$sequenceGuess, deltaMs=${deltaMs ?? 'n/a'}, groups=[$grouped]",
    );
  }

  /// Parses the 42-byte `0x21` payload to find which note record changed
  /// compared to [_previousCmd21Payload]. The payload layout is:
  ///   bytes 0-5: header (opcode, length, seq, constants)
  ///   byte 6: first record index (always 01)
  ///   bytes 7-14: record 1 data (8 bytes)
  ///   byte 15: record 2 index
  ///   bytes 16-23: record 2 data
  ///   byte 24: record 3 index
  ///   bytes 25-32: record 3 data
  ///   byte 33: record 4 index
  ///   bytes 34-41: record 4 data
  ///
  /// Returns the 1-based index of the changed record, or the highest index
  /// if no previous payload exists (first press after app start).
  int _detectChangedNoteIndex(Uint8List current) {
    final noteCount = current.length >= 6 ? current[5] : 1;

    // For 15-byte payloads (single-note release), always index 1.
    if (current.length < 42 || noteCount < 1) return 1;

    final prev = _previousCmd21Payload;
    if (prev == null || prev.length < 42) {
      // No previous — fall back to highest index (most recently replaced
      // in a fresh circular buffer tends to be the last slot, but this is
      // a best-guess for the very first press after app start).
      AppLog.info(
        '${DateTime.now()} no previous 0x21 to diff — defaulting to note index $noteCount',
        tag: 'QuickNoteCapture',
      );
      return noteCount;
    }

    // Each record is 9 bytes: 1-byte index + 8-byte data, starting at byte 6.
    for (var i = 0; i < noteCount; i++) {
      final recordStart = 6 + (i * 9);
      final dataStart = recordStart + 1; // skip the index byte
      final dataEnd = dataStart + 8;
      if (dataEnd > current.length || dataEnd > prev.length) break;

      bool changed = false;
      for (var j = dataStart; j < dataEnd; j++) {
        if (current[j] != prev[j]) {
          changed = true;
          break;
        }
      }
      if (changed) {
        final recordIndex = current[recordStart];
        AppLog.info(
          '${DateTime.now()} diff detected change at record position $i (index=$recordIndex)',
          tag: 'QuickNoteCapture',
        );
        return recordIndex;
      }
    }

    // No diff found — all records identical. Might be a re-press without
    // speaking, or the same note replayed. Default to highest.
    AppLog.info(
      '${DateTime.now()} no record changed in diff — defaulting to note index $noteCount',
      tag: 'QuickNoteCapture',
    );
    return noteCount;
  }

  /// On first `0x21` after launch, checks all note records against NotesStore.
  /// Any record whose 8-byte UID isn't already stored gets fetched, decoded,
  /// transcribed, and saved — catching notes recorded via the official app or
  /// while our app was closed.
  ///
  /// [skipIndex] is the note already being fetched by the primary diff path.
  Future<void> _syncUnknownNotes(Uint8List cmd21, {required int skipIndex}) async {
    if (cmd21.length < 42) return;
    final noteCount = cmd21.length >= 6 ? cmd21[5] : 0;
    if (noteCount < 1) return;

    final store = NotesStore.get;
    final existingNotes = await store.listAll();
    final existingUids = <String>{};
    for (final note in existingNotes) {
      if (note.noteUid != null) {
        existingUids.add(note.noteUid!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join());
      }
    }

    for (var i = 0; i < noteCount; i++) {
      final recordStart = 6 + (i * 9);
      final recordIndex = cmd21[recordStart];
      if (recordIndex == skipIndex) continue;

      final dataStart = recordStart + 1;
      final dataEnd = dataStart + 8;
      if (dataEnd > cmd21.length) break;

      final uidHex = cmd21
          .sublist(dataStart, dataEnd)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      if (existingUids.contains(uidHex)) continue;

      AppLog.info(
        '${DateTime.now()} auto-sync: note index $recordIndex (uid=$uidHex) not in local store — fetching',
        tag: 'QuickNoteCapture',
      );

      // Small delay between fetches to avoid overwhelming the BLE link.
      // The primary note fetch is already in flight; wait for it to finish.
      await Future.delayed(const Duration(seconds: 2));
      await Proto.quickNoteRequestAudio(lr: 'R', noteIndex: recordIndex);

      // The audio will arrive via the normal buffer → handleAudioReady path.
      // Wait for it to complete before fetching the next one.
      await Future.delayed(const Duration(seconds: 3));
    }

    AppLog.info(
      '${DateTime.now()} auto-sync complete',
      tag: 'QuickNoteCapture',
    );
  }

  static const _cmd21PayloadPrefKey = 'quicknote.last_cmd21_payload';

  /// Loads the last-seen `0x21` payload from SharedPreferences so the diff
  /// detection works correctly on the first press after app restart.
  Future<void> _loadPersistedCmd21Payload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hex = prefs.getString(_cmd21PayloadPrefKey);
      if (hex != null && hex.isNotEmpty) {
        final bytes = <int>[];
        for (var i = 0; i < hex.length - 1; i += 2) {
          bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
        }
        _previousCmd21Payload = Uint8List.fromList(bytes);
        AppLog.info(
          '${DateTime.now()} loaded persisted 0x21 baseline (${bytes.length} bytes)',
          tag: 'QuickNoteCapture',
        );
      }
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} failed to load persisted 0x21 baseline: $e',
        tag: 'QuickNoteCapture',
      );
    }
  }

  /// Persists the current `0x21` payload to SharedPreferences.
  Future<void> _persistCmd21Payload(Uint8List payload) async {
    try {
      final hex = payload
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cmd21PayloadPrefKey, hex);
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} failed to persist 0x21 payload: $e',
        tag: 'QuickNoteCapture',
      );
    }
  }

  void _logCmd22(BleReceive res) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final deltaMs =
        _lastCmd22EventMs == null ? null : nowMs - _lastCmd22EventMs!;
    _lastCmd22EventMs = nowMs;

    AppLog.debug(
      "${DateTime.now()} CMD22 event: lr=${res.lr}, family=0x22, len=${res.data.length}, deltaMs=${deltaMs ?? 'n/a'}, data=${res.data.hexString}",
    );
  }

  String _groupHexBytes(Uint8List data, int groupSize) {
    final bytes =
        data.map((value) => value.toRadixString(16).padLeft(2, '0')).toList();
    final groups = <String>[];

    for (var i = 0; i < bytes.length; i += groupSize) {
      final end = (i + groupSize < bytes.length) ? i + groupSize : bytes.length;
      groups.add(bytes.sublist(i, end).join(' '));
    }

    return groups.join('] [');
  }

  String getConnectionStatus() {
    return connectionStatus;
  }

  List<Map<String, String>> getPairedGlasses() {
    return pairedGlasses;
  }

  Future<void> attemptAutoConnect() async {
    await AppSettingsStore.get.init();
    final channel = AppSettingsStore.get.lastChannelNumber;
    final lastWearState = AppSettingsStore.get.lastWearState;
    if (channel.isEmpty) {
      AppLog.info(
        '${DateTime.now()} auto-connect: no persisted channel, skipping',
        tag: 'BLE',
      );
      return;
    }
    if (lastWearState == 'inCradle') {
      AppLog.info(
        '${DateTime.now()} auto-connect: last wear state was inCradle, skipping',
        tag: 'BLE',
      );
      return;
    }
    AppLog.info(
      '${DateTime.now()} auto-connect: scanning for channel=$channel (lastWearState=$lastWearState)',
      tag: 'BLE',
    );
    _pendingAutoConnectChannel = channel;
    _lastConnectedChannelNumber = channel;
    connectionStatus = 'Reconnecting...';
    onStatusChanged?.call();
    await startScan();
  }

  Future<void> forceReconnect() async {
    // Reset per-leg health state so reconnect starts from a clean slate.
    // Without this, stale reconnectAttempts/reconnectInFlight from a
    // previous failed reconnect cycle can leave legs stuck.
    for (final lr in ['L', 'R']) {
      final state = legState(lr);
      if (state.reconnectAttempts > 0 || state.reconnectInFlight) {
        _updateLegState(
          lr,
          state.copyWith(
            reconnectAttempts: 0,
            reconnectInFlight: false,
          ),
          source: 'ForceReconnectReset',
        );
      }
      _lastReconnectAttemptAt[lr] = null;
    }

    String? channelNumber = _lastConnectedChannelNumber;
    if (channelNumber == null || channelNumber.isEmpty) {
      for (final entry in pairedGlasses) {
        final candidate = (entry['channelNumber'] ?? '').trim();
        if (candidate.isNotEmpty) {
          channelNumber = candidate;
          break;
        }
      }
    }
    if (channelNumber == null || channelNumber.isEmpty) {
      await startScan();
      return;
    }
    await connectToGlasses('Pair_$channelNumber');
  }

  static final _reqListen = <String, Completer<BleReceive>>{};
  static final _reqTimeout = <String, Timer>{};
  static Completer<BleReceive>? _nextReceive;

  static _checkTimeout(String cmd, int timeoutMs, Uint8List data, String lr) {
    _reqTimeout.remove(cmd);
    var cb = _reqListen.remove(cmd);
    AppLog.debug(
        '${DateTime.now()} _checkTimeout-----timeoutMs----$timeoutMs-----cb----$cb-----');
    if (cb != null) {
      var res = BleReceive();
      res.isTimeout = true;
      //var showData = data.length > 50 ? data.sublist(0, 50) : data;
      AppLog.error('send Timeout $cmd of $timeoutMs', tag: 'BLE');
      cb.complete(res);
    }

    _reqTimeout[cmd]?.cancel();
    _reqTimeout.remove(cmd);
  }

  static Future<T?> invokeMethod<T>(String method, [dynamic params]) {
    return _channel.invokeMethod(method, params);
  }

  void _logRightHoldF5Probe({
    required BleReceive res,
    required int notifyIndex,
    required String eventLabel,
    required String payload,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastRightCmd21EventMs = _lastRightCmd21EventMs;
    final nearRight21 = lastRightCmd21EventMs != null &&
        (nowMs - lastRightCmd21EventMs).abs() <= 3000;
    final isInterestingF5 = notifyIndex == 0 ||
        notifyIndex == 17 ||
        notifyIndex == 18 ||
        notifyIndex == 23 ||
        notifyIndex == 24;

    if (!(res.lr == 'R' && isInterestingF5) && !nearRight21) {
      return;
    }

    final probeContext = _probeContext();
    final deltaFromRight21 = lastRightCmd21EventMs == null
        ? 'n/a'
        : '${nowMs - lastRightCmd21EventMs}';

    AppLog.debug(
      '${DateTime.now()} lr=${res.lr} f5=$notifyIndex label=$eventLabel len=${res.data.length} raw=${res.data.hexString} payload=[$payload] nearRight21=$nearRight21 deltaFromRight21Ms=$deltaFromRight21 mode=${probeContext.modeLabel} hasActiveDisplay=${probeContext.hasActiveDisplay} owner=${probeContext.activeDisplayOwner}',
      tag: 'RightHoldProbe',
    );
  }

  ({String modeLabel, bool hasActiveDisplay, String activeDisplayOwner})
      _probeContext() {
    final controller = CompanionController.get;
    return (
      modeLabel: controller.activeMode.label,
      hasActiveDisplay: controller.hasActiveDisplay,
      activeDisplayOwner: controller.activeDisplayOwnerLabel,
    );
  }

  static Future<BleReceive> requestRetry(
    Uint8List data, {
    String? lr,
    Map<String, dynamic>? other,
    int timeoutMs = 200,
    bool useNext = false,
    int retry = 3,
  }) async {
    BleReceive ret;
    for (var i = 0; i <= retry; i++) {
      ret = await request(data,
          lr: lr, other: other, timeoutMs: timeoutMs, useNext: useNext);
      if (!ret.isTimeout) {
        return ret;
      }
      if (lr != null && !BleManager.get().isLegAvailable(lr)) {
        break;
      }
    }
    ret = BleReceive();
    ret.isTimeout = true;
    AppLog.error('requestRetry $lr timeout of $timeoutMs', tag: 'BLE');
    return ret;
  }

  static Future<bool> sendBoth(
    data, {
    int timeoutMs = 250,
    SendResultParse? isSuccess,
    int? retry,
  }) async {
    final manager = BleManager.get();
    final targetLegs = manager._targetLegsForBroadcast();
    if (targetLegs.isEmpty) {
      AppLog.error(
          '${DateTime.now()} Transport: sendBoth skipped -> no available legs');
      return false;
    }

    var allSucceeded = true;
    for (final lr in targetLegs) {
      final ret = await BleManager.requestRetry(
        data,
        lr: lr,
        timeoutMs: timeoutMs,
        retry: retry ?? 0,
      );
      if (ret.isTimeout) {
        AppLog.error('${DateTime.now()} Transport: sendBoth timeout -> lr=$lr');
        allSucceeded = false;
        continue;
      }
      if (isSuccess != null) {
        allSucceeded = isSuccess.call(ret.data) && allSucceeded;
      } else if (ret.data.length <= 1 || ret.data[1].toInt() != 0xc9) {
        allSucceeded = false;
      }
    }
    return allSucceeded;
  }

  static Future sendData(Uint8List data,
      {String? lr, Map<String, dynamic>? other, int secondDelay = 100}) async {
    var params = <String, dynamic>{
      'data': data,
    };
    if (other != null) {
      params.addAll(other);
    }
    dynamic ret;
    if (lr != null) {
      params["lr"] = lr;
      ret = await BleManager.invokeMethod(methodSend, params);
      return ret;
    } else {
      final targetLegs = BleManager.get()._targetLegsForBroadcast();
      if (targetLegs.isEmpty) {
        AppLog.error(
            '${DateTime.now()} Transport: sendData skipped -> no available legs');
        return false;
      }
      for (var i = 0; i < targetLegs.length; i++) {
        params["lr"] = targetLegs[i];
        ret = await BleManager.invokeMethod(methodSend, params);
        if (i < targetLegs.length - 1 && secondDelay > 0) {
          await Future.delayed(Duration(milliseconds: secondDelay));
        }
      }
      return ret;
    }
  }

  static Future<BleReceive> request(Uint8List data,
      {String? lr,
      Map<String, dynamic>? other,
      int timeoutMs = 1000, //500,
      bool useNext = false}) async {
    var lr0 = lr ?? Proto.lR();
    var completer = Completer<BleReceive>();
    String cmd = "$lr0${data[0].toRadixString(16).padLeft(2, '0')}";

    if (useNext) {
      _nextReceive = completer;
    } else {
      if (_reqListen.containsKey(cmd)) {
        var res = BleReceive();
        res.isTimeout = true;
        _reqListen[cmd]?.complete(res);
        AppLog.error('already exist key: $cmd', tag: 'BLE');

        _reqTimeout[cmd]?.cancel();
      }
      _reqListen[cmd] = completer;
    }
    AppLog.debug('request key: $cmd', tag: 'BLE');

    if (timeoutMs > 0) {
      _reqTimeout[cmd] = Timer(Duration(milliseconds: timeoutMs), () {
        _checkTimeout(cmd, timeoutMs, data, lr0);
        BleManager.get()._recordRequestTimeout(lr0, cmd);
      });
    }

    completer.future.then((result) {
      _reqTimeout.remove(cmd)?.cancel();
    });

    await sendData(data, lr: lr, other: other).timeout(
      Duration(seconds: 2),
      onTimeout: () {
        _reqTimeout.remove(cmd)?.cancel();
        var ret = BleReceive();
        ret.isTimeout = true;
        _reqListen.remove(cmd)?.complete(ret);
      },
    );

    return completer.future;
  }

  static bool isBothConnected() {
    return get().legState('L').connected && get().legState('R').connected;
  }

  static Future<bool> requestList(
    List<Uint8List> sendList, {
    String? lr,
    int? timeoutMs,
  }) async {
    AppLog.debug(
      'requestList first=${sendList.first} lr=$lr timeoutMs=$timeoutMs',
      tag: 'BLE',
    );

    if (lr != null) {
      return await _requestList(sendList, lr, timeoutMs: timeoutMs);
    } else {
      final targetLegs = BleManager.get()._targetLegsForBroadcast();
      if (targetLegs.isEmpty) {
        AppLog.error(
            '${DateTime.now()} Transport: requestList skipped -> no available legs');
        return false;
      }
      var rets = await Future.wait(
        targetLegs.map(
          (targetLr) => _requestList(
            sendList,
            targetLr,
            keepLast: true,
            timeoutMs: timeoutMs,
          ),
        ),
      );
      if (rets.every((result) => result)) {
        var lastPack = sendList[sendList.length - 1];
        return await sendBoth(lastPack, timeoutMs: timeoutMs ?? 250);
      } else {
        AppLog.error('requestList: per-leg request failed', tag: 'BLE');
      }
    }
    return false;
  }

  static Future<bool> _requestList(List sendList, String lr,
      {bool keepLast = false, int? timeoutMs}) async {
    int len = sendList.length;
    if (keepLast) len = sendList.length - 1;
    for (var i = 0; i < len; i++) {
      var pack = sendList[i];
      var resp = await request(pack, lr: lr, timeoutMs: timeoutMs ?? 350);
      if (resp.isTimeout) {
        return false;
      } else if (resp.data[1].toInt() != 0xc9 && resp.data[1].toInt() != 0xcB) {
        return false;
      }
    }
    return true;
  }

  bool isLegAvailable(String lr) => legState(lr).isAvailable;

  List<String> _targetLegsForBroadcast() {
    final healthyLegs =
        ['L', 'R'].where((lr) => legState(lr).isHealthy).toList();
    if (healthyLegs.isNotEmpty) {
      return healthyLegs;
    }
    return ['L', 'R'].where((lr) => legState(lr).isAvailable).toList();
  }

  void _applyConnectionPayload(Map<String, dynamic> payload) {
    final wasConnected = isConnected;
    // Capture per-leg state before applying the new payload so we can detect
    // up-transitions (arm voice guard) and down-transitions (reset service flags).
    final prevLeftConnected = legState('L').connected;
    final prevRightConnected = legState('R').connected;

    final channelNumber = (payload['channelNumber'] as String?)?.trim() ??
        _lastConnectedChannelNumber;
    if (channelNumber != null && channelNumber.isNotEmpty) {
      _lastConnectedChannelNumber = channelNumber;
      unawaited(AppSettingsStore.get.setLastChannelNumber(channelNumber));
    }
    final leftName =
        payload['leftDeviceName'] as String? ?? legState('L').deviceName;
    final rightName =
        payload['rightDeviceName'] as String? ?? legState('R').deviceName;
    final leftConnected =
        payload['leftConnected'] as bool? ?? legState('L').connected;
    final rightConnected =
        payload['rightConnected'] as bool? ?? legState('R').connected;

    // Detect per-leg transitions before the state is committed.
    final leftCameUp = !prevLeftConnected && leftConnected;
    final rightCameUp = !prevRightConnected && rightConnected;
    final anyLegDropped = (prevLeftConnected && !leftConnected) ||
        (prevRightConnected && !rightConnected);

    // Arm the voice guard immediately on any leg-up transition so that F5
    // voice events arriving from the newly-connected leg are suppressed for
    // the standard 2-second settle window.
    if (leftCameUp) {
      CompanionController.get.noteTransportConnected(
        source: 'leg-reconnect-L',
      );
    }
    if (rightCameUp) {
      CompanionController.get.noteTransportConnected(
        source: 'leg-reconnect-R',
      );
    }

    // Clear stale service flags on any leg drop so that _scheduleClear()
    // timers are not blocked by leftover _isListening/_isThinking state.
    if (anyLegDropped) {
      GlanceAssistantService.get.handleTransportLost();
      ChatService.get.handleTransportLost();
      CaptureService.get.handleTransportLost();
      GlanceService.get.handleTransportLost();
    }

    _updateLegState(
      'L',
      legState('L').copyWith(
        deviceName: leftName,
        connected: leftConnected,
        status: leftConnected
            ? legState('L').status == LegHealthStatus.disconnected
                ? LegHealthStatus.degraded
                : legState('L').status
            : LegHealthStatus.disconnected,
        reconnectInFlight: false,
        // Do not reset reconnectAttempts on bare connected=true: a 6 ms flap
        // would zero the counter and defeat backoff. Only ack/heartbeat proofs
        // a real link — those sites reset the counter.
        reconnectAttempts: legState('L').reconnectAttempts,
        clearHeartbeatAt: !leftConnected,
        clearAckAt: !leftConnected,
      ),
      source: 'NativeConnectionState',
    );
    _updateLegState(
      'R',
      legState('R').copyWith(
        deviceName: rightName,
        connected: rightConnected,
        status: rightConnected
            ? legState('R').status == LegHealthStatus.disconnected
                ? LegHealthStatus.degraded
                : legState('R').status
            : LegHealthStatus.disconnected,
        reconnectInFlight: false,
        reconnectAttempts: legState('R').reconnectAttempts,
        clearHeartbeatAt: !rightConnected,
        clearAckAt: !rightConnected,
      ),
      source: 'NativeConnectionState',
    );

    isConnected = leftConnected || rightConnected;
    connectionStatus = _buildConnectionStatus();
    if (wasConnected && !isConnected) {
      _handleFullDisconnect(source: 'ConnectionStateChanged');
      _maybeStartAutoReconnect();
    } else if (wasConnected && isConnected) {
      // Single-leg disconnect: a leg that WAS up has gone down while the other
      // stays up. Gate on the connected->disconnected transition for THIS
      // payload, not on bare !connected. The second leg always lags the first
      // on a cold connect, so a leg still mid-GATT-discovery reads as
      // !connected and would otherwise be mistaken for a drop — triggering a
      // spurious reconnect that aborts the in-progress connection. A leg whose
      // initial connect genuinely stalls is recovered by _monitorLegHealth,
      // not here.
      for (final lr in ['L', 'R']) {
        final dropped = lr == 'L'
            ? (prevLeftConnected && !leftConnected)
            : (prevRightConnected && !rightConnected);
        if (!dropped) {
          continue;
        }
        final state = legState(lr);
        if (!state.connected &&
            state.deviceName.isNotEmpty &&
            !state.reconnectInFlight) {
          AppLog.info(
            '${DateTime.now()} Transport: single-leg disconnect detected -> $lr, triggering reconnect',
            tag: 'BLE',
          );
          unawaited(_attemptLegReconnect(lr));
        }
      }
    }
  }

  void _recordLegAck(String lr, {required int cmd}) {
    final state = legState(lr);
    final recovered =
        state.connected && state.status != LegHealthStatus.healthy;
    _updateLegState(
      lr,
      state.copyWith(
        connected: true,
        status: LegHealthStatus.healthy,
        lastAckAt: DateTime.now(),
        heartbeatFailures: 0,
        reconnectAttempts: 0,
        reconnectInFlight: false,
        lastRecoveryAt: recovered ? DateTime.now() : state.lastRecoveryAt,
      ),
      source: 'Ack cmd=0x${cmd.toRadixString(16)}',
    );
    _lastReconnectAttemptAt[lr] = null;
    if (recovered) {
      _scheduleTransportResync('ack-$lr');
    }
  }

  void _recordHeartbeatSuccess(String lr) {
    final state = legState(lr);
    final recovered =
        state.connected && state.status != LegHealthStatus.healthy;
    _updateLegState(
      lr,
      state.copyWith(
        connected: true,
        status: LegHealthStatus.healthy,
        lastHeartbeatAt: DateTime.now(),
        lastAckAt: DateTime.now(),
        heartbeatFailures: 0,
        reconnectAttempts: 0,
        reconnectInFlight: false,
        lastRecoveryAt: recovered ? DateTime.now() : state.lastRecoveryAt,
      ),
      source: 'HeartbeatSuccess',
    );
    _lastReconnectAttemptAt[lr] = null;
    if (recovered) {
      AppLog.info('${DateTime.now()} Transport: leg recovered -> $lr');
      _scheduleTransportResync('heartbeat-$lr');
    }
  }

  void _recordHeartbeatFailure(String lr, {required String reason}) {
    final state = legState(lr);
    if (!state.connected) {
      return;
    }
    final failures = state.heartbeatFailures + 1;
    final nextStatus = failures >= _heartbeatDegradeThreshold
        ? LegHealthStatus.degraded
        : state.status;
    _updateLegState(
      lr,
      state.copyWith(
        status: nextStatus,
        heartbeatFailures: failures,
      ),
      source: 'HeartbeatFailure:$reason',
    );
    if (nextStatus == LegHealthStatus.degraded) {
      AppLog.info(
          '${DateTime.now()} Transport: degraded leg detected -> $lr failures=$failures');
    }
  }

  void _recordRequestTimeout(String lr, String cmd) {
    _recordHeartbeatFailure(lr, reason: 'request-timeout:$cmd');
  }

  void _monitorLegHealth() {
    final now = DateTime.now();
    for (final lr in ['L', 'R']) {
      final state = legState(lr);
      if (!state.connected) {
        // Belt-and-braces: attempt reconnect for any disconnected leg that
        // hasn't exhausted its attempts, regardless of the current count.
        // _attemptLegReconnect() handles the increment internally.
        if (state.reconnectAttempts < _maxReconnectAttempts &&
            !state.reconnectInFlight &&
            state.deviceName.isNotEmpty) {
          unawaited(_attemptLegReconnect(lr));
        }
        continue;
      }
      final lastSignal = state.lastHeartbeatAt ?? state.lastAckAt;
      if (lastSignal == null ||
          now.difference(lastSignal) > _heartbeatWarningAge) {
        _recordHeartbeatFailure(lr, reason: 'stale');
      }
      final refreshed = legState(lr);
      if (refreshed.status == LegHealthStatus.degraded &&
          !refreshed.reconnectInFlight &&
          refreshed.reconnectAttempts < _maxReconnectAttempts) {
        unawaited(_attemptLegReconnect(lr));
      }
    }
  }

  Duration _backoffFor(int attempt) {
    const backoffs = [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ];
    final idx = (attempt - 1).clamp(0, backoffs.length - 1);
    return backoffs[idx];
  }

  Future<void> _attemptLegReconnect(String lr) async {
    final state = legState(lr);
    final lastAttempt = _lastReconnectAttemptAt[lr];
    if (lastAttempt != null) {
      final cooldown = _backoffFor(state.reconnectAttempts);
      if (DateTime.now().difference(lastAttempt) < cooldown) {
        AppLog.info(
          '${DateTime.now()} Transport: reconnect cooldown active -> lr=$lr remaining=${cooldown - DateTime.now().difference(lastAttempt)}',
          tag: 'BLE',
        );
        return;
      }
    }

    if (state.reconnectInFlight || state.deviceName.isEmpty) {
      return;
    }
    final attempt = state.reconnectAttempts + 1;
    _lastReconnectAttemptAt[lr] = DateTime.now();
    _updateLegState(
      lr,
      state.copyWith(
        reconnectInFlight: true,
        reconnectAttempts: attempt,
      ),
      source: 'ReconnectAttempt',
    );
    AppLog.info(
        '${DateTime.now()} Transport: reconnect attempt -> lr=$lr attempt=$attempt',
        tag: 'BLE');
    final accepted = await BleManager.invokeMethod<bool>(
          'reconnectGlassesLeg',
          {'lr': lr},
        ) ==
        true;
    if (!accepted) {
      _updateLegState(
        lr,
        legState(lr).copyWith(reconnectInFlight: false),
        source: 'ReconnectRejected',
      );
      AppLog.error(
          '${DateTime.now()} Transport: reconnect request rejected -> lr=$lr');
    } else {
      // Watchdog: if autoConnect=true silently pends with no callback for
      // 30 seconds, clear reconnectInFlight so the health monitor can retry.
      // Without this, a leg can get permanently stuck in reconnectInFlight.
      Future.delayed(const Duration(seconds: 30), () {
        final current = legState(lr);
        if (current.reconnectInFlight && !current.connected) {
          AppLog.info(
            '${DateTime.now()} Transport: reconnect watchdog expired -> lr=$lr, clearing reconnectInFlight',
            tag: 'BLE',
          );
          _updateLegState(
            lr,
            current.copyWith(reconnectInFlight: false),
            source: 'ReconnectWatchdog',
          );
        }
      });
    }
  }

  Future<void> _scheduleTransportResync(String source) async {
    if (_resyncInFlight) {
      return;
    }
    _resyncInFlight = true;
    try {
      AppLog.info(
          '${DateTime.now()} Transport: resync requested -> source=$source');
      await CompanionController.get.handleTransportRecovered(source: source);
    } finally {
      _resyncInFlight = false;
    }
  }

  void _updateLegState(
    String lr,
    LegConnectionState nextState, {
    required String source,
  }) {
    final previous = _legStates[lr]!;
    _legStates[lr] = nextState;
    connectionStatus = _buildConnectionStatus();
    isConnected = legState('L').connected || legState('R').connected;
    if (previous.connected != nextState.connected ||
        previous.status != nextState.status) {
      final statusLabel = switch (nextState.status) {
        LegHealthStatus.disconnected => 'disconnected',
        LegHealthStatus.degraded => 'degraded',
        LegHealthStatus.healthy => 'healthy',
      };
      AppLog.info(
        '${DateTime.now()} Transport: leg=$lr status=$statusLabel connected=${nextState.connected} source=$source',
      );
      onStatusChanged?.call();
    }
  }

  void _handleFullDisconnect({required String source}) {
    beatHeartTimer?.cancel();
    beatHeartTimer = null;
    _timeSyncTimer?.cancel();
    _timeSyncTimer = null;
    _reconnectMonitorTimer?.cancel();
    _reconnectMonitorTimer = null;
    _settingsReconcileFired = false;
    AppLog.info(
      '${DateTime.now()} full disconnect: timers cancelled source=$source',
      tag: 'BLE',
    );
  }

  void _maybeStartAutoReconnect() {
    if (_autoReconnectTimer != null || _autoReconnectAttempt > 0) {
      AppLog.debug(
        '${DateTime.now()} auto-reconnect already active, skipping',
        tag: 'BLE',
      );
      return;
    }
    final lastWearState = AppSettingsStore.get.lastWearState;
    if (lastWearState == 'inCradle') {
      AppLog.info(
        '${DateTime.now()} skip auto-reconnect: last wear state was inCradle',
        tag: 'BLE',
      );
      connectionStatus = 'Not connected';
      onStatusChanged?.call();
      return;
    }
    AppLog.info(
      '${DateTime.now()} auto-reconnect: starting backoff (lastWearState=$lastWearState)',
      tag: 'BLE',
    );
    _autoReconnectAttempt = 0;
    _scheduleNextReconnectAttempt();
  }

  void _scheduleNextReconnectAttempt() {
    if (_autoReconnectAttempt >= _autoReconnectDelays.length) {
      AppLog.info(
        '${DateTime.now()} auto-reconnect: all ${_autoReconnectDelays.length} attempts exhausted',
        tag: 'BLE',
      );
      _autoReconnectTimer = null;
      _autoReconnectAttempt = 0;
      connectionStatus = 'Not connected';
      onStatusChanged?.call();
      return;
    }
    final delay = _autoReconnectDelays[_autoReconnectAttempt];
    AppLog.info(
      '${DateTime.now()} auto-reconnect: attempt $_autoReconnectAttempt in ${delay.inSeconds}s',
      tag: 'BLE',
    );
    connectionStatus = 'Reconnecting...';
    onStatusChanged?.call();
    if (delay == Duration.zero) {
      _executeReconnectAttempt();
    } else {
      _autoReconnectTimer = Timer(delay, _executeReconnectAttempt);
    }
  }

  void _executeReconnectAttempt() {
    _autoReconnectTimer = null;
    if (isConnected) {
      _cancelAutoReconnect(source: 'already-connected');
      return;
    }
    AppLog.info(
      '${DateTime.now()} auto-reconnect: executing attempt $_autoReconnectAttempt',
      tag: 'BLE',
    );
    _autoReconnectAttempt++;
    forceReconnect();
    _scheduleNextReconnectAttempt();
  }

  void _cancelAutoReconnect({required String source}) {
    if (_autoReconnectTimer == null && _autoReconnectAttempt == 0) {
      return;
    }
    AppLog.info(
      '${DateTime.now()} auto-reconnect: cancelled source=$source',
      tag: 'BLE',
    );
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
    _autoReconnectAttempt = 0;
  }

  String _buildConnectionStatus() {
    final left = legState('L');
    final right = legState('R');

    String describe(String lr, LegConnectionState state) {
      final health = switch (state.status) {
        LegHealthStatus.disconnected => 'disconnected',
        LegHealthStatus.degraded => 'degraded',
        LegHealthStatus.healthy => 'healthy',
      };
      final label = state.deviceName.isEmpty ? lr : state.deviceName;
      return '$label ($health)';
    }

    if (!left.connected && !right.connected) {
      return 'Not connected';
    }
    return 'Connected:\n${describe('L', left)}\n${describe('R', right)}';
  }

  void suspendHeartbeats({required String reason}) {
    _heartbeatPauseDepth++;
    AppLog.info(
      '${DateTime.now()} Transport: heartbeat paused reason=$reason depth=$_heartbeatPauseDepth',
      tag: 'Transport',
    );
  }

  void resumeHeartbeats({required String reason}) {
    if (_heartbeatPauseDepth <= 0) {
      return;
    }
    _heartbeatPauseDepth--;
    AppLog.info(
      '${DateTime.now()} Transport: heartbeat resumed reason=$reason depth=$_heartbeatPauseDepth',
      tag: 'Transport',
    );
  }
}

extension Uint8ListEx on Uint8List {
  String get hexString {
    return map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
