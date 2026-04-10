class ChatMessageRecord {
  const ChatMessageRecord({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.createdAt,
    required this.sequence,
  });

  final int id;
  final String sessionId;
  final String role;
  final String text;
  final DateTime createdAt;
  final int sequence;

  factory ChatMessageRecord.fromMap(Map<String, Object?> map) {
    return ChatMessageRecord(
      id: map['id'] as int,
      sessionId: map['session_id'] as String,
      role: map['role'] as String,
      text: map['text'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      sequence: map['sequence_order'] as int,
    );
  }
}
