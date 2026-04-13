class NotificationPackagePreference {
  const NotificationPackagePreference({
    required this.packageName,
    required this.displayName,
    required this.suppressed,
    required this.lastSeenAt,
    required this.isBuiltInCandidate,
  });

  final String packageName;
  final String displayName;
  final bool suppressed;
  final DateTime? lastSeenAt;
  final bool isBuiltInCandidate;

  factory NotificationPackagePreference.fromMap(Map<String, Object?> map) {
    final lastSeenRaw = map['last_seen_at'] as int?;
    return NotificationPackagePreference(
      packageName: (map['package_name'] as String? ?? '').trim(),
      displayName: ((map['display_name'] as String?) ?? '').trim(),
      suppressed: ((map['suppressed'] as int?) ?? 0) == 1,
      lastSeenAt: lastSeenRaw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastSeenRaw),
      isBuiltInCandidate: ((map['is_built_in_candidate'] as int?) ?? 0) == 1,
    );
  }
}
