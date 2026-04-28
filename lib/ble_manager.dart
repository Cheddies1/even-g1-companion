import 'dart:async';
import 'package:demo_ai_even/models/app_mode.dart';
import 'package:demo_ai_even/services/ble.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
import 'package:demo_ai_even/services/device_status_service.dart';
import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/services.dart';

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
  Timer? _reconnectMonitorTimer;
  int? _lastF5EventMs;
  int? _lastCmd21EventMs;
  int? _lastCmd22EventMs;
  int? _lastRightCmd21EventMs;
  bool _resyncInFlight = false;
  final Map<String, LegConnectionState> _legStates =
      <String, LegConnectionState>{
    'L': const LegConnectionState(lr: 'L'),
    'R': const LegConnectionState(lr: 'R'),
  };
  static const _maxReconnectAttempts = 3;
  static const _heartbeatDegradeThreshold = 2;
  static const _heartbeatWarningAge = Duration(seconds: 20);

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
      default:
        AppLog.error('Unknown method: ${call.method}', tag: 'BLE');
    }
  }

  void _onGlassesConnected(dynamic arguments) {
    AppLog.debug('_onGlassesConnected arguments=$arguments', tag: 'BLE');
    AppLog.info(
      '${DateTime.now()} both connected -> ${arguments['leftDeviceName']} | ${arguments['rightDeviceName']}',
      tag: 'BLE',
    );
    _applyConnectionPayload(Map<String, dynamic>.from(arguments as Map));
    CompanionController.get.noteTransportConnected(source: 'glassesConnected');

    onStatusChanged?.call();
    startSendBeatHeart();
  }

  void startSendBeatHeart() async {
    beatHeartTimer?.cancel();
    beatHeartTimer = null;
    _reconnectMonitorTimer?.cancel();
    _reconnectMonitorTimer = null;

    beatHeartTimer = Timer.periodic(const Duration(seconds: 8), (timer) async {
      for (final lr in ['L', 'R']) {
        final state = legState(lr);
        if (!state.connected) {
          continue;
        }
        final success = await Proto.sendHeartBeatToLeg(lr);
        if (success) {
          _recordHeartbeatSuccess(lr);
        } else {
          _recordHeartbeatFailure(lr, reason: 'timeout');
        }
      }
    });

    _reconnectMonitorTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _monitorLegHealth();
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
    _reconnectMonitorTimer?.cancel();
    _reconnectMonitorTimer = null;
    DeviceStatusService.get.reset(source: 'GlassesDisconnected');
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

  void _logCmd21(BleReceive res) {
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
      if (res.data.length == 42) {
        unawaited(CompanionController.get.handleRightHoldModeSwitchProbe());
      }
    }

    AppLog.debug(
      "${DateTime.now()} CMD21 event: lr=${res.lr}, len=${res.data.length}, lengthField=$lengthField, sequenceGuess=$sequenceGuess, deltaMs=${deltaMs ?? 'n/a'}, groups=[$grouped]",
    );
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

  Future<void> forceReconnect() async {
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
    final channelNumber = (payload['channelNumber'] as String?)?.trim() ??
        _lastConnectedChannelNumber;
    if (channelNumber != null && channelNumber.isNotEmpty) {
      _lastConnectedChannelNumber = channelNumber;
    }
    final leftName =
        payload['leftDeviceName'] as String? ?? legState('L').deviceName;
    final rightName =
        payload['rightDeviceName'] as String? ?? legState('R').deviceName;
    final leftConnected =
        payload['leftConnected'] as bool? ?? legState('L').connected;
    final rightConnected =
        payload['rightConnected'] as bool? ?? legState('R').connected;

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
        reconnectAttempts: leftConnected ? 0 : legState('L').reconnectAttempts,
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
        reconnectAttempts: rightConnected ? 0 : legState('R').reconnectAttempts,
        clearHeartbeatAt: !rightConnected,
        clearAckAt: !rightConnected,
      ),
      source: 'NativeConnectionState',
    );

    isConnected = leftConnected || rightConnected;
    connectionStatus = _buildConnectionStatus();
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
        if (state.reconnectAttempts > 0 &&
            state.reconnectAttempts < _maxReconnectAttempts &&
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

  Future<void> _attemptLegReconnect(String lr) async {
    final state = legState(lr);
    if (state.reconnectInFlight || state.deviceName.isEmpty) {
      return;
    }
    final attempt = state.reconnectAttempts + 1;
    _updateLegState(
      lr,
      state.copyWith(
        reconnectInFlight: true,
        reconnectAttempts: attempt,
      ),
      source: 'ReconnectAttempt',
    );
    AppLog.info(
        '${DateTime.now()} Transport: reconnect attempt -> lr=$lr attempt=$attempt');
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
}

extension Uint8ListEx on Uint8List {
  String get hexString {
    return map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
