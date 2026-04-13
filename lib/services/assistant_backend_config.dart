import 'package:demo_ai_even/services/app_settings_store.dart';

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
  final bool usingRuntimeApiKey;
  final bool usingRuntimeBaseUrl;
  final bool usingRuntimeChatModel;
  final bool usingRuntimeTranscriptionModel;

  bool get isConfigured => apiKey.isNotEmpty;

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
      usingRuntimeApiKey: runtimeApiKey.isNotEmpty,
      usingRuntimeBaseUrl: runtimeBaseUrl.isNotEmpty,
      usingRuntimeChatModel: runtimeChatModel.isNotEmpty,
      usingRuntimeTranscriptionModel: runtimeTranscriptionModel.isNotEmpty,
    );
  }
}
