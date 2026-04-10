import 'package:demo_ai_even/models/chat_message.dart';
import 'package:demo_ai_even/services/chat_backend.dart';
import 'package:dio/dio.dart';

class OpenAiChatBackend implements ChatBackend {
  OpenAiChatBackend({
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl,
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 45),
                sendTimeout: const Duration(seconds: 45),
                headers: {
                  'Authorization': 'Bearer $_apiKey',
                  'Content-Type': 'application/json',
                },
              ),
            );

  static const _baseUrl = String.fromEnvironment(
    'CHAT_API_BASE_URL',
    defaultValue: 'https://api.openai.com/v1',
  );
  static const _apiKey = String.fromEnvironment('OPENAI_API_KEY');
  static const _model = String.fromEnvironment(
    'CHAT_MODEL',
    defaultValue: 'gpt-4.1-mini',
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

  final Dio _dio;

  static bool get isConfigured => _apiKey.isNotEmpty;

  @override
  Future<String> send({
    required List<ChatMessage> messages,
  }) async {
    if (!isConfigured) {
      throw const ChatBackendException(
        'Missing OPENAI_API_KEY for Chat mode',
        kind: ChatBackendErrorKind.auth,
      );
    }

    final requestMessages = _shapeHistory(messages);
    final payload = {
      'model': _model,
      'max_completion_tokens': _maxOutputTokens,
      'messages': [
        {
          'role': 'system',
          'content': _systemPrompt,
        },
        ...requestMessages.map((message) => message.toApiMap()),
      ],
    };

    try {
      final response = await _dio.post('/chat/completions', data: payload);
      final content =
          response.data['choices']?[0]?['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const ChatBackendException(
          'Chat backend returned no text',
          kind: ChatBackendErrorKind.generic,
        );
      }
      return _shapeResponse(content.trim());
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final statusMessage = e.response?.statusMessage ?? e.message;
      if (statusCode == 401 || statusCode == 403) {
        throw ChatBackendException(
          'Chat request failed: $statusCode $statusMessage',
          kind: ChatBackendErrorKind.auth,
        );
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw ChatBackendException(
          'Chat request timed out: $statusMessage',
          kind: ChatBackendErrorKind.timeout,
        );
      }
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        throw ChatBackendException(
          'Chat request network error: $statusMessage',
          kind: ChatBackendErrorKind.network,
        );
      }
      throw ChatBackendException(
        statusCode == null
            ? 'Chat request failed: $statusMessage'
            : 'Chat request failed: $statusCode $statusMessage',
        kind: ChatBackendErrorKind.generic,
      );
    }
  }

  List<ChatMessage> _shapeHistory(List<ChatMessage> messages) {
    if (messages.length <= _maxHistoryMessages) {
      return messages;
    }
    final trimmed = messages.sublist(messages.length - _maxHistoryMessages);
    print(
      '${DateTime.now()} Chat backend: trimmed history from ${messages.length} to ${trimmed.length} messages',
    );
    return trimmed;
  }

  String _shapeResponse(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+\n'), '\n').trim();
    if (cleaned.length <= _maxResponseChars) {
      return cleaned;
    }
    final truncated = cleaned.substring(0, _maxResponseChars).trimRight();
    return '$truncated…';
  }
}

class ChatBackendException implements Exception {
  const ChatBackendException(
    this.message, {
    this.kind = ChatBackendErrorKind.generic,
  });

  final String message;
  final ChatBackendErrorKind kind;

  @override
  String toString() => message;
}
