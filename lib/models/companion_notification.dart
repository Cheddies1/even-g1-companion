class CompanionNotification {
  const CompanionNotification({
    required this.key,
    required this.packageName,
    required this.source,
    required this.category,
    required this.channelId,
    required this.tag,
    required this.isOngoing,
    required this.isMediaStyle,
    required this.template,
    required this.summaryText,
    required this.title,
    required this.text,
    required this.bigText,
    required this.subText,
    required this.message,
    required this.navPrimaryInfo,
    required this.navSecondaryInfo,
    required this.navChipExpandedText,
    required this.liveScoreHint,
    required this.navIconPngBase64,
    required this.navIconSource,
    required this.postedAt,
    this.connectedAt,
    this.callType = -1,
    this.callIsVideo = false,
  });

  final String key;
  final String packageName;
  final String source;
  final String category;
  final String channelId;
  final String tag;
  final bool isOngoing;
  final bool isMediaStyle;
  final String template;
  final String summaryText;
  final String title;
  final String text;
  final String bigText;
  final String subText;
  final String message;
  final String navPrimaryInfo;
  final String navSecondaryInfo;
  final String navChipExpandedText;
  final String liveScoreHint;
  final String navIconPngBase64;
  final String navIconSource;
  final DateTime postedAt;
  // Set to the call connect time from notification.when; null if not a call or not yet answered.
  final DateTime? connectedAt;
  final int callType;
  final bool callIsVideo;

  bool get isGoogleMaps =>
      packageName.contains('com.google.android.apps.maps') ||
      source.toLowerCase().contains('maps');

  bool get isSamsungAodMirror =>
      const {
        'com.samsung.android.aodservice',
        'com.samsung.android.app.aodservice',
      }.contains(packageName.trim().toLowerCase());

  bool get isYouTubeLike =>
      const {
        'com.google.android.apps.youtube',
        'com.google.android.youtube',
      }.contains(packageName.trim().toLowerCase());

  bool get hasNavigationPayload =>
      navPrimaryInfo.isNotEmpty ||
      navSecondaryInfo.isNotEmpty ||
      navChipExpandedText.isNotEmpty ||
      navIconPngBase64.isNotEmpty ||
      navIconSource.isNotEmpty;

  bool get isCall =>
      isOngoing &&
      (category.toLowerCase() == 'call' || template.contains('CallStyle'));

  factory CompanionNotification.fromMap(Map<dynamic, dynamic> raw) {
    final whenMs = raw['whenMs'] as int?;
    final connectedAt = (whenMs != null && whenMs > 0)
        ? DateTime.fromMillisecondsSinceEpoch(whenMs)
        : null;

    return CompanionNotification(
      key: (raw['key'] as String?) ?? '',
      packageName: (raw['packageName'] as String?) ?? '',
      source: ((raw['source'] as String?) ?? 'Notification').trim(),
      category: ((raw['category'] as String?) ?? '').trim(),
      channelId: ((raw['channelId'] as String?) ?? '').trim(),
      tag: ((raw['tag'] as String?) ?? '').trim(),
      isOngoing: (raw['isOngoing'] as bool?) ?? false,
      isMediaStyle: (raw['isMediaStyle'] as bool?) ?? false,
      template: ((raw['template'] as String?) ?? '').trim(),
      summaryText: ((raw['summaryText'] as String?) ?? '').trim(),
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
      liveScoreHint: ((raw['liveScoreHint'] as String?) ?? '').trim(),
      navIconPngBase64: ((raw['navIconPngBase64'] as String?) ?? '').trim(),
      navIconSource: ((raw['navIconSource'] as String?) ?? '').trim(),
      postedAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['postedAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ),
      connectedAt: connectedAt,
      callType: (raw['callType'] as int?) ?? -1,
      callIsVideo: (raw['callIsVideo'] as bool?) ?? false,
    );
  }
}
