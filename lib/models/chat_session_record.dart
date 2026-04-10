class ChatSessionRecord {
  const ChatSessionRecord({
    required this.id,
    required this.startedAt,
    this.endedAt,
    this.titleText,
    this.previewText,
  });

  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? titleText;
  final String? previewText;

  factory ChatSessionRecord.fromMap(Map<String, Object?> map) {
    return ChatSessionRecord(
      id: map['id'] as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(map['started_at'] as int),
      endedAt: map['ended_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['ended_at'] as int),
      titleText: map['title_text'] as String?,
      previewText: map['preview_text'] as String?,
    );
  }

  String get displayTitle {
    if (titleText != null && titleText!.trim().isNotEmpty) {
      return titleText!.trim();
    }
    return _formatTitle(startedAt);
  }

  static String _formatTitle(DateTime value) {
    final date =
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final time =
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return 'Chat $date $time';
  }
}
