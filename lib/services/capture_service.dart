import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class CaptureService {
  CaptureService._();

  static CaptureService? _instance;
  static CaptureService get get => _instance ??= CaptureService._();

  bool _isRecording = false;
  String? _lastSavedFileName;

  bool get isRecording => _isRecording;
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
    await TextService.get.startSendText('REC\n--\nRecording\nTilt up or double tap to save');
    print('${DateTime.now()} Capture: recording started');
    return true;
  }

  Future<String?> stopAndSave() async {
    if (!_isRecording) {
      return null;
    }

    _isRecording = false;
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
    Timer(const Duration(seconds: 3), () async {
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();
    });
    print('${DateTime.now()} Capture: recording saved -> $fileName');
    return fileName;
  }

  Future<void> cancel() async {
    if (!_isRecording) {
      return;
    }
    _isRecording = false;
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Capture: recording cancelled');
  }
}
