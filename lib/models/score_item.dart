class ScoreItem {
  const ScoreItem({
    required this.eventId,
    required this.competitionId,
    required this.competition,
    required this.homeTeam,
    required this.awayTeam,
    required this.homeScore,
    required this.awayScore,
    required this.status,
    required this.kickoffUtc,
    required this.isLive,
    required this.isFinished,
  });

  final String eventId;
  final String competitionId;
  final String competition;
  final String homeTeam;
  final String awayTeam;
  final int? homeScore;
  final int? awayScore;
  final String status;
  final DateTime kickoffUtc;
  final bool isLive;
  final bool isFinished;
}
