import 'package:demo_ai_even/services/device_status_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettingsStore extends ChangeNotifier {
  AppSettingsStore._();

  static AppSettingsStore? _instance;
  static AppSettingsStore get get => _instance ??= AppSettingsStore._();

  static const _secureStorage = FlutterSecureStorage();

  static const _apiKeyStorageKey = 'assistant.api_key';
  static const _baseUrlPrefKey = 'assistant.base_url';
  static const _chatModelPrefKey = 'assistant.chat_model';
  static const _transcriptionModelPrefKey = 'assistant.transcription_model';
  static const _headUpModePrefKey = 'firmware.head_up_mode';
  static const _doubleTapActionPrefKey = 'firmware.double_tap_action';
  static const _brightnessLevelPrefKey = 'firmware.brightness_level';
  static const _autoBrightnessPrefKey = 'firmware.auto_brightness';
  static const _lastChannelNumberPrefKey = 'ble.last_channel_number';
  static const _lastWearStatePrefKey = 'ble.last_wear_state';

  bool _initialized = false;
  bool _initializing = false;

  String _apiKey = '';
  String _baseUrl = '';
  String _chatModel = '';
  String _transcriptionModel = '';
  HeadUpMode _headUpMode = HeadUpMode.unknown;
  DoubleTapAction _doubleTapAction = DoubleTapAction.unknown;
  int? _brightnessLevel;
  bool _autoBrightness = false;
  String _lastChannelNumber = '';
  String _lastWearState = '';

  bool get isInitialized => _initialized;
  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  String get chatModel => _chatModel;
  String get transcriptionModel => _transcriptionModel;

  /// Last head-up mode the user picked from the Settings screen, or
  /// [HeadUpMode.unknown] if they have never picked. Persisted across
  /// app restarts.
  HeadUpMode get headUpMode => _headUpMode;

  /// Last double-tap action the user picked. Persistence behaviour
  /// matches [headUpMode].
  DoubleTapAction get doubleTapAction => _doubleTapAction;

  /// Last brightness level the user sent to the glasses via the home screen
  /// slider, or null if the user has never interacted with it. Persisted
  /// across app restarts. Range 0..42.
  int? get brightnessLevel => _brightnessLevel;

  /// Whether auto brightness was last sent as enabled. Persisted across
  /// app restarts; defaults to false.
  bool get autoBrightness => _autoBrightness;

  /// Last BLE channel number the app successfully connected to, or empty
  /// string if the app has never connected. Persisted across app restarts.
  String get lastChannelNumber => _lastChannelNumber;

  /// Name of the [WearState] enum value last observed from the glasses, or
  /// empty string if no wear event has been received yet. Persisted across
  /// app restarts so auto-reconnect can skip a cradle-docked glasses pair.
  String get lastWearState => _lastWearState;

  bool get hasRuntimeApiKey => _apiKey.trim().isNotEmpty;

  Future<void> init() async {
    if (_initialized || _initializing) {
      return;
    }
    _initializing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _apiKey =
          (await _secureStorage.read(key: _apiKeyStorageKey) ?? '').trim();
      _baseUrl = (prefs.getString(_baseUrlPrefKey) ?? '').trim();
      _chatModel = (prefs.getString(_chatModelPrefKey) ?? '').trim();
      _transcriptionModel =
          (prefs.getString(_transcriptionModelPrefKey) ?? '').trim();
      _headUpMode = _readHeadUpMode(prefs);
      _doubleTapAction = _readDoubleTapAction(prefs);
      _brightnessLevel = prefs.containsKey(_brightnessLevelPrefKey)
          ? prefs.getInt(_brightnessLevelPrefKey)
          : null;
      _autoBrightness = prefs.getBool(_autoBrightnessPrefKey) ?? false;
      _lastChannelNumber =
          (prefs.getString(_lastChannelNumberPrefKey) ?? '').trim();
      _lastWearState = (prefs.getString(_lastWearStatePrefKey) ?? '').trim();
      _initialized = true;
    } finally {
      _initializing = false;
    }
  }

  HeadUpMode _readHeadUpMode(SharedPreferences prefs) {
    final raw = prefs.getString(_headUpModePrefKey);
    if (raw == null || raw.isEmpty) {
      return HeadUpMode.unknown;
    }
    for (final mode in HeadUpMode.values) {
      if (mode.name == raw) {
        return mode;
      }
    }
    return HeadUpMode.unknown;
  }

  DoubleTapAction _readDoubleTapAction(SharedPreferences prefs) {
    final raw = prefs.getString(_doubleTapActionPrefKey);
    if (raw == null || raw.isEmpty) {
      return DoubleTapAction.unknown;
    }
    for (final action in DoubleTapAction.values) {
      if (action.name == raw) {
        return action;
      }
    }
    return DoubleTapAction.unknown;
  }

  Future<void> saveAssistantSettings({
    required String apiKey,
    required String baseUrl,
    required String chatModel,
    required String transcriptionModel,
  }) async {
    await init();
    final normalizedApiKey = apiKey.trim();
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedChatModel = chatModel.trim();
    final normalizedTranscriptionModel = transcriptionModel.trim();

    final prefs = await SharedPreferences.getInstance();

    if (normalizedApiKey.isEmpty) {
      await _secureStorage.delete(key: _apiKeyStorageKey);
    } else {
      await _secureStorage.write(
        key: _apiKeyStorageKey,
        value: normalizedApiKey,
      );
    }

    await _writeOptionalPref(
      prefs: prefs,
      key: _baseUrlPrefKey,
      value: normalizedBaseUrl,
    );
    await _writeOptionalPref(
      prefs: prefs,
      key: _chatModelPrefKey,
      value: normalizedChatModel,
    );
    await _writeOptionalPref(
      prefs: prefs,
      key: _transcriptionModelPrefKey,
      value: normalizedTranscriptionModel,
    );

    _apiKey = normalizedApiKey;
    _baseUrl = normalizedBaseUrl;
    _chatModel = normalizedChatModel;
    _transcriptionModel = normalizedTranscriptionModel;
    notifyListeners();
  }

  /// Persist the user's head-up choice across app restarts.
  ///
  /// Saves only — does not push to the firmware. The companion app's
  /// `DeviceStatusService.setHeadUpMode` orchestrates the BLE write and
  /// then calls this for storage.
  Future<void> setHeadUpMode(HeadUpMode mode) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    if (mode == HeadUpMode.unknown) {
      await prefs.remove(_headUpModePrefKey);
    } else {
      await prefs.setString(_headUpModePrefKey, mode.name);
    }
    if (_headUpMode != mode) {
      _headUpMode = mode;
      notifyListeners();
    }
  }

  /// Persist the user's double-tap choice across app restarts. See
  /// [setHeadUpMode] for the orchestration model.
  Future<void> setDoubleTapAction(DoubleTapAction action) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    if (action == DoubleTapAction.unknown) {
      await prefs.remove(_doubleTapActionPrefKey);
    } else {
      await prefs.setString(_doubleTapActionPrefKey, action.name);
    }
    if (_doubleTapAction != action) {
      _doubleTapAction = action;
      notifyListeners();
    }
  }

  /// Persist the brightness level the user last sent to the glasses.
  ///
  /// Pass null to clear the persisted level (e.g. on factory reset). See
  /// [setHeadUpMode] for the orchestration model.
  Future<void> setBrightnessLevel(int? level) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    if (level == null) {
      await prefs.remove(_brightnessLevelPrefKey);
    } else {
      await prefs.setInt(_brightnessLevelPrefKey, level);
    }
    if (_brightnessLevel != level) {
      _brightnessLevel = level;
      notifyListeners();
    }
  }

  /// Persist the auto-brightness flag the user last sent to the glasses. See
  /// [setHeadUpMode] for the orchestration model.
  Future<void> setAutoBrightness(bool auto) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoBrightnessPrefKey, auto);
    if (_autoBrightness != auto) {
      _autoBrightness = auto;
      notifyListeners();
    }
  }

  Future<void> setLastChannelNumber(String channel) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    final trimmed = channel.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_lastChannelNumberPrefKey);
    } else {
      await prefs.setString(_lastChannelNumberPrefKey, trimmed);
    }
    if (_lastChannelNumber != trimmed) {
      _lastChannelNumber = trimmed;
      notifyListeners();
    }
  }

  Future<void> setLastWearState(String stateName) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    final trimmed = stateName.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_lastWearStatePrefKey);
    } else {
      await prefs.setString(_lastWearStatePrefKey, trimmed);
    }
    if (_lastWearState != trimmed) {
      _lastWearState = trimmed;
      notifyListeners();
    }
  }

  Future<void> _writeOptionalPref({
    required SharedPreferences prefs,
    required String key,
    required String value,
  }) async {
    if (value.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, value);
  }
}
