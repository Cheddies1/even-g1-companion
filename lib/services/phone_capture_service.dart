import 'dart:async';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/models/app_mode.dart';
import 'package:even_companion/services/capture_service.dart';
import 'package:even_companion/services/companion_controller.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';
import 'package:flutter/foundation.dart';

/// Phone-microphone recording, independent of the glasses.
///
/// The "capture, but local" path: the same 16 kHz mono WAV, the same
/// `Recordings/Even Companion/` folder, the same `Capture-` filename pattern
/// and the same recordings list as glasses capture. Only the microphone
/// differs, so a recording made without the glasses on is indistinguishable
/// downstream - deliberately, so there is one place to look for audio.
///
/// Unlike [CaptureService] this is not a glasses mode. It has no gesture, no
/// BLE dependency, and starts from a button whether or not the glasses are
/// connected. That is the point: it exists for when they are not being worn.
///
/// Mutual exclusion with the glasses mic is enforced here and in
/// [CaptureService.startRecording]. The native recorders are separate
/// objects with separate PCM files, but the phone has one microphone and the
/// glasses paths (Capture, Chat, QuickNote, Quick Ask) all assume they own
/// the audio session, so overlapping sessions would truncate each other.
class PhoneCaptureService extends ChangeNotifier {
  PhoneCaptureService._();

  static PhoneCaptureService? _instance;
  static PhoneCaptureService get get => _instance ??= PhoneCaptureService._();

  /// Cadence of the in-app elapsed-time refresh. One second because the card
  /// shows seconds. The notification is not refreshed on this tick - it uses
  /// Android's own chronometer, which counts up from the start time with no
  /// further work from us.
  static const Duration _tickInterval = Duration(seconds: 1);

  /// How often the glasses HUD is re-pushed while recording. Matches
  /// [CaptureService] rather than the 1 s tick - a `0x4E` render per second
  /// is more BLE traffic than the display needs.
  static const Duration _glassesHudInterval = Duration(seconds: 5);

  bool _isRecording = false;
  DateTime? _startedAt;
  String? _lastSavedFileName;
  Timer? _tick;
  DateTime? _lastGlassesPush;
  int _pulseIndex = 0;

  static const List<String> _pulseChars = <String>['*', '#', '.'];

  bool get isRecording => _isRecording;
  String? get lastSavedFileName => _lastSavedFileName;

  /// Elapsed recording time, or [Duration.zero] when idle.
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// Whether RECORD_AUDIO has been granted. Checked fresh each call rather
  /// than cached, because the user can revoke it from system settings while
  /// the app is alive.
  Future<bool> hasMicPermission() async {
    final granted =
        await BleManager.invokeMethod<bool>('hasRecordAudioPermission');
    return granted == true;
  }

  /// Fires the runtime permission prompt and waits for the user to answer
  /// it. The native side holds the method-channel result open until
  /// `onRequestPermissionsResult` fires, so this completes with the real
  /// decision rather than the pre-prompt state - which is what lets a
  /// first-run Record tap start recording instead of needing a second tap.
  Future<bool> requestMicPermission() async {
    final granted =
        await BleManager.invokeMethod<bool>('requestRecordAudioPermission');
    return granted == true;
  }

