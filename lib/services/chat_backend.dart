import 'package:even_companion/models/chat_message.dart';

abstract class ChatBackend {
  Future<String> send({
    required List<ChatMessage> messages,
  });

  Stream<String> stream({
    required List<ChatMessage> messages,
  }) async* {
    yield await send(messages: messages);
  }
}

enum ChatBackendErrorKind {
  auth,
  timeout,
  network,
  generic,
}
