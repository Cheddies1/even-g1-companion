class CompanionNotification {
  const CompanionNotification({
    required this.key,
    required this.packageName,
    required this.source,
    required this.title,
    required this.text,
    required this.bigText,
    required this.subText,
    required this.message,
    required this.navPrimaryInfo,
    required this.navSecondaryInfo,
    required this.navChipExpandedText,
    required this.navIconPngBase64,
    required this.navIconSource,
    required this.postedAt,
  });

  final String key;
  final String packageName;
  final String source;
  final String title;
  final String text;
  final String bigText;
  final String subText;
  final String message;
  final String navPrimaryInfo;
  final String navSecondaryInfo;
  final String navChipExpandedText;
  final String navIconPngBase64;
  final String navIconSource;
  final DateTime postedAt;

  bool get isGoogleMaps =>
      packageName.contains('com.google.android.apps.maps') ||
      source.toLowerCase().contains('maps');

  factory CompanionNotification.fromMap(Map<dynamic, dynamic> raw) {
    return CompanionNotification(
      key: (raw['key'] as String?) ?? '',
      packageName: (raw['packageName'] as String?) ?? '',
      source: ((raw['source'] as String?) ?? 'Notification').trim(),
      title: ((raw['title'] as String?) ?? '').trim(),
      text: ((raw['text'] as String?) ?? '').trim(),
      bigText: ((raw['bigText'] as String?) ?? '').trim(),
      subText: ((raw['subText'] as String?) ?? '').trim(),
      message:
          ((raw['message'] as String?) ?? 'Open your phone for details').trim(),
      navPrimaryInfo: ((raw['navPrimaryInfo'] as String?) ?? '').trim(),
      navSecondaryInfo: ((raw['navSecondaryInfo'] as String?) ?? '').trim(),
      navChipExpandedText: ((raw['navChipExpandedText'] as String?) ?? '')
          .trim(),
      navIconPngBase64: ((raw['navIconPngBase64'] as String?) ?? '').trim(),
      navIconSource: ((raw['navIconSource'] as String?) ?? '').trim(),
      postedAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['postedAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}
