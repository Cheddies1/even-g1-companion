import 'package:demo_ai_even/models/score_catalog.dart';
import 'package:demo_ai_even/models/score_item.dart';

abstract class ScoreProvider {
  Future<List<ScoreItem>> fetchScores({
    required List<ScoreCompetitionOption> competitions,
    required List<ScoreTeamOption> teams,
    required DateTime now,
  });
}
