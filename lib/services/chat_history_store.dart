import 'package:even_companion/models/chat_message_record.dart';
import 'package:even_companion/models/chat_session_record.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class ChatHistoryStore extends ChangeNotifier {
  ChatHistoryStore._();

  static ChatHistoryStore? _instance;
  static ChatHistoryStore get get => _instance ??= ChatHistoryStore._();

  Database? _db;
  bool _initializing = false;
  bool _initialized = false;
  List<ChatSessionRecord> _recentSessions = const <ChatSessionRecord>[];

  List<ChatSessionRecord> get recentSessions => _recentSessions;
  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized || _initializing) {
      return;
    }
    _initializing = true;
    try {
      final databasePath = await getDatabasesPath();
      final dbPath = path.join(databasePath, 'even_companion_chat.db');
      _db = await openDatabase(
        dbPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE chat_sessions (
              id TEXT PRIMARY KEY,
              started_at INTEGER NOT NULL,
              ended_at INTEGER,
              title_text TEXT,
              preview_text TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE chat_messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              role TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              sequence_order INTEGER NOT NULL,
              FOREIGN KEY(session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_chat_messages_session_order ON chat_messages(session_id, sequence_order)',
          );
        },
      );
      await _refreshRecentSessions();
      _initialized = true;
    } finally {
      _initializing = false;
    }
  }

  Future<void> startSession({
    required String id,
    required DateTime startedAt,
    String? titleText,
  }) async {
    await init();
    await _db!.insert(
      'chat_sessions',
      {
        'id': id,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': null,
        'title_text': titleText ?? _defaultTitle(startedAt),
        'preview_text': null,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _refreshRecentSessions();
  }

  Future<void> appendMessage({
    required String sessionId,
    required String role,
    required String text,
    required int sequence,
    required DateTime createdAt,
  }) async {
    await init();
    await _db!.insert(
      'chat_messages',
      {
        'session_id': sessionId,
        'role': role,
        'text': text,
        'created_at': createdAt.millisecondsSinceEpoch,
        'sequence_order': sequence,
      },
    );

    if (role == 'user') {
      final currentSession = await _db!.query(
        'chat_sessions',
        columns: ['preview_text'],
        where: 'id = ?',
        whereArgs: [sessionId],
        limit: 1,
      );
      final existingPreview =
          currentSession.isEmpty ? null : currentSession.first['preview_text'] as String?;
      if (existingPreview == null || existingPreview.trim().isEmpty) {
        await _db!.update(
          'chat_sessions',
          {'preview_text': _preview(text)},
          where: 'id = ?',
          whereArgs: [sessionId],
        );
      }
    }

    await _refreshRecentSessions();
  }

  Future<void> endSession({
    required String sessionId,
    required DateTime endedAt,
  }) async {
    await init();
    await _db!.update(
      'chat_sessions',
      {'ended_at': endedAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    await _refreshRecentSessions();
  }

  Future<void> deleteSession(String sessionId) async {
    await init();
    await _db!.delete(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    await _db!.delete(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    await _refreshRecentSessions();
  }

  Future<List<ChatMessageRecord>> loadTranscript(String sessionId) async {
    await init();
    final rows = await _db!.query(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'sequence_order ASC',
    );
    return rows.map(ChatMessageRecord.fromMap).toList(growable: false);
  }

  Future<void> _refreshRecentSessions() async {
    if (_db == null) {
      _recentSessions = const <ChatSessionRecord>[];
      notifyListeners();
      return;
    }
    final rows = await _db!.query(
      'chat_sessions',
      orderBy: 'started_at DESC',
      limit: 12,
    );
    _recentSessions = rows.map(ChatSessionRecord.fromMap).toList(growable: false);
    notifyListeners();
  }

  String _defaultTitle(DateTime value) {
    final date =
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final time =
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return 'Chat $date $time';
  }

  String _preview(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 96) {
      return cleaned;
    }
    return '${cleaned.substring(0, 95)}…';
  }
}
