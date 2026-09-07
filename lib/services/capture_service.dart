import 'dart:async';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/phone_capture_service.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';

class CaptureService {
  CaptureService._();

  static CaptureService? _instance;
  static CaptureService get get => _instance ??= CaptureService._();

  /// Set to `true` to revert to the original single-shot `REC` indicator
  /// instead of the live pulsing HUD. Intended as a safety valve if the
  /// periodic HUD refresh is later observed to disturb the inbound audio
  /// stream during recording. Toggle in code and rebuild — there is no
  /// runtime setting on purpose, this is meant for triage.
  static const bool useStaticRecFallback = false;

  /// Cadence of the live HUD refresh while recording. Mirrors the spec from
  /// `docs/g1-companion-apps-comparison-notes.md` Capture v2 design.
  static const Duration _hudRefreshInterval = Duration(seconds: 5);
  static const Duration _saveConfirmationDuration = Duration(seconds: 5);

  /// ASCII-only pulse characters cycled through to signal liveness on each
  /// HUD refresh. ASCII per the G1 firmware-font constraint.
  static const List<String> _pulseChars = <String>['*', '#', '.'];

  bool _isRecording = false;
  bool _isDisplayVisible = false;
  String? _lastSavedFileName;
  Timer? _displayTimer;
  Timer? _hudTimer;
  DateTime? _recordingStartedAt;
  int _pulseIndex = 0;

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

    // The phone has one microphone. A phone-mic recording already owns the
    // audio session, and starting the glasses recorder over the top would
    // leave two sessions writing separate PCM files with two disagreeing
    // HUDs. Refuse instead. Mirrors the same check in
    // PhoneCaptureService.startRecording.
    if (PhoneCaptureService.get.isRecording) {
      AppLog.info(
        '${DateTime.now()} start refused - phone recording active',
        tag: 'Capture',
      );
      return false;
    }

    final started = await BleManager.invokeMethod<bool>('startGlassesCapture');
    if (started != true) {
      AppLog.error(
        '${DateTime.now()} failed to start native recorder',
        tag: 'Capture',
      );
      return false;
    }

    final (_, micStarted) = await Proto.micOn(lr: 'R');
    if (!micStarted) {
      await BleManager.invokeMethod('cancelGlassesCapture');
      AppLog.error('${DateTime.now()} mic start failed', tag: 'Capture');
      return false;
    }

    _isRecording = true;
    _recordingStartedAt = DateTime.now();
    _pulseIndex = 0;
    markDisplayVisible(value: true, source: 'Capture.startRecording');
    _displayTimer?.cancel();

    await TextService.get.startSendText(_buildRecordingHudText());
    _startHudRefreshTimer();
    AppLog.info('${DateTime.now()} recording started', tag: 'Capture');
    return true;
  }

  Future<void> showReadyIndicator() async {
    if (_isRecording) {
      return;
    }
    _displayTimer?.cancel();
    markDisplayVisible(value: true, source: 'Capture.showReadyIndicator');
    await TextService.get.startSendText('Capture ready\nTilt up to record');
    AppLog.debug('${DateTime.now()} ready indicator shown', tag: 'Capture');
  }

  Future<String?> stopAndSave() async {
    if (!_isRecording) {
      return null;
    }

    _isRecording = false;
    _stopHudRefreshTimer();
    final recordedFor = _recordingStartedAt == null
        ? null
        : DateTime.now().difference(_recordingStartedAt!);
    _recordingStartedAt = null;

    markDisplayVisible(value: true, source: 'Capture.stopAndSave.result');
    final raw = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
      'stopGlassesCapture',
    );
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();

    final fileName = raw?['fileName'] as String?;
    _lastSavedFileName = fileName;

    final message = _buildSaveConfirmation(fileName: fileName, duration: recordedFor);
    await TextService.get.startSendText(message);
    _displayTimer?.cancel();
    _displayTimer = Timer(_saveConfirmationDuration, () async {
      markDisplayVisible(value: false, source: 'Capture.stopAndSave.timeout');
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();
    });
    AppLog.info(
      '${DateTime.now()} recording saved -> $fileName',
      tag: 'Capture',
    );
    return fileName;
  }

  Future<void> cancel() async {
    _displayTimer?.cancel();
    _displayTimer = null;
    _stopHudRefreshTimer();
    _recordingStartedAt = null;
    if (!_isRecording) {
      markDisplayVisible(value: false, source: 'Capture.cancel.idle');
      return;
    }
    _isRecording = false;
    markDisplayVisible(value: false, source: 'Capture.cancel.recording');
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    AppLog.info('${DateTime.now()} recording cancelled', tag: 'Capture');
  }

  /// Called when the BLE transport is lost (full or single-leg disconnect).
  /// Clears the _isRecording flag so no stale state blocks future sessions.
  /// Must not perform any BLE IO — transport is gone.
  void handleTransportLost() {
    _isRecording = false;
    _isDisplayVisible = false;
    _displayTimer?.cancel();
    _displayTimer = null;
    _stopHudRefreshTimer();
    _recordingStartedAt = null;
    AppLog.info(
      '${DateTime.now()} transport lost — flags cleared',
      tag: 'Capture',
    );
  }

  void _startHudRefreshTimer() {
    _hudTimer?.cancel();
    if (useStaticRecFallback) {
      // Fallback path: do not refresh — the initial REC text stays put.
      return;
    }
    _hudTimer = Timer.periodic(_hudRefreshInterval, (_) async {
      if (!_isRecording) {
        _stopHudRefreshTimer();
        return;
      }
      _pulseIndex = (_pulseIndex + 1) % _pulseChars.length;
      try {
        await TextService.get.startSendText(_buildRecordingHudText());
      } catch (error, stack) {
        AppLog.error(
          '${DateTime.now()} HUD refresh failed: $error',
          tag: 'Capture',
        );
        AppLog.debug('HUD refresh stack: $stack', tag: 'Capture');
      }
    });
  }

  void _stopHudRefreshTimer() {
    _hudTimer?.cancel();
    _hudTimer = null;
  }

  String _buildRecordingHudText() {
    if (useStaticRecFallback) {
      return 'REC';
    }
    final elapsed = _recordingStartedAt == null
        ? Duration.zero
        : DateTime.now().difference(_recordingStartedAt!);
    final pulse = _pulseChars[_pulseIndex % _pulseChars.length];
    return '$pulse REC  ${_formatElapsed(elapsed)}';
  }

  String _buildSaveConfirmation({String? fileName, Duration? duration}) {
    final durationLine = duration == null
        ? 'Saved'
        : 'Saved ${_formatDuration(duration)}';
    if (fileName == null || fileName.isEmpty) {
      return durationLine;
    }
    return '$durationLine\n$fileName';
  }

  /// Formats an elapsed time as MM:SS (or H:MM:SS once it crosses an hour),
  /// for compact HUD display.
  static String _formatElapsed(Duration elapsed) {
    final totalSeconds = elapsed.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }

  /// Formats a duration in human-readable form for the save confirmation
  /// (e.g. `12m 34s`, `1h 02m 34s`).
  static String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
    }
    if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    }
    return '${seconds}s';
  }
}
