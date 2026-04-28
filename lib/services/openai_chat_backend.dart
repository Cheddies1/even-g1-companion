import 'package:demo_ai_even/models/chat_message.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/assistant_backend_config.dart';
import 'package:demo_ai_even/services/chat_backend.dart';
import 'package:dio/dio.dart';

class OpenAiChatBackend implements ChatBackend {
  OpenAiChatBackend({
    Dio? dio,
  }) : _dio = dio;

  final Dio? _dio;

  @override
  Future<String> send({
    required List<ChatMessage> messages,
  }) async {
    final config = AssistantBackendConfig.resolve();
    if (!config.isConfigured) {
      throw const ChatBackendException(
        'Missing OPENAI_API_KEY for Chat mode',
        kind: ChatBackendErrorKind.auth,
      );
    }

    final requestMessages = _shapeHistory(
      messages,
      maxHistoryMessages: config.maxHistoryMessages,
    );
    final payload = {
      'model': config.chatModel,
      'max_completion_tokens': config.maxOutputTokens,
      'messages': [
        {
          'role': 'system',
          'content': config.systemPrompt,
        },
        ...requestMessages.map((message) => message.toApiMap()),
      ],
    };

    try {
      final response = await _clientFor(config).post(
        '/chat/completions',
        data: payload,
      );
      final content =
          response.data['choices']?[0]?['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const ChatBackendException(
          'Chat backend returned no text',
          kind: ChatBackendErrorKind.generic,
        );
      }
      return _shapeResponse(
        content.trim(),
        maxResponseChars: config.maxResponseChars,
      );
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

  Dio _clientFor(AssistantBackendConfig config) {
    return _dio ??
        Dio(
          BaseOptions(
            baseUrl: config.baseUrl,
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 45),
            sendTimeout: const Duration(seconds: 45),
            headers: {
              'Authorization': 'Bearer ${config.apiKey}',
              'Content-Type': 'application/json',
            },
          ),
        );
  }

  List<ChatMessage> _shapeHistory(
    List<ChatMessage> messages, {
    required int maxHistoryMessages,
  }) {
    if (messages.length <= maxHistoryMessages) {
      return messages;
    }
    final trimmed = messages.sublist(messages.length - maxHistoryMessages);
    AppLog.debug(
      '${DateTime.now()} trimmed history from ${messages.length} to ${trimmed.length} messages',
      tag: 'ChatBackend',
    );
    return trimmed;
  }

  String _shapeResponse(String text, {required int maxResponseChars}) {
    final cleaned = text.replaceAll(RegExp(r'\s+\n'), '\n').trim();
    if (cleaned.length <= maxResponseChars) {
      return cleaned;
    }
    final truncated = cleaned.substring(0, maxResponseChars).trimRight();
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
