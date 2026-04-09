import 'dart:async';
import 'package:demo_ai_even/services/ble.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/services.dart';

typedef SendResultParse = bool Function(Uint8List value);

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
  int? _lastF5EventMs;
  int? _lastCmd21EventMs;
  int? _lastCmd22EventMs;
  
  final List<Map<String, String>> pairedGlasses = [];
  bool isConnected = false;
  String connectionStatus = 'Not connected';

  void _init() {}

  void startListening() {
    eventBleReceive.listen((res) {
      _handleReceivedData(res);
    });
  }

  Future<void> startScan() async {
    try {
      print("${DateTime.now()} BLE UI: scan requested");
      await _channel.invokeMethod('startScan');
    } catch (e) {
      print('Error starting scan: $e');
    }
  }

  Future<void> stopScan() async {
    try {
      print("${DateTime.now()} BLE UI: stop scan requested");
      await _channel.invokeMethod('stopScan');
    } catch (e) {
      print('Error stopping scan: $e');
    }
  }

  Future<void> connectToGlasses(String deviceName) async {
    try {
      final reconnectAttempt =
          connectionStatus != 'Not connected' || pairedGlasses.isNotEmpty;
      print(
        "${DateTime.now()} BLE UI: connect requested for $deviceName, reconnectAttempt=$reconnectAttempt",
      );
      await _channel.invokeMethod('connectToGlasses', {'deviceName': deviceName});
      connectionStatus = 'Connecting...';
    } catch (e) {
      print('Error connecting to device: $e');
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
      case 'foundPairedGlasses':
        _onPairedGlassesFound(Map<String, String>.from(call.arguments));
        break;
      default:
        print('Unknown method: ${call.method}');
    }
  }

  void _onGlassesConnected(dynamic arguments) {
    print("_onGlassesConnected----arguments----$arguments------");
    print(
      "${DateTime.now()} BLE UI: both connected -> ${arguments['leftDeviceName']} | ${arguments['rightDeviceName']}",
    );
    connectionStatus = 'Connected: \n${arguments['leftDeviceName']} \n${arguments['rightDeviceName']}';
    isConnected = true;

    onStatusChanged?.call();
    startSendBeatHeart();
  }

  int tryTime = 0;
  void startSendBeatHeart() async {
    beatHeartTimer?.cancel();
    beatHeartTimer = null;

    beatHeartTimer = Timer.periodic(Duration(seconds: 8), (timer) async {
      bool isSuccess = await Proto.sendHeartBeat();
      if (!isSuccess && tryTime < 2) {
        tryTime++;
        await Proto.sendHeartBeat();
      } else {
        tryTime = 0;
      }
    });
  }

  void _onGlassesConnecting() {
    print("${DateTime.now()} BLE UI: connecting");
    connectionStatus = 'Connecting...';

      onStatusChanged?.call();
  }

  void _onGlassesDisconnected() {
    print("${DateTime.now()} BLE UI: disconnected");
    connectionStatus = 'Not connected';
    isConnected = false;

    onStatusChanged?.call();
  }

  void _onPairedGlassesFound(Map<String, String> deviceInfo) {
    print(
      "${DateTime.now()} BLE UI: pair discovered -> channel=${deviceInfo['channelNumber']}, left=${deviceInfo['leftDeviceName']}, right=${deviceInfo['rightDeviceName']}",
    );
    final String channelNumber = deviceInfo['channelNumber']!;
    final isAlreadyPaired = pairedGlasses.any((glasses) => glasses['channelNumber'] == channelNumber);

    if (!isAlreadyPaired) {
      pairedGlasses.add(deviceInfo);
    }

    onStatusChanged?.call();
  }

  void _handleReceivedData(BleReceive res) {
    if (res.type == "VoiceChunk") {
      return;
    }

    String cmd = "${res.lr}${res.getCmd().toRadixString(16).padLeft(2, '0')}";
    if (res.getCmd() != 0xf1) {
      print(
        "${DateTime.now()} BleManager receive cmd: $cmd, len: ${res.data.length}, data = ${res.data.hexString}",
      );
    }

    if (res.getCmd() == 0x21) {
      _logCmd21(res);
    }

    if (res.getCmd() == 0x22) {
      _logCmd22(res);
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

      print(
        "${DateTime.now()} F5 event: lr=${res.lr}, id=$notifyIndex, label=$eventLabel, payload=[$payload], deltaMs=${deltaMs ?? 'n/a'}",
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
        case 23: //BleEvent.evenaiStart:
          print('${DateTime.now()} Legacy EvenAI start ignored in companion mode');
          break;
        case 24: //BleEvent.evenaiRecordOver:
          print('${DateTime.now()} Legacy EvenAI stop ignored in companion mode');
          break;
        default:
          print("Unhandled Ble Event: $notifyIndex ($eventLabel)");
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
        return 'unknown-background-state-6';
      case 7:
        return 'unknown-background-state-7';
      case 8:
        return 'unknown-background-state-8';
      case 9:
        return 'suspected-tilt-or-headup-state-9';
      case 10:
        return 'suspected-tilt-or-headup-state-10';
      case 11:
        return 'unknown-background-state-11';
      case 14:
        return 'unknown-background-state-14';
      case 15:
        return 'unknown-background-state-15';
      case 17:
        return 'voice-start-or-state-17';
      case 18:
        return 'voice-stop-or-state-18';
      case 30:
        return 'dashboard-open-confirm-or-state-up';
      case 31:
        return 'dashboard-close-confirm-or-state-down';
      case 23:
        return 'app-mapped-evenai-start';
      case 24:
        return 'app-mapped-evenai-record-over';
      case 32:
        return 'unknown-background-state-32';
      default:
        return 'unknown-f5-event';
    }
  }

  void _logCmd21(BleReceive res) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final deltaMs =
        _lastCmd21EventMs == null ? null : nowMs - _lastCmd21EventMs!;
    _lastCmd21EventMs = nowMs;

    final lengthField = res.data.length > 1 ? res.data[1].toInt() : -1;
    final sequenceGuess = res.data.length > 3 ? res.data[3].toInt() : -1;
    final grouped = _groupHexBytes(res.data, 7);

    print(
      "${DateTime.now()} CMD21 event: lr=${res.lr}, len=${res.data.length}, lengthField=$lengthField, sequenceGuess=$sequenceGuess, deltaMs=${deltaMs ?? 'n/a'}, groups=[$grouped]",
    );
  }

  void _logCmd22(BleReceive res) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final deltaMs =
        _lastCmd22EventMs == null ? null : nowMs - _lastCmd22EventMs!;
    _lastCmd22EventMs = nowMs;

    print(
      "${DateTime.now()} CMD22 event: lr=${res.lr}, family=0x22, len=${res.data.length}, deltaMs=${deltaMs ?? 'n/a'}, data=${res.data.hexString}",
    );
  }

  String _groupHexBytes(Uint8List data, int groupSize) {
    final bytes = data
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .toList();
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


  static final _reqListen = <String, Completer<BleReceive>>{};
  static final _reqTimeout = <String, Timer>{};
  static Completer<BleReceive>? _nextReceive;

  static _checkTimeout(String cmd, int timeoutMs, Uint8List data, String lr) {
    _reqTimeout.remove(cmd);
    var cb = _reqListen.remove(cmd);
    print('${DateTime.now()} _checkTimeout-----timeoutMs----$timeoutMs-----cb----$cb-----');
    if (cb != null) {
      var res = BleReceive();
      res.isTimeout = true;
      //var showData = data.length > 50 ? data.sublist(0, 50) : data;
      print(
          "send Timeout $cmd of $timeoutMs");
      cb.complete(res);
    }

    _reqTimeout[cmd]?.cancel();
    _reqTimeout.remove(cmd);
  }

  static Future<T?> invokeMethod<T>(String method, [dynamic params]) {
    return _channel.invokeMethod(method, params);
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
      if (!BleManager.isBothConnected()) {
        break;
      }
    }
    ret = BleReceive();
    ret.isTimeout = true;
    print(
        "requestRetry $lr timeout of $timeoutMs");
    return ret;
  }

  static Future<bool> sendBoth(
    data, {
    int timeoutMs = 250,
    SendResultParse? isSuccess,
    int? retry,
  }) async {

    var ret = await BleManager.requestRetry(data,
        lr: "L", timeoutMs: timeoutMs, retry: retry ?? 0);
    if (ret.isTimeout) {
      print("sendBoth L timeout");

      return false;
    } else if (isSuccess != null) {
      final success = isSuccess.call(ret.data);
      if (!success) return false;
      var retR = await BleManager.requestRetry(data,
          lr: "R", timeoutMs: timeoutMs, retry: retry ?? 0);
      if (retR.isTimeout) return false;
      return isSuccess.call(retR.data);
    } else if (ret.data[1].toInt() == 0xc9) {
      var ret = await BleManager.requestRetry(data,
          lr: "R", timeoutMs: timeoutMs, retry: retry ?? 0);
      if (ret.isTimeout) return false;
    }
    return true;
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
      params["lr"] = "L"; // get().slave; 
      var ret = await _channel
          .invokeMethod(methodSend, params); //ret is true or false or null
      if (ret == true) {
        params["lr"] = "R"; // get().master;
        ret = await BleManager.invokeMethod(methodSend, params);
        return ret;
      }
      if (secondDelay > 0) {
        await Future.delayed(Duration(milliseconds: secondDelay));
      }
      params["lr"] = "R"; // get().master;
      ret = await BleManager.invokeMethod(methodSend, params);
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
        print("already exist key: $cmd");

        _reqTimeout[cmd]?.cancel();
      }
      _reqListen[cmd] = completer;
    }
    print("request key: $cmd, ");

    if (timeoutMs > 0) {
      _reqTimeout[cmd] = Timer(Duration(milliseconds: timeoutMs), () {
        _checkTimeout(cmd, timeoutMs, data, lr0);
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
    //return isConnectedL() && isConnectedR();

    // todo
    return true;
  }

  static Future<bool> requestList(
    List<Uint8List> sendList, {
    String? lr,
    int? timeoutMs,
  }) async {
    print("requestList---sendList---${sendList.first}----lr---$lr----timeoutMs----$timeoutMs-");

    if (lr != null) {
      return await _requestList(sendList, lr, timeoutMs: timeoutMs);
    } else {
      var rets = await Future.wait([
        _requestList(sendList, "L", keepLast: true, timeoutMs: timeoutMs),
        _requestList(sendList, "R", keepLast: true, timeoutMs: timeoutMs),
      ]);
      if (rets.length == 2 && rets[0] && rets[1]) {
        var lastPack = sendList[sendList.length - 1];
        return await sendBoth(lastPack, timeoutMs: timeoutMs ?? 250);
      } else {
        print("error request lr leg");
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

}

extension Uint8ListEx on Uint8List {
  String get hexString {
    return map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
