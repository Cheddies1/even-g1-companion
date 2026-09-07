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
    required this.requiresApiKey,
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
  // Transcription runs on the self-hosted Speaches whisper-server on
  // deepthought rather than OpenAI: unmetered, and measured at 0.34 s for
  // 9.7 s of glasses audio (~28x realtime on the RTX 3090), which beats the
  // OpenAI round trip. Tailnet-only and unauthenticated by design.
  static const _fallbackTranscriptionBaseUrl = String.fromEnvironment(
    'TRANSCRIPTION_API_BASE_URL',
    defaultValue: 'http://deepthought:56478/v1',
  );
  static const _fallbackTranscriptionModel = String.fromEnvironment(
    'CHAT_TRANSCRIPTION_MODEL',
    defaultValue: 'deepdml/faster-whisper-large-v3-turbo-ct2',
  );
  // Local Whisper answers in well under a second for utterance-length audio,
  // so a short connect timeout is what makes an asleep or off-tailnet box
  // fail fast instead of stalling the user mid-gesture. The receive budget
  // stays generous for the occasional long clip.
  static const _transcriptionConnectTimeoutSeconds = 8;
  static const _transcriptionReceiveTimeoutSeconds = 60;
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

  /// Human-readable profile name used in error messages so a misconfigured
  /// key names the backend that rejected it.
  final String profileLabel;

  /// Whether this profile needs a bearer token to be usable. False for the
  /// self-hosted transcription profile - Speaches on the tailnet is
  /// unauthenticated, so demanding a key would make a working setup look
  /// unconfigured.
  final bool requiresApiKey;
  final bool usingRuntimeApiKey;
  final bool usingRuntimeBaseUrl;
  final bool usingRuntimeChatModel;
  final bool usingRuntimeTranscriptionModel;

  /// A profile is usable when it has a base URL and, if it needs one, a key.
  bool get isConfigured =>
      baseUrl.isNotEmpty && (!requiresApiKey || apiKey.isNotEmpty);

  /// Whether to attach `Authorization` on requests to this profile.
  ///
  /// Only over TLS. The local transcription endpoint is plain HTTP inside the
  /// WireGuard tailnet, which needs no token - and putting an OpenAI bearer
  /// on a cleartext request to a host that ignores it is how credentials end
  /// up somewhere they were never needed.
  bool get shouldSendApiKey =>
      apiKey.isNotEmpty && baseUrl.toLowerCase().startsWith('https://');

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
      requiresApiKey: true,
      usingRuntimeApiKey: runtimeApiKey.isNotEmpty,
      usingRuntimeBaseUrl: runtimeBaseUrl.isNotEmpty,
      usingRuntimeChatModel: runtimeChatModel.isNotEmpty,
      usingRuntimeTranscriptionModel: runtimeTranscriptionModel.isNotEmpty,
    );
  }

  /// The speech-to-text profile, used by Quick Ask, Chat mode and QuickNote.
  ///
  /// Separate from [resolve] because STT and the reasoning call no longer
  /// share a host: transcription goes to the local whisper-server while chat
  /// stays on OpenAI. Needs no API key, and deliberately has no fallback -
  /// an unreachable box reports that plainly rather than silently spending
  /// OpenAI credit.
  static AssistantBackendConfig resolveTranscription() {
    final settings = AppSettingsStore.get;
    final runtimeBaseUrl = settings.transcriptionBaseUrl.trim();
    final runtimeModel = settings.transcriptionModel.trim();

    return AssistantBackendConfig(
      // Carried so a self-hosted endpoint that does want a token can use the
      // configured key, but only over TLS - see [shouldSendApiKey].
      apiKey: settings.apiKey.trim(),
      baseUrl: runtimeBaseUrl.isNotEmpty
          ? runtimeBaseUrl
          : _fallbackTranscriptionBaseUrl,
      // Not used on this profile; the chat model belongs to [resolve].
      chatModel: _fallbackChatModel,
      transcriptionModel:
          runtimeModel.isNotEmpty ? runtimeModel : _fallbackTranscriptionModel,
      language: _language,
      maxOutputTokens: _maxOutputTokens,
      maxResponseChars: _maxResponseChars,
      maxHistoryMessages: _maxHistoryMessages,
      systemPrompt: _systemPrompt,
      connectTimeoutSeconds: _transcriptionConnectTimeoutSeconds,
      receiveTimeoutSeconds: _transcriptionReceiveTimeoutSeconds,
      profileLabel: 'Whisper',
      requiresApiKey: false,
      usingRuntimeApiKey: false,
      usingRuntimeBaseUrl: runtimeBaseUrl.isNotEmpty,
      usingRuntimeChatModel: false,
      usingRuntimeTranscriptionModel: runtimeModel.isNotEmpty,
    );
  }
}
