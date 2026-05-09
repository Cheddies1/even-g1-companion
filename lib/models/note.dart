import 'dart:typed_data';

/// Represents a single captured voice note in the QuickNote pipeline.
///
/// [id] is the autoincrement primary key from the database.
/// [createdAt] is millisecondsSinceEpoch UTC — the moment the note was created.
/// [transcriptRaw] is the unprocessed STT output; null until STT completes.
/// [transcriptClean] is the post-tidy text; null until the tidy step completes.
/// [status] is either 'active' or 'done'.
/// [sortOrder] controls display order (larger = higher in the list, i.e. most recent first).
///   Initial value on insert equals [createdAt] as a double, so natural chronological order
///   is preserved without any extra logic. Fractional values allow reordering between existing
///   notes without renumbering.
/// [noteUid] is the 8-byte UID from the firmware 0x21 payload; null until assigned.
/// [category] is one of 'shopping', 'todo', or 'notes' (default).
/// [error] is set if STT or any pipeline step fails; null on success.
class Note {
  const Note({
    required this.id,
    required this.createdAt,
    this.transcriptRaw,
    this.transcriptClean,
    required this.status,
    required this.sortOrder,
    this.noteUid,
    this.category = 'notes',
    this.error,
  });

  final int id;
  final int createdAt;
  final String? transcriptRaw;
  final String? transcriptClean;
  final String status;
  final double sortOrder;
  final Uint8List? noteUid;
  final String category;
  final String? error;

  DateTime get createdAtUtc => DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true);

  factory Note.fromMap(Map<String, Object?> map) {
    return Note(
      id: map['id'] as int,
      createdAt: map['created_at'] as int,
      transcriptRaw: map['transcript_raw'] as String?,
      transcriptClean: map['transcript_clean'] as String?,
      status: map['status'] as String,
      sortOrder: (map['sort_order'] as num).toDouble(),
      noteUid: map['note_uid'] as Uint8List?,
      category: (map['category'] as String?) ?? 'notes',
      error: map['error'] as String?,
    );
  }

  Note copyWith({
    int? id,
    int? createdAt,
    Object? transcriptRaw = _absent,
    Object? transcriptClean = _absent,
    String? status,
    double? sortOrder,
    Object? noteUid = _absent,
    String? category,
    Object? error = _absent,
  }) {
    return Note(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      transcriptRaw: transcriptRaw == _absent ? this.transcriptRaw : transcriptRaw as String?,
      transcriptClean:
          transcriptClean == _absent ? this.transcriptClean : transcriptClean as String?,
      status: status ?? this.status,
      sortOrder: sortOrder ?? this.sortOrder,
      noteUid: noteUid == _absent ? this.noteUid : noteUid as Uint8List?,
      category: category ?? this.category,
      error: error == _absent ? this.error : error as String?,
    );
  }
}

// Sentinel for distinguishing "not passed" from "explicitly null" in copyWith.
const Object _absent = Object();
