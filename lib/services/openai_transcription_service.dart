import 'dart:io';

import 'package:dio/dio.dart';

class OpenAiTranscriptionService {
  OpenAiTranscriptionService({
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
                },
              ),
            );

  static const _baseUrl = String.fromEnvironment(
    'CHAT_API_BASE_URL',
    defaultValue: 'https://api.openai.com/v1',
  );
  static const _apiKey = String.fromEnvironment('OPENAI_API_KEY');
  static const _model = String.fromEnvironment(
    'CHAT_TRANSCRIPTION_MODEL',
    defaultValue: 'gpt-4o-mini-transcribe',
  );
  static const _language = String.fromEnvironment(
    'CHAT_TRANSCRIPTION_LANGUAGE',
    defaultValue: 'en',
  );

  final Dio _dio;

  static bool get isConfigured => _apiKey.isNotEmpty;

  Future<String> transcribe(String filePath) async {
    if (!isConfigured) {
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
        'model': _model,
        'language': _language,
        'response_format': 'json',
        'file': await MultipartFile.fromFile(
          file.path,
          filename: file.uri.pathSegments.isEmpty
              ? 'chat.wav'
              : file.uri.pathSegments.last,
        ),
      });
      final response = await _dio.post(
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
