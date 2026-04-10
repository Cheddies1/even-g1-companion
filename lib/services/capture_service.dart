import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class CaptureService {
  CaptureService._();

  static CaptureService? _instance;
  static CaptureService get get => _instance ??= CaptureService._();

  bool _isRecording = false;
  bool _isDisplayVisible = false;
  String? _lastSavedFileName;
  Timer? _displayTimer;

  bool get isRecording => _isRecording;
  bool get isDisplayVisible => _isDisplayVisible;
  String? get lastSavedFileName => _lastSavedFileName;

  Future<bool> startRecording() async {
    if (_isRecording) {
      return true;
    }

    final started = await BleManager.invokeMethod<bool>('startGlassesCapture');
    if (started != true) {
      print('${DateTime.now()} Capture: failed to start native recorder');
      return false;
    }

    final (_, micStarted) = await Proto.micOn(lr: 'R');
    if (!micStarted) {
      await BleManager.invokeMethod('cancelGlassesCapture');
      print('${DateTime.now()} Capture: mic start failed');
      return false;
    }

    _isRecording = true;
    _isDisplayVisible = true;
    _displayTimer?.cancel();
    await TextService.get.startSendText('REC');
    print('${DateTime.now()} Capture: recording started');
    return true;
  }

  Future<String?> stopAndSave() async {
    if (!_isRecording) {
      return null;
    }

    _isRecording = false;
    _isDisplayVisible = true;
    final raw = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
      'stopGlassesCapture',
    );
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();

    final fileName = raw?['fileName'] as String?;
    _lastSavedFileName = fileName;
    final message =
        fileName == null ? 'Recording saved' : 'Recording saved\n$fileName';
    await TextService.get.startSendText(message);
    _displayTimer?.cancel();
    _displayTimer = Timer(const Duration(seconds: 3), () async {
      _isDisplayVisible = false;
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();
    });
    print('${DateTime.now()} Capture: recording saved -> $fileName');
    return fileName;
  }

  Future<void> cancel() async {
    _displayTimer?.cancel();
    _displayTimer = null;
    if (!_isRecording) {
      _isDisplayVisible = false;
      return;
    }
    _isRecording = false;
    _isDisplayVisible = false;
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Capture: recording cancelled');
  }
}
