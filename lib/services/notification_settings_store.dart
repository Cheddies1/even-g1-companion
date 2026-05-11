import 'package:even_companion/models/companion_notification.dart';
import 'package:even_companion/models/notification_package_preference.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class NotificationSettingsStore extends ChangeNotifier {
  NotificationSettingsStore._();

  static NotificationSettingsStore? _instance;
  static NotificationSettingsStore get get =>
      _instance ??= NotificationSettingsStore._();

  static const Map<String, String> _defaultSuppressedPackages = {
    'com.samsung.android.oneconnect': 'SmartThings',
    'com.samsung.android.smartthings': 'SmartThings',
    'com.sec.android.app.camera': 'Samsung Camera',
  };

  Database? _db;
  bool _initialized = false;
  bool _initializing = false;
  List<NotificationPackagePreference> _recentPackages =
      const <NotificationPackagePreference>[];
  Set<String> _suppressedPackages = const <String>{};
  Set<String> _mediaPackages = const <String>{};
  Set<String> _mediaOptOutPackages = const <String>{};

  bool get isInitialized => _initialized;
  List<NotificationPackagePreference> get recentPackages => _recentPackages;

  bool isPackageSuppressed(String packageName) {
    return _suppressedPackages.contains(packageName.trim().toLowerCase());
  }

  /// Returns `true` if the package is force-marked as media, `false` if
  /// force-opted out, or `null` if the auto-detect heuristic should decide.
  bool? isPackageMedia(String packageName) {
    final normalized = packageName.trim().toLowerCase();
    if (_mediaPackages.contains(normalized)) {
      return true;
    }
    if (_mediaOptOutPackages.contains(normalized)) {
      return false;
    }
    return null;
  }

  Future<void> init() async {
    if (_initialized || _initializing) {
      return;
    }
    _initializing = true;
    try {
      final databasePath = await getDatabasesPath();
      final dbPath = path.join(databasePath, 'even_companion_notifications.db');
      _db = await openDatabase(
        dbPath,
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE notification_package_preferences (
              package_name TEXT PRIMARY KEY,
              display_name TEXT NOT NULL,
              suppressed INTEGER NOT NULL DEFAULT 0,
              last_seen_at INTEGER,
              is_built_in_candidate INTEGER NOT NULL DEFAULT 0,
              media_override INTEGER
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE notification_package_preferences ADD COLUMN media_override INTEGER',
            );
          }
        },
      );
      await _seedBuiltInPackages();
      await _refresh();
      _initialized = true;
    } finally {
      _initializing = false;
    }
  }

  Future<void> noteNotification(CompanionNotification notification) async {
    await init();
    final packageName = notification.packageName.trim().toLowerCase();
    if (packageName.isEmpty) {
      return;
    }
    final existing = await _db!.query(
      'notification_package_preferences',
      where: 'package_name = ?',
      whereArgs: [packageName],
      limit: 1,
    );
    final displayName = notification.source.trim().isNotEmpty
        ? notification.source.trim()
        : packageName;
    if (existing.isEmpty) {
      await _db!.insert(
        'notification_package_preferences',
        {
          'package_name': packageName,
          'display_name': displayName,
          'suppressed': 0,
          'last_seen_at': notification.postedAt.millisecondsSinceEpoch,
          'is_built_in_candidate':
              _defaultSuppressedPackages.containsKey(packageName) ? 1 : 0,
          'media_override': null,
        },
      );
    } else {
      await _db!.update(
        'notification_package_preferences',
        {
          'display_name': displayName,
          'last_seen_at': notification.postedAt.millisecondsSinceEpoch,
        },
        where: 'package_name = ?',
        whereArgs: [packageName],
      );
    }
    await _refresh();
  }

  Future<void> setPackageSuppressed(
    String packageName,
    bool suppressed,
  ) async {
    await init();
    final normalized = packageName.trim().toLowerCase();
    if (normalized.isEmpty) {
      return;
    }
    final existing = await _db!.query(
      'notification_package_preferences',
      where: 'package_name = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (existing.isEmpty) {
      await _db!.insert(
        'notification_package_preferences',
        {
          'package_name': normalized,
          'display_name': _defaultSuppressedPackages[normalized] ?? normalized,
          'suppressed': suppressed ? 1 : 0,
          'last_seen_at': null,
          'is_built_in_candidate':
              _defaultSuppressedPackages.containsKey(normalized) ? 1 : 0,
        },
      );
    } else {
      await _db!.update(
        'notification_package_preferences',
        {'suppressed': suppressed ? 1 : 0},
        where: 'package_name = ?',
        whereArgs: [normalized],
      );
    }
    await _refresh();
  }

  Future<void> setPackageMedia(String packageName, bool? value) async {
    await init();
    final normalized = packageName.trim().toLowerCase();
    if (normalized.isEmpty) {
      return;
    }
    final existing = await _db!.query(
      'notification_package_preferences',
      where: 'package_name = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    final mediaOverrideValue = value == null ? null : (value ? 1 : 0);
    if (existing.isEmpty) {
      await _db!.insert(
        'notification_package_preferences',
        {
          'package_name': normalized,
          'display_name': _defaultSuppressedPackages[normalized] ?? normalized,
          'suppressed': 0,
          'last_seen_at': null,
          'is_built_in_candidate':
              _defaultSuppressedPackages.containsKey(normalized) ? 1 : 0,
          'media_override': mediaOverrideValue,
        },
      );
    } else {
      await _db!.update(
        'notification_package_preferences',
        {'media_override': mediaOverrideValue},
        where: 'package_name = ?',
        whereArgs: [normalized],
      );
    }
    await _refresh();
    notifyListeners();
  }

  Future<void> _seedBuiltInPackages() async {
    for (final entry in _defaultSuppressedPackages.entries) {
      await _db!.insert(
        'notification_package_preferences',
        {
          'package_name': entry.key,
          'display_name': entry.value,
          'suppressed': 1,
          'last_seen_at': null,
          'is_built_in_candidate': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> _refresh() async {
    if (_db == null) {
      return;
    }
    final rows = await _db!.query(
      'notification_package_preferences',
      orderBy:
          'CASE WHEN last_seen_at IS NULL THEN 1 ELSE 0 END, last_seen_at DESC, display_name ASC',
      limit: 20,
    );
    _recentPackages = rows
        .map(NotificationPackagePreference.fromMap)
        .toList(growable: false);
    _suppressedPackages = rows
        .where((row) => ((row['suppressed'] as int?) ?? 0) == 1)
        .map((row) => ((row['package_name'] as String?) ?? '').trim().toLowerCase())
        .where((packageName) => packageName.isNotEmpty)
        .toSet();
    _mediaPackages = rows
        .where((row) => (row['media_override'] as int?) == 1)
        .map((row) => ((row['package_name'] as String?) ?? '').trim().toLowerCase())
        .where((packageName) => packageName.isNotEmpty)
        .toSet();
    _mediaOptOutPackages = rows
        .where((row) => (row['media_override'] as int?) == 0)
        .map((row) => ((row['package_name'] as String?) ?? '').trim().toLowerCase())
        .where((packageName) => packageName.isNotEmpty)
        .toSet();
    notifyListeners();
  }
}
