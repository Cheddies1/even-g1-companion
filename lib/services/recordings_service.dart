import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/recording.dart';
import 'package:even_companion/services/app_log.dart';

/// Wrapper over the Android platform channel that the recordings UI uses to
/// list, rename, share, and delete on-device recordings. All state lives on
/// the Android side (in MediaStore); this class is intentionally stateless —
/// every operation re-queries the filesystem so the UI never drifts from
/// what is actually present.
class RecordingsService {
  RecordingsService._();
  static final RecordingsService get = RecordingsService._();

  /// Returns the recordings currently on disk under
  /// `Recordings/Even Companion/`, most recent first.
  Future<List<Recording>> list() async {
    try {
      final raw = await BleManager.invokeMethod<List<dynamic>>('listRecordings');
      if (raw == null) return const <Recording>[];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map(Recording.fromMap)
          .toList(growable: false);
    } catch (error, stack) {
      AppLog.error(
        '${DateTime.now()} listRecordings failed: $error',
        tag: 'Recordings',
      );
      AppLog.debug('listRecordings stack: $stack', tag: 'Recordings');
      return const <Recording>[];
    }
  }

  /// Renames a recording's prefix while preserving its timestamp suffix.
  /// Returns the new filename on success, or `null` on failure.
  Future<String?> renamePrefix(Recording recording, String newPrefix) async {
    final newName = recording.renamedTo(newPrefix);
    if (newName == recording.fileName) {
      // No-op rename — treat as success.
      return newName;
    }
    try {
      final ok = await BleManager.invokeMethod<bool>(
        'renameRecording',
        <String, dynamic>{
          'uri': recording.uri,
          'newDisplayName': newName,
        },
      );
      return ok == true ? newName : null;
    } catch (error) {
      AppLog.error(
        '${DateTime.now()} renameRecording failed: $error',
        tag: 'Recordings',
      );
      return null;
    }
  }

  /// Permanently deletes a recording.
  Future<bool> delete(Recording recording) async {
    try {
      final ok = await BleManager.invokeMethod<bool>(
        'deleteRecording',
        <String, dynamic>{'uri': recording.uri},
      );
      return ok == true;
    } catch (error) {
      AppLog.error(
        '${DateTime.now()} deleteRecording failed: $error',
        tag: 'Recordings',
      );
      return false;
    }
  }

  /// Launches the system share sheet for the given recording.
  Future<bool> share(Recording recording) async {
    try {
      final ok = await BleManager.invokeMethod<bool>(
        'shareRecording',
        <String, dynamic>{
          'uri': recording.uri,
          'displayName': recording.fileName,
        },
      );
      return ok == true;
    } catch (error) {
      AppLog.error(
        '${DateTime.now()} shareRecording failed: $error',
        tag: 'Recordings',
      );
      return false;
    }
  }
}
