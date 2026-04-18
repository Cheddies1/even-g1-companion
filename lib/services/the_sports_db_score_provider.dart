import 'package:demo_ai_even/models/score_catalog.dart';
import 'package:demo_ai_even/models/score_item.dart';
import 'package:demo_ai_even/services/score_provider.dart';
import 'package:dio/dio.dart';

class TheSportsDbScoreProvider implements ScoreProvider {
  TheSportsDbScoreProvider({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: 'https://www.thesportsdb.com/api/v1/json/123',
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 8),
              ),
            );

  final Dio _dio;
  final Map<String, String> _resolvedTeamIds = <String, String>{};

  @override
  Future<List<ScoreItem>> fetchScores({
    required List<ScoreCompetitionOption> competitions,
    required List<ScoreTeamOption> teams,
    required DateTime now,
  }) async {
    final relevantCompetitions = <ScoreCompetitionOption>{
      ...competitions,
      ...teams
          .expand((team) => team.competitionIds)
          .map(ScoreCatalog.competitionById)
          .whereType<ScoreCompetitionOption>(),
    }.toList(growable: false);

    if (relevantCompetitions.isEmpty) {
      return const <ScoreItem>[];
    }

    final followedTeamIds = await _resolveFollowedTeamIds(teams);
    final followedTeamNames =
        teams.map((team) => team.searchTerm.toLowerCase()).toSet();
    final eventMap = <String, ScoreItem>{};
    final dates = <DateTime>[
      DateTime(now.year, now.month, now.day),
      DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),
    ];

    for (final competition in relevantCompetitions) {
      for (final date in dates) {
        final response = await _dio.get<Map<String, dynamic>>(
          '/eventsday.php',
          queryParameters: {
            'd': _formatDate(date),
            'l': competition.providerLeagueId,
          },
        );
        final events = response.data?['events'];
        if (events is! List) {
          continue;
        }
        for (final raw in events.whereType<Map>()) {
          final item = _parseEvent(raw, competition);
          if (item == null) {
            continue;
          }
          if (!_matchesFollowedScope(
            item,
            competitions: competitions,
            followedTeamIds: followedTeamIds,
            followedTeamNames: followedTeamNames,
            raw: raw,
          )) {
            continue;
          }
          eventMap[item.eventId] = item;
        }
      }
    }

    return eventMap.values.toList(growable: false);
  }

  Future<Set<String>> _resolveFollowedTeamIds(List<ScoreTeamOption> teams) async {
    final resolved = <String>{};
    for (final team in teams) {
      final cached = _resolvedTeamIds[team.id];
      if (cached != null && cached.isNotEmpty) {
        resolved.add(cached);
        continue;
      }
      final teamId = await _searchTeamId(team);
      if (teamId != null && teamId.isNotEmpty) {
        _resolvedTeamIds[team.id] = teamId;
        resolved.add(teamId);
      }
    }
    return resolved;
  }

  Future<String?> _searchTeamId(ScoreTeamOption team) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/searchteams.php',
      queryParameters: {'t': team.searchTerm},
    );
    final teamsRaw = response.data?['teams'];
    if (teamsRaw is! List) {
      return null;
    }

    Map<dynamic, dynamic>? bestMatch;
    final normalizedSearch = team.searchTerm.toLowerCase();
    for (final raw in teamsRaw.whereType<Map>()) {
      final sport = (raw['strSport'] as String? ?? '').trim().toLowerCase();
      if (sport != 'rugby') {
        continue;
      }
      final name = (raw['strTeam'] as String? ?? '').trim().toLowerCase();
      if (name == normalizedSearch) {
        bestMatch = raw;
        break;
      }
      bestMatch ??= raw;
    }
    return (bestMatch?['idTeam'] as String?)?.trim();
  }

  bool _matchesFollowedScope(
    ScoreItem item, {
    required List<ScoreCompetitionOption> competitions,
    required Set<String> followedTeamIds,
    required Set<String> followedTeamNames,
    required Map<dynamic, dynamic> raw,
  }) {
    final followedCompetitionIds = competitions.map((item) => item.id).toSet();
    if (followedCompetitionIds.contains(item.competitionId)) {
      return true;
    }

    final homeId = (raw['idHomeTeam'] as String? ?? '').trim();
    final awayId = (raw['idAwayTeam'] as String? ?? '').trim();
    if (followedTeamIds.contains(homeId) || followedTeamIds.contains(awayId)) {
      return true;
    }

    final homeName = item.homeTeam.toLowerCase();
    final awayName = item.awayTeam.toLowerCase();
    return followedTeamNames.contains(homeName) ||
        followedTeamNames.contains(awayName);
  }

  ScoreItem? _parseEvent(
    Map<dynamic, dynamic> raw,
    ScoreCompetitionOption competition,
  ) {
    final eventId = (raw['idEvent'] as String? ?? '').trim();
    final homeTeam = (raw['strHomeTeam'] as String? ?? '').trim();
    final awayTeam = (raw['strAwayTeam'] as String? ?? '').trim();
    final kickoffUtc = _parseKickoffUtc(raw);
    if (eventId.isEmpty ||
        homeTeam.isEmpty ||
        awayTeam.isEmpty ||
        kickoffUtc == null) {
      return null;
    }

    final status = (raw['strStatus'] as String? ?? '').trim();
    final leagueName = (raw['strLeague'] as String? ?? '').trim();
    return ScoreItem(
      eventId: eventId,
      competitionId: competition.id,
      competition:
          leagueName.isNotEmpty ? leagueName : competition.displayName,
      homeTeam: homeTeam,
      awayTeam: awayTeam,
      homeScore: _parseNullableInt(raw['intHomeScore']),
      awayScore: _parseNullableInt(raw['intAwayScore']),
      status: status,
      kickoffUtc: kickoffUtc,
      isLive: _isLiveStatus(status),
      isFinished: _isFinishedStatus(status),
    );
  }

  DateTime? _parseKickoffUtc(Map<dynamic, dynamic> raw) {
    final timestamp = (raw['strTimestamp'] as String? ?? '').trim();
    if (timestamp.isNotEmpty) {
      return _parseUtcTimestamp(timestamp);
    }

    final date = (raw['dateEvent'] as String? ?? '').trim();
    final time = (raw['strTime'] as String? ?? '').trim();
    if (date.isEmpty) {
      return null;
    }

    final normalizedTime = time.isEmpty ? '00:00:00' : time;
    return _parseUtcTimestamp('${date}T$normalizedTime');
  }

  DateTime? _parseUtcTimestamp(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    if (!value.endsWith('Z') &&
        !value.contains('+') &&
        (value.length <= 10 || !value.substring(10).contains('-'))) {
      value = '${value}Z';
    }
    return DateTime.tryParse(value)?.toUtc();
  }

  int? _parseNullableInt(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) {
      return null;
    }
    return int.tryParse(value);
  }

  bool _isLiveStatus(String status) {
    final normalized = status.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    const liveStatuses = <String>{
      'live',
      'in play',
      '1h',
      '2h',
      'ht',
      'et',
      'bt',
      'p',
    };
    if (liveStatuses.contains(normalized)) {
      return true;
    }
    return RegExp(r"^\d{1,3}(\+?\d+)?'$").hasMatch(status.trim());
  }

  bool _isFinishedStatus(String status) {
    final normalized = status.trim().toLowerCase();
    return normalized == 'ft' ||
        normalized == 'aft' ||
        normalized == 'finished' ||
        normalized == 'ended';
  }

  String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
