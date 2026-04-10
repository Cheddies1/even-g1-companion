import 'package:demo_ai_even/models/chat_message.dart';

abstract class ChatBackend {
  Future<String> send({
    required List<ChatMessage> messages,
  });
}
