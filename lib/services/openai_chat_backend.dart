import 'dart:convert';

import 'package:even_companion/models/chat_message.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/assistant_backend_config.dart';
import 'package:even_companion/services/chat_backend.dart';
import 'package:dio/dio.dart';

class OpenAiChatBackend implements ChatBackend {
  OpenAiChatBackend({
    Dio? dio,
    AssistantBackendConfig Function()? configResolver,
  })  : _dio = dio,
        _configResolver = configResolver ?? AssistantBackendConfig.resolve;

  final Dio? _dio;

  /// Resolves the profile this backend talks to. Defaults to the OpenAI
  /// profile. Injectable so tests can supply a stub config.
  final AssistantBackendConfig Function() _configResolver;

  @override
  Future<String> send({
    required List<ChatMessage> messages,
  }) async {
    final config = _resolveConfig();
    final payload = _buildPayload(config, messages);

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

  @override
  Stream<String> stream({
    required List<ChatMessage> messages,
  }) async* {
    final config = _resolveConfig();
    final payload = _buildPayload(
      config,
      messages,
      stream: true,
    );

    try {
      final response = await _clientFor(config).post<ResponseBody>(
        '/chat/completions',
        data: payload,
        options: Options(responseType: ResponseType.stream),
      );
      final body = response.data;
      if (body == null) {
        throw const ChatBackendException(
          'Chat backend returned no stream body',
          kind: ChatBackendErrorKind.generic,
        );
      }

      await for (final line in body.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) {
          continue;
        }

        final data = trimmed.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') {
          continue;
        }

        final decoded = jsonDecode(data);
        final choices =
            decoded is Map<String, dynamic> ? decoded['choices'] : null;
        final choice =
            choices is List && choices.isNotEmpty ? choices.first : null;
        final delta = choice is Map ? choice['delta'] : null;
        final content = delta is Map ? delta['content'] : null;
        final text = _deltaToText(content);
        if (text.isEmpty) {
          continue;
        }
        yield text;
      }
    } on DioException catch (e) {
      throw _mapDioException(e);
    } on ChatBackendException {
      rethrow;
    } catch (e) {
      throw ChatBackendException(
        'Chat stream failed: $e',
        kind: ChatBackendErrorKind.generic,
      );
    }
  }

  Dio _clientFor(AssistantBackendConfig config) {
    return _dio ??
        Dio(
          BaseOptions(
            baseUrl: config.baseUrl,
            connectTimeout: Duration(seconds: config.connectTimeoutSeconds),
            receiveTimeout: Duration(seconds: config.receiveTimeoutSeconds),
            sendTimeout: Duration(seconds: config.receiveTimeoutSeconds),
            headers: {
              'Authorization': 'Bearer ${config.apiKey}',
              'Content-Type': 'application/json',
            },
          ),
        );
  }

  AssistantBackendConfig _resolveConfig() {
    final config = _configResolver();
    if (!config.isConfigured) {
      throw ChatBackendException(
        '${config.profileLabel} backend is not configured (missing key or URL)',
        kind: ChatBackendErrorKind.auth,
      );
    }
    return config;
  }

  Map<String, dynamic> _buildPayload(
    AssistantBackendConfig config,
    List<ChatMessage> messages, {
    bool stream = false,
  }) {
    final requestMessages = _shapeHistory(
      messages,
      maxHistoryMessages: config.maxHistoryMessages,
    );
    return {
      'model': config.chatModel,
      'max_completion_tokens': config.maxOutputTokens,
      'stream': stream,
      'messages': [
        {
          'role': 'system',
          'content': config.systemPrompt,
        },
        ...requestMessages.map((message) => message.toApiMap()),
      ],
    };
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

  String _deltaToText(dynamic content) {
    if (content is String) {
      return content;
    }
    if (content is List) {
      final buffer = StringBuffer();
      for (final item in content) {
        if (item is Map<String, dynamic> && item['type'] == 'text') {
          final text = item['text'];
          if (text is String) {
            buffer.write(text);
          }
        }
      }
      return buffer.toString();
    }
    return '';
  }

  ChatBackendException _mapDioException(DioException e) {
    final statusCode = e.response?.statusCode;
    final statusMessage = e.response?.statusMessage ?? e.message;
    if (statusCode == 401 || statusCode == 403) {
      return ChatBackendException(
        'Chat request failed: $statusCode $statusMessage',
        kind: ChatBackendErrorKind.auth,
      );
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return ChatBackendException(
        'Chat request timed out: $statusMessage',
        kind: ChatBackendErrorKind.timeout,
      );
    }
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.unknown) {
      return ChatBackendException(
        'Chat request network error: $statusMessage',
        kind: ChatBackendErrorKind.network,
      );
    }
    return ChatBackendException(
      statusCode == null
          ? 'Chat request failed: $statusMessage'
          : 'Chat request failed: $statusCode $statusMessage',
      kind: ChatBackendErrorKind.generic,
    );
  }
}
