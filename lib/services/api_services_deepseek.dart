import 'package:even_companion/services/app_log.dart';
import 'package:dio/dio.dart';

class ApiDeepSeekService {
  late Dio _dio;

  ApiDeepSeekService() {
    _dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.deepseek.com',
        headers: {
          'Authorization': 'Bearer ${const String.fromEnvironment("DASHSCOPE_API_KEY", defaultValue: "sk-5d8fa6e859d64b3c84862b90a9eb45d1")}', // replace with your apikey
          'Content-Type': 'application/json',
        },
      ),
    );
  }

  Future<String> sendChatRequest(String question) async {
    final data = {
      "model": "deepseek-chat",
      "messages": [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": question}
      ],
    };
    AppLog.debug('sendChatRequest data=$data', tag: 'DeepSeek');

    try {
      final response = await _dio.post('/chat/completions', data: data);

      if (response.statusCode == 200) {
          AppLog.debug('Response: ${response.data}', tag: 'DeepSeek');

          final data = response.data;
          final content = data['choices']?[0]?['message']?['content'] ?? "Unable to answer the question";
          return content;
      } else {
        AppLog.error(
          'Request failed with status: ${response.statusCode}',
          tag: 'DeepSeek',
        );
        return "Request failed with status: ${response.statusCode}";
      }
    } on DioError catch (e) {
      if (e.response != null) {
        AppLog.error(
          'Error: ${e.response?.statusCode}, ${e.response?.data}',
          tag: 'DeepSeek',
        );
        return "AI request error: ${e.response?.statusCode}, ${e.response?.data}";
      } else {
        AppLog.error('Error: ${e.message}', tag: 'DeepSeek');
        return "AI request error: ${e.message}";
      }
    }
  }
}
