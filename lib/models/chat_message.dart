enum ChatRole {
  user,
  assistant,
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
  });

  final ChatRole role;
  final String content;

  String get apiRole {
    switch (role) {
      case ChatRole.user:
        return 'user';
      case ChatRole.assistant:
        return 'assistant';
    }
  }

  Map<String, String> toApiMap() {
    return {
      'role': apiRole,
      'content': content,
    };
  }
}