  /// Starts recording from the phone mic.
  ///
  /// Returns a [PhoneCaptureStartResult] describing why a start was refused
  /// so the caller can show the right message rather than a generic failure.
  Future<PhoneCaptureStartResult> startRecording() async {
    if (_isRecording) {
      return PhoneCaptureStartResult.alreadyRecording;
    }

    // A glasses capture already owns the audio session. Refuse rather than
    // stomping it - the native glasses recorder would keep writing to its
    // own PCM file and the two HUDs would disagree about what is running.
    if (CaptureService.get.isRecording) {
      return PhoneCaptureStartResult.glassesCaptureActive;
    }

    if (!await hasMicPermission()) {
      final granted = await requestMicPermission();
      if (!granted) {
        return PhoneCaptureStartResult.permissionDenied;
      }
    }

    final started = await BleManager.invokeMethod<bool>(
      'startPhoneCapture',
      <String, dynamic>{
        // The notification renders its own ticking timer from this, so no
        // per-second channel traffic is needed to keep it current.
        'startedAtMs': DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (started != true) {
      AppLog.error(
        '${DateTime.now()} native phone recorder failed to start',
        tag: 'PhoneCapture',
      );
      return PhoneCaptureStartResult.recorderFailed;
    }

    _isRecording = true;
    _startedAt = DateTime.now();
    _pulseIndex = 0;
    _lastGlassesPush = null;
    _startTicker();
    notifyListeners();
    AppLog.info(
      '${DateTime.now()} phone recording started',
      tag: 'PhoneCapture',
    );
    return PhoneCaptureStartResult.started;
  }

  /// Stops recording, writes the WAV, and returns the saved filename or null
  /// if the save failed. Safe to call when idle.
  Future<String?> stopAndSave() async {
    if (!_isRecording) {
      return null;
    }

    _isRecording = false;
    _stopTicker();
    final recordedFor = elapsed;
    _startedAt = null;

    final raw = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
      'stopPhoneCapture',
    );
    final fileName = raw?['fileName'] as String?;
    _lastSavedFileName = raw?['success'] == true ? fileName : null;

    if (raw?['success'] != true) {
      AppLog.error(
        '${DateTime.now()} phone recording save failed',
        tag: 'PhoneCapture',
      );
    } else {
      AppLog.info(
        '${DateTime.now()} phone recording saved -> $fileName '
        '(${recordedFor.inSeconds}s)',
        tag: 'PhoneCapture',
      );
    }

    await _clearGlassesHud();
    notifyListeners();
    return _lastSavedFileName;
  }

  /// Aborts without saving and deletes the temp PCM.
  Future<void> cancel() async {
    if (!_isRecording) {
      return;
    }
    _isRecording = false;
    _stopTicker();
    _startedAt = null;
    await BleManager.invokeMethod('cancelPhoneCapture');
    await _clearGlassesHud();
    notifyListeners();
    AppLog.info(
      '${DateTime.now()} phone recording cancelled',
      tag: 'PhoneCapture',
    );
  }

  void _startTicker() {
    _tick?.cancel();
    _tick = Timer.periodic(_tickInterval, (_) async {
      if (!_isRecording) {
        _stopTicker();
        return;
      }
      notifyListeners();
      await _pushGlassesHudIfDue(formatElapsed(elapsed));
    });
  }

  void _stopTicker() {
    _tick?.cancel();
    _tick = null;
  }

  /// Mirrors the recording state onto the glasses, so a phone recording
  /// started while wearing them is visible.
  ///
  /// Gated on Capture mode owning the display. In Glance, Chat or Navigate
  /// the active feature owns the `0x4E` surface, and pushing a REC line into
  /// it would fight the Glance carousel or a nav card - each would overwrite
  /// the other every few seconds. Mode ownership belongs to
  /// CompanionController, so this defers to it rather than writing anyway.
  ///
  /// Best-effort in every case: a BLE failure must not affect the recording,
  /// which runs entirely on the phone.
  Future<void> _pushGlassesHudIfDue(String elapsedLabel) async {
    if (!BleManager.get().isConnected) {
      return;
    }
    if (CompanionController.get.activeMode != AppMode.capture) {
      return;
    }
    final last = _lastGlassesPush;
    if (last != null &&
        DateTime.now().difference(last) < _glassesHudInterval) {
      return;
    }
    _lastGlassesPush = DateTime.now();
    _pulseIndex = (_pulseIndex + 1) % _pulseChars.length;
    final pulse = _pulseChars[_pulseIndex];
    try {
      await TextService.get.startSendText('$pulse REC  $elapsedLabel\nPhone mic');
    } catch (error) {
      AppLog.error(
        '${DateTime.now()} glasses HUD push failed: $error',
        tag: 'PhoneCapture',
      );
    }
  }

  Future<void> _clearGlassesHud() async {
    if (_lastGlassesPush == null || !BleManager.get().isConnected) {
      _lastGlassesPush = null;
      return;
    }
    _lastGlassesPush = null;
    try {
      await TextService.get.stopTextSendingByOS();
      // Leave the display mode as well, matching CaptureService.stopAndSave,
      // so the glasses fall back to the firmware dashboard rather than
      // holding the last rendered line.
      await Proto.exit();
    } catch (error) {
      AppLog.error(
        '${DateTime.now()} glasses HUD clear failed: $error',
        tag: 'PhoneCapture',
      );
    }
  }

  /// Formats elapsed time as MM:SS, or H:MM:SS past an hour. Used by the
  /// in-app card, the notification line and the glasses HUD so all three
  /// read identically.
  static String formatElapsed(Duration elapsed) {
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
}

/// Why a [PhoneCaptureService.startRecording] call did or did not start.
enum PhoneCaptureStartResult {
  started,
  alreadyRecording,
  glassesCaptureActive,
  permissionDenied,
  recorderFailed,
}
