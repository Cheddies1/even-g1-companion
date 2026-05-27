import 'package:even_companion/services/app_settings_store.dart';

class AssistantBackendConfig {
  const AssistantBackendConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.chatModel,
    required this.transcriptionModel,
    required this.language,
    required this.maxOutputTokens,
    required this.maxResponseChars,
    required this.maxHistoryMessages,
    required this.systemPrompt,
    required this.connectTimeoutSeconds,
    required this.receiveTimeoutSeconds,
    required this.profileLabel,
    required this.usingRuntimeApiKey,
    required this.usingRuntimeBaseUrl,
    required this.usingRuntimeChatModel,
    required this.usingRuntimeTranscriptionModel,
  });

  static const _fallbackBaseUrl = String.fromEnvironment(
    'CHAT_API_BASE_URL',
    defaultValue: 'https://api.openai.com/v1',
  );
  static const _fallbackApiKey = String.fromEnvironment('OPENAI_API_KEY');
  static const _fallbackChatModel = String.fromEnvironment(
    'CHAT_MODEL',
    defaultValue: 'gpt-4.1-mini',
  );
  static const _fallbackTranscriptionModel = String.fromEnvironment(
    'CHAT_TRANSCRIPTION_MODEL',
    defaultValue: 'gpt-4o-mini-transcribe',
  );
  static const _language = String.fromEnvironment(
    'CHAT_TRANSCRIPTION_LANGUAGE',
    defaultValue: 'en',
  );
  static const _maxOutputTokens = int.fromEnvironment(
    'CHAT_MAX_OUTPUT_TOKENS',
    defaultValue: 220,
  );
  static const _maxResponseChars = int.fromEnvironment(
    'CHAT_MAX_RESPONSE_CHARS',
    defaultValue: 900,
  );
  static const _maxHistoryMessages = int.fromEnvironment(
    'CHAT_MAX_HISTORY_MESSAGES',
    defaultValue: 16,
  );
  // OpenAI-path timeouts (seconds). Match the prior hardcoded Dio values.
  static const _openAiConnectTimeoutSeconds = 20;
  static const _openAiReceiveTimeoutSeconds = 45;
  // Hermes-path defaults. Hermes is an agent that may run a tool loop, so its
  // receive timeout is generous by default and configurable in Settings.
  static const _fallbackHermesBaseUrl =
      String.fromEnvironment('HERMES_API_BASE_URL');
  static const _fallbackHermesChatModel = String.fromEnvironment(
    'HERMES_CHAT_MODEL',
    defaultValue: 'hermes-agent',
  );
  static const _hermesConnectTimeoutSeconds = 20;
  static const _hermesDefaultReceiveTimeoutSeconds = int.fromEnvironment(
    'HERMES_RECEIVE_TIMEOUT_SECONDS',
    defaultValue: 120,
  );
  static const _systemPrompt = String.fromEnvironment(
    'CHAT_SYSTEM_PROMPT',
    defaultValue:
        'You are an assistant responding to a user via smart glasses.\n'
        '\n'
        'Context about the user:\n'
        '- CPTO of a fintech organisation\n'
        '- Highly technical\n'
        '- Time-constrained\n'
        '- Values practical, real-world solutions over theory\n'
        '- Often working on live systems or prototypes\n'
        '\n'
        'Primary goal:\n'
        '- Deliver useful, actionable answers quickly\n'
        '\n'
        'Constraints:\n'
        '- Responses must be concise and easy to read on a small display\n'
        '- Prefer short sentences\n'
        '- Avoid long paragraphs\n'
        '- Break responses into small chunks\n'
        '- Default to brief answers unless explicitly asked for detail\n'
        '\n'
        'Style:\n'
        '- Direct and practical\n'
        '- No fluff\n'
        '- No unnecessary explanations\n'
        '- Assume competence, do not over-explain basics\n'
        '\n'
        'Behaviour:\n'
        '- Prioritise actionable next steps over background\n'
        '- If multiple options exist, give the best one first\n'
        '- Call out tradeoffs briefly if relevant\n'
        '- If unsure, say so briefly and suggest how to verify\n'
        '\n'
        'Length control:\n'
        '- If the response would be long:\n'
        '  - prioritise the most useful information first\n'
        '  - keep total length limited',
  );

  final String apiKey;
  final String baseUrl;
  final String chatModel;
  final String transcriptionModel;
  final String language;
  final int maxOutputTokens;
  final int maxResponseChars;
  final int maxHistoryMessages;
  final String systemPrompt;
  final int connectTimeoutSeconds;
  final int receiveTimeoutSeconds;

  /// Human-readable profile name ("OpenAI" / "Hermes") used in error
  /// messages so a misconfigured key reports the right backend.
  final String profileLabel;
  final bool usingRuntimeApiKey;
  final bool usingRuntimeBaseUrl;
  final bool usingRuntimeChatModel;
  final bool usingRuntimeTranscriptionModel;

  /// A profile is usable for a chat call only with both a key and a base URL.
  /// The OpenAI base URL always defaults, so this matches the prior
  /// key-only check there; for Hermes it also requires a configured URL.
  bool get isConfigured => apiKey.isNotEmpty && baseUrl.isNotEmpty;

  static AssistantBackendConfig resolve() {
    final settings = AppSettingsStore.get;
    final runtimeApiKey = settings.apiKey.trim();
    final runtimeBaseUrl = settings.baseUrl.trim();
    final runtimeChatModel = settings.chatModel.trim();
    final runtimeTranscriptionModel = settings.transcriptionModel.trim();

    return AssistantBackendConfig(
      apiKey: runtimeApiKey.isNotEmpty ? runtimeApiKey : _fallbackApiKey,
      baseUrl: runtimeBaseUrl.isNotEmpty ? runtimeBaseUrl : _fallbackBaseUrl,
      chatModel:
          runtimeChatModel.isNotEmpty ? runtimeChatModel : _fallbackChatModel,
      transcriptionModel: runtimeTranscriptionModel.isNotEmpty
          ? runtimeTranscriptionModel
          : _fallbackTranscriptionModel,
      language: _language,
      maxOutputTokens: _maxOutputTokens,
      maxResponseChars: _maxResponseChars,
      maxHistoryMessages: _maxHistoryMessages,
      systemPrompt: _systemPrompt,
      connectTimeoutSeconds: _openAiConnectTimeoutSeconds,
      receiveTimeoutSeconds: _openAiReceiveTimeoutSeconds,
      profileLabel: 'OpenAI',
      usingRuntimeApiKey: runtimeApiKey.isNotEmpty,
      usingRuntimeBaseUrl: runtimeBaseUrl.isNotEmpty,
      usingRuntimeChatModel: runtimeChatModel.isNotEmpty,
      usingRuntimeTranscriptionModel: runtimeTranscriptionModel.isNotEmpty,
    );
  }

  /// The Hermes chat profile. Reuses the glasses-native system prompt and the
  /// shared length caps; only the endpoint, key, model, and timeout differ.
  /// Never used for STT or note-tidy — those keep calling [resolve].
  static AssistantBackendConfig resolveHermes() {
    final settings = AppSettingsStore.get;
    final runtimeApiKey = settings.hermesApiKey.trim();
    final runtimeBaseUrl = settings.hermesBaseUrl.trim();
    final runtimeChatModel = settings.hermesChatModel.trim();
    final runtimeTimeout = settings.hermesTimeoutSeconds;

    return AssistantBackendConfig(
      apiKey: runtimeApiKey,
      baseUrl:
          runtimeBaseUrl.isNotEmpty ? runtimeBaseUrl : _fallbackHermesBaseUrl,
      chatModel: runtimeChatModel.isNotEmpty
          ? runtimeChatModel
          : _fallbackHermesChatModel,
      // Hermes does not serve transcription; carry the OpenAI default so the
      // field is populated but it is never exercised on this profile.
      transcriptionModel: _fallbackTranscriptionModel,
      language: _language,
      maxOutputTokens: _maxOutputTokens,
      maxResponseChars: _maxResponseChars,
      maxHistoryMessages: _maxHistoryMessages,
      systemPrompt: _systemPrompt,
      connectTimeoutSeconds: _hermesConnectTimeoutSeconds,
      receiveTimeoutSeconds:
          runtimeTimeout ?? _hermesDefaultReceiveTimeoutSeconds,
      profileLabel: 'Hermes',
      usingRuntimeApiKey: runtimeApiKey.isNotEmpty,
      usingRuntimeBaseUrl: runtimeBaseUrl.isNotEmpty,
      usingRuntimeChatModel: runtimeChatModel.isNotEmpty,
      usingRuntimeTranscriptionModel: false,
    );
  }
}
