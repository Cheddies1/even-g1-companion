import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/app_log.dart';
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

  void markDisplayVisible({
    required bool value,
    required String source,
  }) {
    if (_isDisplayVisible == value) {
      return;
    }
    AppLog.debug(
      '${DateTime.now()} DisplayState: source=$source service=Capture old=$_isDisplayVisible new=$value mode=Capture',
    );
    _isDisplayVisible = value;
  }

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
    markDisplayVisible(value: true, source: 'Capture.startRecording');
    _displayTimer?.cancel();
    await TextService.get.startSendText('REC');
    print('${DateTime.now()} Capture: recording started');
    return true;
  }

  Future<void> showReadyIndicator() async {
    if (_isRecording) {
      return;
    }
    _displayTimer?.cancel();
    markDisplayVisible(value: true, source: 'Capture.showReadyIndicator');
    await TextService.get.startSendText('*');
    print('${DateTime.now()} Capture: ready indicator shown');
  }

  Future<String?> stopAndSave() async {
    if (!_isRecording) {
      return null;
    }

    _isRecording = false;
    markDisplayVisible(value: true, source: 'Capture.stopAndSave.result');
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
      markDisplayVisible(value: false, source: 'Capture.stopAndSave.timeout');
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
      markDisplayVisible(value: false, source: 'Capture.cancel.idle');
      return;
    }
    _isRecording = false;
    markDisplayVisible(value: false, source: 'Capture.cancel.recording');
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Capture: recording cancelled');
  }
}
