import 'dart:io';

import 'package:demo_ai_even/services/assistant_backend_config.dart';
import 'package:dio/dio.dart';

class OpenAiTranscriptionService {
  OpenAiTranscriptionService({
    Dio? dio,
  }) : _dio = dio;

  final Dio? _dio;

  Future<String> transcribe(String filePath) async {
    final config = AssistantBackendConfig.resolve();
    if (!config.isConfigured) {
      throw const ChatTranscriptionException(
        'Missing OPENAI_API_KEY for speech transcription',
        kind: ChatTranscriptionErrorKind.auth,
      );
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      throw const ChatTranscriptionException(
        'Recorded audio file not found',
        kind: ChatTranscriptionErrorKind.generic,
      );
    }

    try {
      final formData = FormData.fromMap({
        'model': config.transcriptionModel,
        'language': config.language,
        'response_format': 'json',
        'file': await MultipartFile.fromFile(
          file.path,
          filename: file.uri.pathSegments.isEmpty
              ? 'chat.wav'
              : file.uri.pathSegments.last,
        ),
      });
      final response = await _clientFor(config).post(
        '/audio/transcriptions',
        data: formData,
      );
      final text = response.data['text'] as String?;
      if (text == null || text.trim().isEmpty) {
        return '';
      }
      return text.trim();
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      final statusMessage = e.response?.statusMessage ?? e.message;
      if (statusCode == 401 || statusCode == 403) {
        throw ChatTranscriptionException(
          'Transcription failed: $statusCode $statusMessage',
          kind: ChatTranscriptionErrorKind.auth,
        );
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw ChatTranscriptionException(
          'Transcription timed out: $statusMessage',
          kind: ChatTranscriptionErrorKind.timeout,
        );
      }
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        throw ChatTranscriptionException(
          'Transcription network error: $statusMessage',
          kind: ChatTranscriptionErrorKind.network,
        );
      }
      throw ChatTranscriptionException(
        statusCode == null
            ? 'Transcription failed: $statusMessage'
            : 'Transcription failed: $statusCode $statusMessage',
        kind: ChatTranscriptionErrorKind.generic,
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
            },
          ),
        );
  }
}

enum ChatTranscriptionErrorKind {
  auth,
  timeout,
  network,
  generic,
}

class ChatTranscriptionException implements Exception {
  const ChatTranscriptionException(
    this.message, {
    this.kind = ChatTranscriptionErrorKind.generic,
  });

  final String message;
  final ChatTranscriptionErrorKind kind;

  @override
  String toString() => message;
}
