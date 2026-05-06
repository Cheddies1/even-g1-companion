class NotificationPackagePreference {
  const NotificationPackagePreference({
    required this.packageName,
    required this.displayName,
    required this.suppressed,
    required this.lastSeenAt,
    required this.isBuiltInCandidate,
    required this.mediaOverride,
  });

  final String packageName;
  final String displayName;
  final bool suppressed;
  final DateTime? lastSeenAt;
  final bool isBuiltInCandidate;

  /// `true` — force-absorb into Now Playing.
  /// `false` — force-opt-out from Now Playing.
  /// `null` — use auto-detect heuristic.
  final bool? mediaOverride;

  factory NotificationPackagePreference.fromMap(Map<String, Object?> map) {
    final lastSeenRaw = map['last_seen_at'] as int?;
    final mediaRaw = map['media_override'] as int?;
    return NotificationPackagePreference(
      packageName: (map['package_name'] as String? ?? '').trim(),
      displayName: ((map['display_name'] as String?) ?? '').trim(),
      suppressed: ((map['suppressed'] as int?) ?? 0) == 1,
      lastSeenAt: lastSeenRaw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastSeenRaw),
      isBuiltInCandidate: ((map['is_built_in_candidate'] as int?) ?? 0) == 1,
      mediaOverride: mediaRaw == null ? null : mediaRaw == 1,
    );
  }
}
