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

  bool _initialized = false;
  bool _initializing = false;

  String _apiKey = '';
  String _baseUrl = '';
  String _chatModel = '';
  String _transcriptionModel = '';

  bool get isInitialized => _initialized;
  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  String get chatModel => _chatModel;
  String get transcriptionModel => _transcriptionModel;

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
      _initialized = true;
    } finally {
      _initializing = false;
    }
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
