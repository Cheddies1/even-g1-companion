enum ChatRole {
  user,
  assistant,
}

extension ChatRoleX on ChatRole {
  String get apiRole {
    switch (this) {
      case ChatRole.user:
        return 'user';
      case ChatRole.assistant:
        return 'assistant';
    }
  }
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
  });

  final ChatRole role;
  final String content;

  String get apiRole {
    return role.apiRole;
  }

  Map<String, String> toApiMap() {
    return {
      'role': apiRole,
      'content': content,
    };
  }
}
