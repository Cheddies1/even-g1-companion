import 'dart:async';

import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/proto.dart';
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

/// Persisted-on-glasses head-up (tilt-up) behaviour.
///
/// Sent to the firmware as `08 06 00 00 03 <wireValue>`. Verified values:
/// `0x00` = the firmware's own dashboard appears on tilt-up; `0x02` = the
/// glasses emit `F5 02` / `F5 03` only and the companion app drives any
/// visible response itself.
enum HeadUpMode {
  unknown,
  evenDashboard,
  companionApp,
}

extension HeadUpModeX on HeadUpMode {
  String get displayLabel {
    switch (this) {
      case HeadUpMode.evenDashboard:
        return 'Even firmware dashboard';
      case HeadUpMode.companionApp:
        return 'Companion app behaviour';
      case HeadUpMode.unknown:
        return 'Not yet set';
    }
  }

  int? get wireValue {
    switch (this) {
      case HeadUpMode.evenDashboard:
        return 0x00;
      case HeadUpMode.companionApp:
        return 0x02;
      case HeadUpMode.unknown:
        return null;
    }
  }
}

/// Persisted-on-glasses double-tap action.
///
/// Sent to the firmware as `26 06 00 <seq> 05 <wireValue>`. Verified values
/// from the 2026-04-28 settings capture: `0x00` = none (firmware emits
/// `F5 00` only when there's something to close), `0x04` = open the firmware
/// dashboard locally (no `F5 20`), `0x05` = transcribe (host-handled, fires
/// `F5 20` which the companion app routes to its mode-cycle handler).
enum DoubleTapAction {
  unknown,
  evenDashboard,
  companionAppModeSwitch,
  doNothing,
}

extension DoubleTapActionX on DoubleTapAction {
  String get displayLabel {
    switch (this) {
      case DoubleTapAction.companionAppModeSwitch:
        return 'Companion app mode switch';
      case DoubleTapAction.evenDashboard:
        return 'Even firmware dashboard';
      case DoubleTapAction.doNothing:
        return 'Do nothing';
      case DoubleTapAction.unknown:
        return 'Not yet set';
    }
  }

  int? get wireValue {
    switch (this) {
      case DoubleTapAction.doNothing:
        return 0x00;
      case DoubleTapAction.evenDashboard:
        return 0x04;
      case DoubleTapAction.companionAppModeSwitch:
        return 0x05;
      case DoubleTapAction.unknown:
        return null;
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
  HeadUpMode _headUpMode = HeadUpMode.unknown;
  DoubleTapAction _doubleTapAction = DoubleTapAction.unknown;

  int? get glassesBatteryPct => _glassesBatteryPct;
  int? get caseBatteryPct => _caseBatteryPct;
  WearState get wearState => _wearState;

  /// Most recently echoed brightness level from `F5 12`, or null if no echo
  /// has been received since connect.
  int? get brightnessLevel => _brightnessLevel;

  /// Whether auto brightness was last sent as enabled. Tracked from the last
  /// [setBrightness] call and persisted in [AppSettingsStore] because the
  /// firmware does not echo this flag. Stays set across disconnects.
  bool get autoBrightness => _autoBrightness;

  /// Current head-up (tilt-up) mode. Stays aligned with [AppSettingsStore]
  /// across disconnects — the companion app is authoritative and re-pushes
  /// this value on every fresh BLE reconnect. Returns [HeadUpMode.unknown]
  /// if the user has never picked.
  HeadUpMode get headUpMode => _headUpMode;

  /// Current double-tap action. Behaviour and persistence model matches
  /// [headUpMode].
  DoubleTapAction get doubleTapAction => _doubleTapAction;

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
  /// Also writes both values through to [AppSettingsStore] so the companion
  /// app's UI is authoritative across reconnects and cold launches.
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
    await AppSettingsStore.get.setBrightnessLevel(clamped);
    await AppSettingsStore.get.setAutoBrightness(auto);
    if (_autoBrightness != auto) {
      _autoBrightness = auto;
      notifyListeners();
    }
  }

  /// Send `0x08 06 00 00 03 <wireValue>` to both legs to persist the head-up
  /// (tilt-up) behaviour on the glasses. Also writes the choice to
  /// [AppSettingsStore] so it survives app restarts and is re-pushed on every
  /// fresh BLE reconnect (authoritative model). No-op for [HeadUpMode.unknown].
  Future<void> setHeadUpMode(HeadUpMode mode) async {
    final wire = mode.wireValue;
    if (wire == null) {
      return;
    }
    AppLog.info(
      '${DateTime.now()} head-up mode send: ${mode.name} (0x${wire.toRadixString(16).padLeft(2, '0')})',
      tag: 'DeviceStatus',
    );
    await Proto.setHeadUpMode(wire);
    await AppSettingsStore.get.setHeadUpMode(mode);
    if (_headUpMode != mode) {
      _headUpMode = mode;
      notifyListeners();
    }
  }

  /// Send `0x26 06 00 <seq> 05 <wireValue>` to both legs to persist the
  /// double-tap action on the glasses. Also writes the choice to
  /// [AppSettingsStore] so it survives app restarts and is re-pushed on every
  /// fresh BLE reconnect (authoritative model). No-op for
  /// [DoubleTapAction.unknown].
  Future<void> setDoubleTapAction(DoubleTapAction action) async {
    final wire = action.wireValue;
    if (wire == null) {
      return;
    }
    AppLog.info(
      '${DateTime.now()} double-tap action send: ${action.name} (0x${wire.toRadixString(16).padLeft(2, '0')})',
      tag: 'DeviceStatus',
    );
    await Proto.setDoubleTapAction(wire);
    await AppSettingsStore.get.setDoubleTapAction(action);
    if (_doubleTapAction != action) {
      _doubleTapAction = action;
      notifyListeners();
    }
  }

  /// Clear live-echo state on full disconnect so the UI doesn't show stale
  /// numbers pushed by the glasses firmware.
  ///
  /// **Only** the firmware-echoed fields are cleared: battery percentages,
  /// wear state, and the `F5 12` brightness echo. User-intent fields
  /// (`_autoBrightness`, `_headUpMode`, `_doubleTapAction`) are left
  /// untouched — they already match [AppSettingsStore] by construction and
  /// will be re-pushed to the glasses by the settings reconcile on the next
  /// fresh connect.
  void reset({required String source}) {
    final hadLiveState = _glassesBatteryPct != null ||
        _caseBatteryPct != null ||
        _wearState != WearState.unknown ||
        _brightnessLevel != null;
    _glassesBatteryPct = null;
    _caseBatteryPct = null;
    _wearState = WearState.unknown;
    _brightnessLevel = null;
    if (hadLiveState) {
      AppLog.info(
        '${DateTime.now()} cleared live device status from $source',
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
    unawaited(AppSettingsStore.get.setLastWearState(_wearState.name));
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
