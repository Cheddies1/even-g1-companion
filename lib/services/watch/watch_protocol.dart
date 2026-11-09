import 'package:even_companion/models/app_mode.dart';

/// Galaxy Watch remote wire types (docs/plans/watch-remote-spike.md). Pure,
/// so parsing and the state shape are unit-tested without a watch.
///
/// Commands are intents, not synthetic F5 gestures: a watch press is already
/// deliberate, so it skips the tilt gates and guards that F5 meanings carry.
enum WatchCommandKind {
  setMode('mode.set'),
  captureStart('capture.start'),
  captureStop('capture.stop'),

  /// Source-agnostic: glasses mic when the glasses are connected and out of
  /// the case, else the phone mic. Stop ends whichever is running.
  recordStart('record.start'),
  recordStop('record.stop'),
  glanceNext('glance.next'),
  glancePrev('glance.prev'),
  glanceClose('glance.close'),
  askStart('ask.start'),
  askStop('ask.stop'),
  navStop('nav.stop');

  const WatchCommandKind(this.wire);
  final String wire;
}

class WatchCommand {
  const WatchCommand(this.kind, {this.mode});

  final WatchCommandKind kind;

  /// Only for [WatchCommandKind.setMode].
  final AppMode? mode;

  /// Throws [FormatException] with a watch-displayable message.
  static WatchCommand parse(Object? json) {
    if (json is! Map) {
      throw const FormatException('Command is not an object');
    }
    final cmd = json['cmd'];
    if (cmd is! String) {
      throw const FormatException('Missing cmd');
    }
    final kind = WatchCommandKind.values
        .where((k) => k.wire == cmd)
        .firstOrNull;
    if (kind == null) {
      throw FormatException('Unknown command $cmd');
    }
    if (kind != WatchCommandKind.setMode) {
      return WatchCommand(kind);
    }
    final rawMode = json['mode'];
    final mode = rawMode is String ? parseMode(rawMode) : null;
    if (mode == null) {
      throw FormatException('Unknown mode $rawMode');
    }
    return WatchCommand(kind, mode: mode);
  }

  /// Strict, unlike `AppModeParseX.fromLabel`, which falls back to Glance.
  static AppMode? parseMode(String raw) {
    final wanted = raw.trim().toLowerCase();
    return AppMode.values.where((m) => m.name == wanted).firstOrNull;
  }
}

/// Outcome of a remote intent, returned to the watch as the ack.
class RemoteResult {
  const RemoteResult.ok([this.message = '']) : ok = true;
  const RemoteResult.fail(this.message) : ok = false;

  final bool ok;
  final String message;

  Map<String, Object> toJson() => {'ok': ok, 'message': message};
}

/// The state item mirrored to the watch. Bump [protocol] on incompatible
/// changes; additions are compatible.
class WatchState {
  const WatchState({
    required this.connected,
    required this.mode,
    required this.status,
    required this.displayOwner,
    required this.recording,
    required this.recordingSource,
    required this.recordingStartedAt,
    required this.recordTarget,
    required this.glanceVisible,
    required this.glanceIndex,
    required this.glanceCount,
    required this.glanceTitle,
    required this.glanceApp,
    required this.assistantListening,
    required this.assistantThinking,
    required this.walkActive,
    required this.glassesBattery,
    required this.caseBattery,
  });

  static const protocol = 1;
  static const _maxTitle = 60;

  final bool connected;
  final AppMode mode;
  final String status;
  final String displayOwner;
  /// Either source: the glasses mic (Capture) or the phone mic.
  final bool recording;

  /// `glasses`, `phone`, or null when idle.
  final String? recordingSource;
  final DateTime? recordingStartedAt;

  /// Which mic `record.start` would use now: `glasses` or `phone`.
  final String recordTarget;
  final bool glanceVisible;
  final int glanceIndex;
  final int glanceCount;
  final String glanceTitle;
  final String glanceApp;
  final bool assistantListening;
  final bool assistantThinking;
  final bool walkActive;
  final int? glassesBattery;
  final int? caseBattery;

  Map<String, Object?> toJson() => {
        'protocol': protocol,
        'connected': connected,
        'mode': mode.name,
        'status': status,
        'displayOwner': displayOwner,
        'recording': recording,
        'recordingSource': recordingSource,
        'recordingStartedAt': recordingStartedAt?.millisecondsSinceEpoch,
        'recordTarget': recordTarget,
        'glance': {
          'visible': glanceVisible,
          'index': glanceIndex,
          'count': glanceCount,
          'title': _truncate(glanceTitle),
          'app': glanceApp,
        },
        'assistant': {
          'listening': assistantListening,
          'thinking': assistantThinking,
        },
        'walkActive': walkActive,
        'battery': {'glasses': glassesBattery, 'case': caseBattery},
      };

  static String _truncate(String s) =>
      s.length <= _maxTitle ? s : '${s.substring(0, _maxTitle - 3)}...';
}
