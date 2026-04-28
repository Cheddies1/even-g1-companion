import 'package:flutter/foundation.dart';

/// Central app logger.
///
/// Levels:
/// - [info]   : always enabled. Concise operational lifecycle / state changes.
/// - [error]  : always enabled. Error paths, failed guards, recoverable bugs.
/// - [debug]  : gated behind the build-time define `COMPANION_VERBOSE_LOGS`.
///              Used for investigation-grade chatter (per-event BLE packet
///              notes, tilt-intent traces, heartbeat details, etc.).
///
/// Every method accepts an optional [tag] which, when present, is rendered as
/// a consistent `[TAG]` prefix so logs can be filtered by category.
/// Recommended tags: `BLE`, `Controller`, `Glance`, `Chat`, `Capture`,
/// `Navigate`, `TiltIntent`, `Proto`, `Text`, `Bmp`.
class AppLog {
  AppLog._();

  static const verbose =
      bool.fromEnvironment('COMPANION_VERBOSE_LOGS', defaultValue: false);

  static void debug(String message, {String? tag}) {
    if (!verbose) {
      return;
    }
    debugPrint(_format(tag, message));
  }

  static void info(String message, {String? tag}) {
    debugPrint(_format(tag, message));
  }

  static void error(String message, {String? tag}) {
    debugPrint(_format(tag, message));
  }

  static String _format(String? tag, String message) {
    if (tag == null || tag.isEmpty) {
      return message;
    }
    return '[$tag] $message';
  }
}
