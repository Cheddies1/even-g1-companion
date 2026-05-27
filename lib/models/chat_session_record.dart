/// Which voice surface produced a saved session.
enum ChatSessionKind {
  /// Tilt-up Chat mode (a full, multi-turn conversation).
  chat('chat', 'Chat'),

  /// Left-hold Glance Quick Ask (an ephemeral ask-and-answer window).
  quickAsk('quick_ask', 'Quick Ask');

  const ChatSessionKind(this.wireValue, this.label);

  /// Value persisted in the `kind` column.
  final String wireValue;

  /// Human-readable label shown in the chat log.
  final String label;

  static ChatSessionKind fromWire(Object? value) {
    for (final kind in ChatSessionKind.values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    // Rows written before the kind column existed default to Chat.
    return ChatSessionKind.chat;
  }
}

class ChatSessionRecord {
  const ChatSessionRecord({
    required this.id,
    required this.startedAt,
    this.kind = ChatSessionKind.chat,
    this.endedAt,
    this.titleText,
    this.previewText,
  });

  final String id;
  final DateTime startedAt;
  final ChatSessionKind kind;
  final DateTime? endedAt;
  final String? titleText;
  final String? previewText;

  factory ChatSessionRecord.fromMap(Map<String, Object?> map) {
    return ChatSessionRecord(
      id: map['id'] as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(map['started_at'] as int),
      kind: ChatSessionKind.fromWire(map['kind']),
      endedAt: map['ended_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['ended_at'] as int),
      titleText: map['title_text'] as String?,
      previewText: map['preview_text'] as String?,
    );
  }

  /// An explicit stored title wins; otherwise derive from kind + start time at
  /// read time so the format stays in one place and isn't baked into the DB.
  String get displayTitle {
    if (titleText != null && titleText!.trim().isNotEmpty) {
      return titleText!.trim();
    }
    return '${kind.label} ${_formatStamp(startedAt)}';
  }

  static String _formatStamp(DateTime value) {
    final date =
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final time =
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}
