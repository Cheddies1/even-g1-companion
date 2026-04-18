import 'dart:async';

import 'package:demo_ai_even/models/glance_idle_score_card.dart';
import 'package:demo_ai_even/models/score_catalog.dart';
import 'package:demo_ai_even/models/score_item.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/score_provider.dart';
import 'package:demo_ai_even/services/score_settings_store.dart';
import 'package:demo_ai_even/services/the_sports_db_score_provider.dart';
import 'package:flutter/foundation.dart';

class ScoresService extends ChangeNotifier {
  ScoresService._({ScoreProvider? provider})
      : _provider = provider ?? TheSportsDbScoreProvider();

  static ScoresService? _instance;
  static ScoresService get get => _instance ??= ScoresService._();

  static const _pollInterval = Duration(seconds: 45);

  final ScoreProvider _provider;
  Timer? _pollTimer;
  bool _initialized = false;
  bool _refreshInFlight = false;
  DateTime? _lastSuccessAt;
  List<ScoreItem> _items = const <ScoreItem>[];
  List<GlanceIdleScoreCard> _idleCards = const <GlanceIdleScoreCard>[];

  List<ScoreItem> get items => _items;
  List<GlanceIdleScoreCard> get idleCards => _idleCards;
  DateTime? get lastSuccessAt => _lastSuccessAt;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await ScoreSettingsStore.get.init();
    ScoreSettingsStore.get.addListener(_handleSettingsChanged);
    await _syncPollingForSettings(refreshImmediately: true);
  }

  void _handleSettingsChanged() {
    unawaited(_syncPollingForSettings(refreshImmediately: true));
  }

  Future<void> _syncPollingForSettings({
    required bool refreshImmediately,
  }) async {
    if (!ScoreSettingsStore.get.hasSelections) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _items = const <ScoreItem>[];
      _idleCards = const <GlanceIdleScoreCard>[];
      notifyListeners();
      return;
    }

    _pollTimer ??= Timer.periodic(_pollInterval, (_) {
      unawaited(refreshScores());
    });

    if (refreshImmediately) {
      await refreshScores();
    }
  }

  Future<void> refreshScores() async {
    if (_refreshInFlight) {
      return;
    }

    final competitionOptions = ScoreSettingsStore.get.followedCompetitionIds
        .map(ScoreCatalog.competitionById)
        .whereType<ScoreCompetitionOption>()
        .toList(growable: false);
    final teamOptions = ScoreSettingsStore.get.followedTeamIds
        .map(ScoreCatalog.teamById)
        .whereType<ScoreTeamOption>()
        .toList(growable: false);

    if (competitionOptions.isEmpty && teamOptions.isEmpty) {
      _items = const <ScoreItem>[];
      _idleCards = const <GlanceIdleScoreCard>[];
      notifyListeners();
      return;
    }

    _refreshInFlight = true;
    try {
      final now = DateTime.now();
      final fetched = await _provider.fetchScores(
        competitions: competitionOptions,
        teams: teamOptions,
        now: now,
      );
      _items = _sortItems(fetched, now);
      _idleCards = _buildIdleCards(_items, now);
      _lastSuccessAt = now;
      AppLog.info(
        '${DateTime.now()} Scores: refreshed items=${_items.length} idleCards=${_idleCards.length}',
      );
      notifyListeners();
    } catch (e) {
      AppLog.error('${DateTime.now()} Scores: refresh failed -> $e');
      notifyListeners();
    } finally {
      _refreshInFlight = false;
    }
  }

  List<ScoreItem> _sortItems(List<ScoreItem> items, DateTime now) {
    final copy = List<ScoreItem>.from(items);
    copy.sort((a, b) {
      if (a.isLive != b.isLive) {
        return a.isLive ? -1 : 1;
      }
      final aDistance = a.kickoffUtc.difference(now.toUtc()).abs();
      final bDistance = b.kickoffUtc.difference(now.toUtc()).abs();
      final compareDistance = aDistance.compareTo(bDistance);
      if (compareDistance != 0) {
        return compareDistance;
      }
      return a.competition.compareTo(b.competition);
    });
    return List<ScoreItem>.unmodifiable(copy);
  }

  List<GlanceIdleScoreCard> _buildIdleCards(
    List<ScoreItem> items,
    DateTime now,
  ) {
    final liveItems = items.where((item) => item.isLive).toList(growable: false);
    if (liveItems.isNotEmpty) {
      return liveItems
          .map((item) => GlanceIdleScoreCard(
                id: item.eventId,
                displayText: _buildLiveText(item),
                isLive: true,
              ))
          .toList(growable: false);
    }

    ScoreItem? nextKickoff;
    for (final item in items) {
      if (item.isFinished || item.isLive) {
        continue;
      }
      final untilKickoff = item.kickoffUtc.difference(now.toUtc());
      if (untilKickoff.isNegative || untilKickoff > const Duration(hours: 1)) {
        continue;
      }
      nextKickoff = item;
      break;
    }
    if (nextKickoff == null) {
      return const <GlanceIdleScoreCard>[];
    }

    return <GlanceIdleScoreCard>[
      GlanceIdleScoreCard(
        id: nextKickoff.eventId,
        displayText: _buildUpcomingText(nextKickoff, now),
        isLive: false,
      ),
    ];
  }

  String _buildLiveText(ScoreItem item) {
    final homeScore = item.homeScore?.toString() ?? '-';
    final awayScore = item.awayScore?.toString() ?? '-';
    final competition = _shortCompetition(item.competition);
    final status = item.status.trim().isEmpty ? 'LIVE' : item.status.trim();
    return '$competition\n${item.homeTeam} $homeScore\n${item.awayTeam} $awayScore\n$status';
  }

  String _buildUpcomingText(ScoreItem item, DateTime now) {
    final localKickoff = item.kickoffUtc.toLocal();
    final hours = localKickoff.hour.toString().padLeft(2, '0');
    final minutes = localKickoff.minute.toString().padLeft(2, '0');
    final untilKickoff = item.kickoffUtc.difference(now.toUtc());
    final totalMinutes = untilKickoff.inMinutes.clamp(0, 59);
    final competition = _shortCompetition(item.competition);
    return '$competition\n${item.homeTeam} vs ${item.awayTeam}\nKO $hours:$minutes\nin ${totalMinutes}m';
  }

  String _shortCompetition(String competition) {
    final normalized = competition.trim();
    if (normalized == 'English Prem Rugby') {
      return 'Prem Rugby';
    }
    if (normalized == 'Six Nations Championship') {
      return 'Six Nations';
    }
    return normalized;
  }
}
