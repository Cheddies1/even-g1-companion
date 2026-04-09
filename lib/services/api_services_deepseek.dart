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
    print("sendChatRequest------data----------$data--------");

    try {
      final response = await _dio.post('/chat/completions', data: data);

      if (response.statusCode == 200) {
          print("Response: ${response.data}");

          final data = response.data;
          final content = data['choices']?[0]?['message']?['content'] ?? "Unable to answer the question";
          return content;
      } else {
        print("Request failed with status: ${response.statusCode}");
        return "Request failed with status: ${response.statusCode}";
      }
    } on DioError catch (e) {
      if (e.response != null) {
        print("Error: ${e.response?.statusCode}, ${e.response?.data}");
        return "AI request error: ${e.response?.statusCode}, ${e.response?.data}";
      } else {
        print("Error: ${e.message}");
        return "AI request error: ${e.message}";
      }
    }
  }
}
