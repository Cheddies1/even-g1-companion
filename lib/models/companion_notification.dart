class CompanionNotification {
  const CompanionNotification({
    required this.key,
    required this.packageName,
    required this.source,
    required this.message,
    required this.postedAt,
  });

  final String key;
  final String packageName;
  final String source;
  final String message;
  final DateTime postedAt;

  bool get isGoogleMaps =>
      packageName.contains('com.google.android.apps.maps') ||
      source.toLowerCase().contains('maps');

  factory CompanionNotification.fromMap(Map<dynamic, dynamic> raw) {
    return CompanionNotification(
      key: (raw['key'] as String?) ?? '',
      packageName: (raw['packageName'] as String?) ?? '',
      source: ((raw['source'] as String?) ?? 'Notification').trim(),
      message:
          ((raw['message'] as String?) ?? 'Open your phone for details').trim(),
      postedAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['postedAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}
