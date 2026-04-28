import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/foundation.dart';

/// Worn / cradle state derived from `0xF5` sensor sub-codes.
enum WearState {
  unknown,
  worn,
  inCradle,
}

extension WearStateLabel on WearState {
  String get displayLabel {
    switch (this) {
      case WearState.worn:
        return 'Worn';
      case WearState.inCradle:
        return 'In cradle';
      case WearState.unknown:
        return '—';
    }
  }
}

/// Tracks battery, wear state, and brightness pushed by the glasses over
/// `0xF5` events; also owns the host-to-glasses brightness command path.
///
/// Sub-codes interpreted (confirmed against the official-app HCI snoop log
/// in `logs/bluetooth/`; see `docs/protocol-reference.md`):
///
/// - `F5 06`         -> wear state: worn
/// - `F5 08`         -> wear state: in cradle (lid open)
/// - `F5 0B`         -> wear state: in cradle (lid closed)
/// - `F5 0A <pct>`   -> glasses battery percentage 0..100 (byte 2)
/// - `F5 0F <pct>`   -> case/cradle battery percentage 0..100 (byte 2)
/// - `F5 12 <lvl>`   -> brightness state echo (byte 2, range 0..42)
///
/// Both temples push these events independently; we accept whichever arrives
/// last. Values stay quiet (no notify) until they actually change so listeners
/// don't churn on the periodic re-pushes the firmware emits while worn.
///
/// Brightness commands are sent via [setBrightness], which writes
/// `0x01 <level> <auto>` to both legs and relies on the firmware's `F5 12`
/// echo to confirm the applied level. The auto flag is locally tracked
/// because the firmware does not echo it back.
class DeviceStatusService extends ChangeNotifier {
  DeviceStatusService._();

  static DeviceStatusService? _instance;
  static DeviceStatusService get get =>
      _instance ??= DeviceStatusService._();

  /// Inclusive maximum brightness level observed from the official app.
  static const int brightnessLevelMax = 42;

  int? _glassesBatteryPct;
  int? _caseBatteryPct;
  WearState _wearState = WearState.unknown;
  int? _brightnessLevel;
  bool _autoBrightness = false;

  int? get glassesBatteryPct => _glassesBatteryPct;
  int? get caseBatteryPct => _caseBatteryPct;
  WearState get wearState => _wearState;

  /// Most recently echoed brightness level from `F5 12`, or null if no echo
  /// has been received since connect.
  int? get brightnessLevel => _brightnessLevel;

  /// Whether auto brightness is locally believed to be on. Tracked from the
  /// last [setBrightness] call because the firmware does not echo this flag.
  bool get autoBrightness => _autoBrightness;

  /// "85%" or null if no glasses battery push has been received yet.
  String? get glassesBatteryLabel {
    final pct = _glassesBatteryPct;
    return pct == null ? null : '$pct%';
  }

  /// "60%" or null if no case battery push has been received yet.
  String? get caseBatteryLabel {
    final pct = _caseBatteryPct;
    return pct == null ? null : '$pct%';
  }

  /// Single ingestion point from `BleManager` for every `0xF5` event.
  /// Returns true if any tracked state changed.
  bool ingestF5Event({
    required int subCode,
    required List<int> rawData,
    required String side,
  }) {
    switch (subCode) {
      case 0x06:
        return _setWearState(WearState.worn, source: 'F5 06 ($side)');
      case 0x08:
        return _setWearState(WearState.inCradle, source: 'F5 08 ($side)');
      case 0x0B:
        return _setWearState(WearState.inCradle, source: 'F5 0B ($side)');
      case 0x0A:
        if (rawData.length < 3) {
          return false;
        }
        return _setGlassesBattery(rawData[2], source: 'F5 0A ($side)');
      case 0x0F:
        if (rawData.length < 3) {
          return false;
        }
        return _setCaseBattery(rawData[2], source: 'F5 0F ($side)');
      case 0x12:
        if (rawData.length < 3) {
          return false;
        }
        return _setBrightnessLevel(rawData[2], source: 'F5 12 ($side)');
      default:
        return false;
    }
  }

  /// Send `0x01 <level> <auto>` to both legs and update the locally tracked
  /// auto flag. The applied [level] is confirmed back via `F5 12`.
  ///
  /// [level] is clamped to `0..[brightnessLevelMax]`.
  Future<void> setBrightness({
    required int level,
    required bool auto,
  }) async {
    final clamped = level.clamp(0, brightnessLevelMax);
    AppLog.info(
      '${DateTime.now()} brightness send: level=$clamped auto=$auto',
      tag: 'DeviceStatus',
    );
    await Proto.setBrightness(clamped, auto);
    if (_autoBrightness != auto) {
      _autoBrightness = auto;
      notifyListeners();
    }
  }

  /// Reset on full disconnect so the UI doesn't show stale numbers.
  void reset({required String source}) {
    final hadAny = _glassesBatteryPct != null ||
        _caseBatteryPct != null ||
        _wearState != WearState.unknown ||
        _brightnessLevel != null ||
        _autoBrightness;
    _glassesBatteryPct = null;
    _caseBatteryPct = null;
    _wearState = WearState.unknown;
    _brightnessLevel = null;
    _autoBrightness = false;
    if (hadAny) {
      AppLog.info(
        '${DateTime.now()} cleared device status from $source',
        tag: 'DeviceStatus',
      );
      notifyListeners();
    }
  }

  bool _setWearState(WearState next, {required String source}) {
    if (_wearState == next) {
      return false;
    }
    AppLog.info(
      '${DateTime.now()} wear state -> ${next.displayLabel} from $source',
      tag: 'DeviceStatus',
    );
    _wearState = next;
    notifyListeners();
    return true;
  }

  bool _setGlassesBattery(int pct, {required String source}) {
    if (pct < 0 || pct > 100) {
      AppLog.debug(
        '${DateTime.now()} ignoring out-of-range glasses battery=$pct from $source',
        tag: 'DeviceStatus',
      );
      return false;
    }
    if (_glassesBatteryPct == pct) {
      return false;
    }
    AppLog.info(
      '${DateTime.now()} glasses battery -> $pct% from $source',
      tag: 'DeviceStatus',
    );
    _glassesBatteryPct = pct;
    notifyListeners();
    return true;
  }

  bool _setCaseBattery(int pct, {required String source}) {
    if (pct < 0 || pct > 100) {
      AppLog.debug(
        '${DateTime.now()} ignoring out-of-range case battery=$pct from $source',
        tag: 'DeviceStatus',
      );
      return false;
    }
    if (_caseBatteryPct == pct) {
      return false;
    }
    AppLog.info(
      '${DateTime.now()} case battery -> $pct% from $source',
      tag: 'DeviceStatus',
    );
    _caseBatteryPct = pct;
    notifyListeners();
    return true;
  }

  bool _setBrightnessLevel(int level, {required String source}) {
    if (level < 0 || level > brightnessLevelMax) {
      AppLog.debug(
        '${DateTime.now()} ignoring out-of-range brightness=$level from $source',
        tag: 'DeviceStatus',
      );
      return false;
    }
    if (_brightnessLevel == level) {
      return false;
    }
    AppLog.info(
      '${DateTime.now()} brightness level -> $level from $source',
      tag: 'DeviceStatus',
    );
    _brightnessLevel = level;
    notifyListeners();
    return true;
  }
}
