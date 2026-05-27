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
