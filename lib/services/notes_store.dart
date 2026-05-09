import 'package:demo_ai_even/models/note.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

/// Persistent store for QuickNote voice notes, backed by a dedicated sqflite
/// database (`even_companion_notes.db`).
///
/// Kept separate from [ChatHistoryStore]'s `even_companion_chat.db` so that the
/// two concerns don't share a migration surface.
///
/// Sort order convention: [sortOrder] larger = higher in the list (most recent
/// first). Newly inserted notes receive [createdAt] as their initial [sortOrder]
/// value, so chronological ordering is automatic. Fractional midpoint values
/// allow drag-to-reorder without renumbering.
class NotesStore extends ChangeNotifier {
  NotesStore._();

  static NotesStore? _instance;
  static NotesStore get get => _instance ??= NotesStore._();

  Database? _db;
  Future<void>? _initFuture;
  bool _initialized = false;
  List<Note> _notes = const <Note>[];

  /// The current cached list of notes, ordered by [sortOrder] descending
  /// (largest = top). Updated after every mutation.
  List<Note> get notes => _notes;

  bool get isInitialized => _initialized;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    if (_initialized) return;
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    final databasePath = await getDatabasesPath();
    final dbPath = path.join(databasePath, 'even_companion_notes.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE notes (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at      INTEGER NOT NULL,
            transcript_raw  TEXT,
            transcript_clean TEXT,
            status          TEXT NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'done')),
            sort_order      REAL NOT NULL,
            note_uid        BLOB,
            error           TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_notes_sort_order ON notes(sort_order DESC)',
        );
      },
    );
    await _refreshNotes();
    _initialized = true;
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Inserts a new note and returns its autoincrement [id].
  ///
  /// Pass [createdAt] as millisecondsSinceEpoch UTC. If [sortOrder] equals
  /// [createdAt.toDouble()] the note will sort chronologically by default.
  Future<int> insert({
    required int createdAt,
    String? transcriptRaw,
    String? transcriptClean,
    required String status,
    required double sortOrder,
    Uint8List? noteUid,
    String? error,
  }) async {
    await init();
    final id = await _db!.insert(
      'notes',
      {
        'created_at': createdAt,
        'transcript_raw': transcriptRaw,
        'transcript_clean': transcriptClean,
        'status': status,
        'sort_order': sortOrder,
        'note_uid': noteUid,
        'error': error,
      },
    );
    await _refreshNotes();
    return id;
  }

  /// Sets the [status] column for the note identified by [id].
  Future<void> updateStatus({required int id, required String status}) async {
    await init();
    await _db!.update(
      'notes',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _refreshNotes();
  }

  /// Fills in the cleaned transcript text produced by the async tidy step
  /// (task #5 / QuickNoteTidyService).
  Future<void> updateTranscriptClean({
    required int id,
    required String transcriptClean,
  }) async {
    await init();
    await _db!.update(
      'notes',
      {'transcript_clean': transcriptClean},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _refreshNotes();
  }

  /// Records a diagnostic error message when STT or any pipeline step fails.
  Future<void> updateError({required int id, required String error}) async {
    await init();
    await _db!.update(
      'notes',
      {'error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _refreshNotes();
  }

  /// Updates the [sortOrder] for drag-to-reorder. Set to the fractional midpoint
  /// between two neighbours' values; the list will not need renumbering.
  ///
  /// **Caveat for task #7:** repeated midpoint reordering within the same narrow
  /// gap will eventually exhaust REAL precision. The UI layer must implement a
  /// rebalance pass (renumber all rows by even integer steps) when adjacent
  /// values get within ~`Float64.epsilon * scale` of each other.
  Future<void> reorder({required int id, required double sortOrder}) async {
    await init();
    await _db!.update(
      'notes',
      {'sort_order': sortOrder},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _refreshNotes();
  }

  /// Permanently removes the note identified by [id].
  Future<void> delete({required int id}) async {
    await init();
    await _db!.delete('notes', where: 'id = ?', whereArgs: [id]);
    await _refreshNotes();
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns all notes ordered by [sortOrder] descending (largest = top of list).
  ///
  /// When [includeDone] is false, notes with `status = 'done'` are excluded.
  /// The cached [notes] getter gives the same result synchronously after any
  /// mutation has fired [notifyListeners].
  Future<List<Note>> listAll({bool includeDone = true}) async {
    await init();
    final rows = await _db!.query(
      'notes',
      where: includeDone ? null : "status = 'active'",
      orderBy: 'sort_order DESC, created_at DESC, id DESC',
    );
    return rows.map(Note.fromMap).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _refreshNotes() async {
    if (_db == null) {
      _notes = const <Note>[];
      notifyListeners();
      return;
    }
    final rows = await _db!.query(
      'notes',
      orderBy: 'sort_order DESC, created_at DESC, id DESC',
    );
    _notes = rows.map(Note.fromMap).toList(growable: false);
    notifyListeners();
  }
}
