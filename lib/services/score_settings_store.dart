import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScoreSettingsStore extends ChangeNotifier {
  ScoreSettingsStore._();

  static ScoreSettingsStore? _instance;
  static ScoreSettingsStore get get => _instance ??= ScoreSettingsStore._();

  static const _followedCompetitionIdsKey = 'scores.followed_competitions';
  static const _followedTeamIdsKey = 'scores.followed_teams';

  bool _initialized = false;
  bool _initializing = false;
  Set<String> _followedCompetitionIds = const <String>{};
  Set<String> _followedTeamIds = const <String>{};

  bool get isInitialized => _initialized;
  Set<String> get followedCompetitionIds => _followedCompetitionIds;
  Set<String> get followedTeamIds => _followedTeamIds;
  bool get hasSelections =>
      _followedCompetitionIds.isNotEmpty || _followedTeamIds.isNotEmpty;

  Future<void> init() async {
    if (_initialized || _initializing) {
      return;
    }
    _initializing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _followedCompetitionIds = _decodeStringSet(
        prefs.getString(_followedCompetitionIdsKey),
      );
      _followedTeamIds = _decodeStringSet(prefs.getString(_followedTeamIdsKey));
      _initialized = true;
    } finally {
      _initializing = false;
    }
  }

  bool isCompetitionFollowed(String id) {
    return _followedCompetitionIds.contains(id);
  }

  bool isTeamFollowed(String id) {
    return _followedTeamIds.contains(id);
  }

  Future<void> setCompetitionFollowed(String id, bool followed) async {
    await init();
    final next = Set<String>.from(_followedCompetitionIds);
    if (followed) {
      next.add(id);
    } else {
      next.remove(id);
    }
    await _save(
      followedCompetitionIds: next,
      followedTeamIds: _followedTeamIds,
    );
  }

  Future<void> setTeamFollowed(String id, bool followed) async {
    await init();
    final next = Set<String>.from(_followedTeamIds);
    if (followed) {
      next.add(id);
    } else {
      next.remove(id);
    }
    await _save(
      followedCompetitionIds: _followedCompetitionIds,
      followedTeamIds: next,
    );
  }

  Future<void> _save({
    required Set<String> followedCompetitionIds,
    required Set<String> followedTeamIds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _followedCompetitionIdsKey,
      jsonEncode(followedCompetitionIds.toList()..sort()),
    );
    await prefs.setString(
      _followedTeamIdsKey,
      jsonEncode(followedTeamIds.toList()..sort()),
    );
    _followedCompetitionIds =
        Set<String>.unmodifiable(followedCompetitionIds.toSet());
    _followedTeamIds = Set<String>.unmodifiable(followedTeamIds.toSet());
    notifyListeners();
  }

  Set<String> _decodeStringSet(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <String>{};
      }
      return decoded
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet();
    } catch (_) {
      return const <String>{};
    }
  }
}
