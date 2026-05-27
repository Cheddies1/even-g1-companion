import 'package:even_companion/services/device_status_service.dart';
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
  static const _assistantBackendPrefKey = 'assistant.backend';
  static const _hermesFallbackPrefKey = 'assistant.hermes_fallback';
  static const _hermesApiKeyStorageKey = 'assistant.hermes_api_key';
  static const _hermesBaseUrlPrefKey = 'assistant.hermes_base_url';
  static const _hermesChatModelPrefKey = 'assistant.hermes_chat_model';
  static const _hermesTimeoutPrefKey = 'assistant.hermes_timeout_seconds';
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
  AssistantBackendKind _assistantBackend = AssistantBackendKind.openai;
  bool _hermesFallbackEnabled = true;
  String _hermesApiKey = '';
  String _hermesBaseUrl = '';
  String _hermesChatModel = '';
  int? _hermesTimeoutSeconds;
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

  /// Which backend the Quick Ask / Chat reasoning call routes to. STT and
  /// note-tidy always stay on the OpenAI profile regardless of this choice.
  /// Defaults to [AssistantBackendKind.openai].
  AssistantBackendKind get assistantBackend => _assistantBackend;

  /// When [assistantBackend] is Hermes and Hermes is unreachable, fall back
  /// to the OpenAI direct path. Defaults to true.
  bool get hermesFallbackEnabled => _hermesFallbackEnabled;

  /// Hermes bearer token. Stored in secure storage, never SharedPreferences.
  String get hermesApiKey => _hermesApiKey;

  /// Hermes OpenAI-compatible base URL, e.g. `http://deepthought:8642/v1`.
  String get hermesBaseUrl => _hermesBaseUrl;

  /// Hermes chat model id. Empty falls back to the build default.
  String get hermesChatModel => _hermesChatModel;

  /// Hermes chat receive timeout in seconds, or null to use the build
  /// default. Hermes may run a tool loop, so this is typically higher than
  /// the OpenAI path's 45 s.
  int? get hermesTimeoutSeconds => _hermesTimeoutSeconds;

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
      _assistantBackend = _readAssistantBackend(prefs);
      _hermesFallbackEnabled =
          prefs.getBool(_hermesFallbackPrefKey) ?? true;
      _hermesApiKey =
          (await _secureStorage.read(key: _hermesApiKeyStorageKey) ?? '')
              .trim();
      _hermesBaseUrl = (prefs.getString(_hermesBaseUrlPrefKey) ?? '').trim();
      _hermesChatModel =
          (prefs.getString(_hermesChatModelPrefKey) ?? '').trim();
      _hermesTimeoutSeconds = prefs.containsKey(_hermesTimeoutPrefKey)
          ? prefs.getInt(_hermesTimeoutPrefKey)
          : null;
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

  AssistantBackendKind _readAssistantBackend(SharedPreferences prefs) {
    final raw = prefs.getString(_assistantBackendPrefKey);
    if (raw == null || raw.isEmpty) {
      return AssistantBackendKind.openai;
    }
    for (final kind in AssistantBackendKind.values) {
      if (kind.name == raw) {
        return kind;
      }
    }
    return AssistantBackendKind.openai;
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

  /// Persist the Hermes profile. The API key lives in secure storage; URL,
  /// model, and timeout live in SharedPreferences. Empty optional fields are
  /// cleared so the build defaults apply.
  Future<void> saveHermesSettings({
    required String apiKey,
    required String baseUrl,
    required String chatModel,
    int? timeoutSeconds,
  }) async {
    await init();
    final normalizedApiKey = apiKey.trim();
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedChatModel = chatModel.trim();

    final prefs = await SharedPreferences.getInstance();

    if (normalizedApiKey.isEmpty) {
      await _secureStorage.delete(key: _hermesApiKeyStorageKey);
    } else {
      await _secureStorage.write(
        key: _hermesApiKeyStorageKey,
        value: normalizedApiKey,
      );
    }

    await _writeOptionalPref(
      prefs: prefs,
      key: _hermesBaseUrlPrefKey,
      value: normalizedBaseUrl,
    );
    await _writeOptionalPref(
      prefs: prefs,
      key: _hermesChatModelPrefKey,
      value: normalizedChatModel,
    );
    if (timeoutSeconds == null) {
      await prefs.remove(_hermesTimeoutPrefKey);
    } else {
      await prefs.setInt(_hermesTimeoutPrefKey, timeoutSeconds);
    }

    _hermesApiKey = normalizedApiKey;
    _hermesBaseUrl = normalizedBaseUrl;
    _hermesChatModel = normalizedChatModel;
    _hermesTimeoutSeconds = timeoutSeconds;
    notifyListeners();
  }

  /// Persist which backend the reasoning call routes to.
  Future<void> setAssistantBackend(AssistantBackendKind kind) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_assistantBackendPrefKey, kind.name);
    if (_assistantBackend != kind) {
      _assistantBackend = kind;
      notifyListeners();
    }
  }

  /// Persist whether OpenAI fallback is allowed when Hermes is unreachable.
  Future<void> setHermesFallbackEnabled(bool enabled) async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hermesFallbackPrefKey, enabled);
    if (_hermesFallbackEnabled != enabled) {
      _hermesFallbackEnabled = enabled;
      notifyListeners();
    }
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

/// Which backend the Quick Ask / Chat reasoning call routes to.
enum AssistantBackendKind { openai, hermes }
