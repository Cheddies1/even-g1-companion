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
  static const _systemPrompt = String.fromEnvironment(
    'CHAT_SYSTEM_PROMPT',
    defaultValue:
        'You are a concise assistant for Even smart glasses. Give practical answers that are brief, clear, and easy to read on a heads-up display.',
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
      );
    }

    final payload = {
      'model': _model,
      'messages': [
        {
          'role': 'system',
          'content': _systemPrompt,
        },
        ...messages.map((message) => message.toApiMap()),
      ],
    };

    try {
      final response = await _dio.post('/chat/completions', data: payload);
      final content =
          response.data['choices']?[0]?['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const ChatBackendException('Chat backend returned no text');
      }
      return content.trim();
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final statusMessage = e.response?.statusMessage ?? e.message;
      throw ChatBackendException(
        statusCode == null
            ? 'Chat request failed: $statusMessage'
            : 'Chat request failed: $statusCode $statusMessage',
      );
    }
  }
}

class ChatBackendException implements Exception {
  const ChatBackendException(this.message);

  final String message;

  @override
  String toString() => message;
}
