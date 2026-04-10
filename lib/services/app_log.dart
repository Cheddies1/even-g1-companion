import 'package:flutter/foundation.dart';

class AppLog {
  AppLog._();

  static const verbose =
      bool.fromEnvironment('COMPANION_VERBOSE_LOGS', defaultValue: false);

  static void debug(String message) {
    if (!verbose) {
      return;
    }
    debugPrint(message);
  }

  static void info(String message) {
    debugPrint(message);
  }

  static void error(String message) {
    debugPrint(message);
  }
}
