class ScoreCompetitionOption {
  const ScoreCompetitionOption({
    required this.id,
    required this.providerLeagueId,
    required this.displayName,
    required this.subtitle,
  });

  final String id;
  final String providerLeagueId;
  final String displayName;
  final String subtitle;
}

class ScoreTeamOption {
  const ScoreTeamOption({
    required this.id,
    required this.displayName,
    required this.searchTerm,
    required this.competitionIds,
  });

  final String id;
  final String displayName;
  final String searchTerm;
  final List<String> competitionIds;
}

class ScoreCatalog {
  ScoreCatalog._();

  static const competitions = <ScoreCompetitionOption>[
    ScoreCompetitionOption(
      id: 'premiership-rugby',
      providerLeagueId: '4414',
      displayName: 'Premiership Rugby',
      subtitle: 'English Prem Rugby',
    ),
    ScoreCompetitionOption(
      id: 'six-nations',
      providerLeagueId: '4714',
      displayName: 'Six Nations',
      subtitle: 'Men',
    ),
    ScoreCompetitionOption(
      id: 'six-nations-women',
      providerLeagueId: '5563',
      displayName: 'Women\'s Six Nations',
      subtitle: 'Women',
    ),
    ScoreCompetitionOption(
      id: 'rugby-championship',
      providerLeagueId: '4986',
      displayName: 'Rugby Championship',
      subtitle: 'Southern Hemisphere',
    ),
    ScoreCompetitionOption(
      id: 'rugby-world-cup',
      providerLeagueId: '4574',
      displayName: 'Rugby World Cup',
      subtitle: 'International',
    ),
  ];

  static const teams = <ScoreTeamOption>[
    ScoreTeamOption(
      id: 'harlequins',
      displayName: 'Harlequins',
      searchTerm: 'Harlequins',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'bath-rugby',
      displayName: 'Bath Rugby',
      searchTerm: 'Bath Rugby',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'bristol-bears',
      displayName: 'Bristol Bears',
      searchTerm: 'Bristol Bears',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'exeter-chiefs',
      displayName: 'Exeter Chiefs',
      searchTerm: 'Exeter Chiefs',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'gloucester-rugby',
      displayName: 'Gloucester Rugby',
      searchTerm: 'Gloucester Rugby',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'leicester-tigers',
      displayName: 'Leicester Tigers',
      searchTerm: 'Leicester Tigers',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'northampton-saints',
      displayName: 'Northampton Saints',
      searchTerm: 'Northampton Saints',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'sale-sharks',
      displayName: 'Sale Sharks',
      searchTerm: 'Sale Sharks',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'saracens',
      displayName: 'Saracens',
      searchTerm: 'Saracens',
      competitionIds: ['premiership-rugby'],
    ),
    ScoreTeamOption(
      id: 'england-rugby',
      displayName: 'England Rugby',
      searchTerm: 'England Rugby',
      competitionIds: ['six-nations', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'france-rugby',
      displayName: 'France Rugby',
      searchTerm: 'France Rugby',
      competitionIds: ['six-nations', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'ireland-rugby',
      displayName: 'Ireland Rugby',
      searchTerm: 'Ireland Rugby',
      competitionIds: ['six-nations', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'italy-rugby',
      displayName: 'Italy Rugby',
      searchTerm: 'Italy Rugby',
      competitionIds: ['six-nations', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'scotland-rugby',
      displayName: 'Scotland Rugby',
      searchTerm: 'Scotland Rugby',
      competitionIds: ['six-nations', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'wales-rugby',
      displayName: 'Wales Rugby',
      searchTerm: 'Wales Rugby',
      competitionIds: ['six-nations', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'england-rugby-women',
      displayName: 'England Rugby Women',
      searchTerm: 'England Rugby Women',
      competitionIds: ['six-nations-women'],
    ),
    ScoreTeamOption(
      id: 'france-rugby-women',
      displayName: 'France Rugby Women',
      searchTerm: 'France Rugby Women',
      competitionIds: ['six-nations-women'],
    ),
    ScoreTeamOption(
      id: 'ireland-rugby-women',
      displayName: 'Ireland Rugby Women',
      searchTerm: 'Ireland Rugby Women',
      competitionIds: ['six-nations-women'],
    ),
    ScoreTeamOption(
      id: 'italy-rugby-women',
      displayName: 'Italy Rugby Women',
      searchTerm: 'Italy Rugby Women',
      competitionIds: ['six-nations-women'],
    ),
    ScoreTeamOption(
      id: 'scotland-rugby-women',
      displayName: 'Scotland Rugby Women',
      searchTerm: 'Scotland Rugby Women',
      competitionIds: ['six-nations-women'],
    ),
    ScoreTeamOption(
      id: 'wales-rugby-women',
      displayName: 'Wales Rugby Women',
      searchTerm: 'Wales Rugby Women',
      competitionIds: ['six-nations-women'],
    ),
    ScoreTeamOption(
      id: 'argentina-rugby',
      displayName: 'Argentina Rugby',
      searchTerm: 'Argentina Rugby',
      competitionIds: ['rugby-championship', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'australia-rugby',
      displayName: 'Australia Rugby',
      searchTerm: 'Australia Rugby',
      competitionIds: ['rugby-championship', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'new-zealand-rugby',
      displayName: 'New Zealand Rugby',
      searchTerm: 'New Zealand Rugby',
      competitionIds: ['rugby-championship', 'rugby-world-cup'],
    ),
    ScoreTeamOption(
      id: 'south-africa-rugby',
      displayName: 'South Africa Rugby',
      searchTerm: 'South Africa Rugby',
      competitionIds: ['rugby-championship', 'rugby-world-cup'],
    ),
  ];

  static ScoreCompetitionOption? competitionById(String id) {
    for (final option in competitions) {
      if (option.id == id) {
        return option;
      }
    }
    return null;
  }

  static ScoreTeamOption? teamById(String id) {
    for (final option in teams) {
      if (option.id == id) {
        return option;
      }
    }
    return null;
  }
}
