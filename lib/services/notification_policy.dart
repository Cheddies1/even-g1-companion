import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/notification_settings_store.dart';

enum NotificationDisposition {
  blocked,
  suppressed,
  protected,
  normal,
}

class NotificationPolicy {
  NotificationPolicy._();

  static const Set<String> _blockedPackages = {
    'com.example.demo_ai_even',
  };

  static const Set<String> _protectedPackages = {
    'com.google.android.apps.youtube',
    'com.google.android.youtube',
    'com.google.android.apps.maps',
  };

  static NotificationDisposition classify(CompanionNotification notification) {
    final packageName = notification.packageName.trim().toLowerCase();
    if (_blockedPackages.contains(packageName)) {
      return NotificationDisposition.blocked;
    }
    if (_isProtectedPinnedLiveScoreNotification(notification)) {
      return NotificationDisposition.protected;
    }
    if (notification.isSamsungAodMirror) {
      return NotificationDisposition.suppressed;
    }
    if (NotificationSettingsStore.get.isPackageSuppressed(packageName)) {
      return NotificationDisposition.suppressed;
    }
    if (_shouldSuppressOpenOnPhone(notification)) {
      return NotificationDisposition.suppressed;
    }
    if (_isProtectedMediaNotification(notification)) {
      return NotificationDisposition.protected;
    }
    if (notification.isOngoing) {
      return NotificationDisposition.suppressed;
    }
    if (_protectedPackages.contains(packageName)) {
      return NotificationDisposition.protected;
    }
    return NotificationDisposition.normal;
  }

  static bool shouldBlockFromGlance(CompanionNotification notification) {
    final disposition = classify(notification);
    return disposition == NotificationDisposition.blocked ||
        disposition == NotificationDisposition.suppressed;
  }

  static bool canDismissFromGlance(CompanionNotification notification) {
    return classify(notification) == NotificationDisposition.normal;
  }

  static bool isDismissibleInGlance(CompanionNotification notification) {
    return classify(notification) == NotificationDisposition.normal;
  }

  static bool _shouldSuppressOpenOnPhone(CompanionNotification notification) {
    final combined = _normalize(
      [
        notification.title,
        notification.text,
        notification.bigText,
        notification.message,
      ].join(' '),
    );
    if (combined.isEmpty) {
      return false;
    }
    if (combined == 'open on phone' ||
        combined == 'open your phone for details' ||
        combined.endsWith(' open on phone') ||
        combined.contains(' tap to open on phone')) {
      return true;
    }
    final informativeFields = <String>[
      notification.navPrimaryInfo,
      notification.navSecondaryInfo,
      notification.subText,
    ].map(_normalize).where((value) => value.isNotEmpty).toList();
    return informativeFields.isEmpty &&
        (combined.contains('open on phone') ||
            combined.contains('open your phone for details'));
  }

  static bool _isProtectedPinnedLiveScoreNotification(
    CompanionNotification notification,
  ) {
    if (_isSamsungAodSportsWrapper(notification)) {
      return true;
    }
    final combined = _normalize(
      [
        notification.title,
        notification.text,
        notification.bigText,
        notification.subText,
        notification.summaryText,
        notification.message,
      ].join(' '),
    );
    final hasScorePattern = RegExp(r'\b\d+\s*[-:]\s*\d+\b').hasMatch(combined);
    final hasSportsSignal = RegExp(
      r'\b(live|final|half|quarter|q[1-4]|inning|innings|period|ft|ht)\b',
    ).hasMatch(combined);
    final hasCompetitionSignal = RegExp(
      r'\b(six nations|premier league|wsl|champions league|fa cup|world cup|league)\b',
    ).hasMatch(combined);
    if (!(hasScorePattern && (hasSportsSignal || hasCompetitionSignal))) {
      return false;
    }
    if (notification.isOngoing) {
      return true;
    }
    if (notification.isSamsungAodMirror) {
      return true;
    }
    return false;
  }

  static bool _isSamsungAodSportsWrapper(CompanionNotification notification) {
    if (!notification.isSamsungAodMirror) {
      return false;
    }
    final channelId = _normalize(notification.channelId);
    final liveScoreHint = _normalize(notification.liveScoreHint);
    return channelId.contains('google_sports_nowbar_ongoing_channel') ||
        liveScoreHint.contains('ambientdata:sportsscore:');
  }

  static bool _isProtectedMediaNotification(CompanionNotification notification) {
    final category = _normalize(notification.category);
    final channelId = _normalize(notification.channelId);
    if (notification.isYouTubeLike) {
      return true;
    }
    if (!notification.isMediaStyle) {
      return false;
    }
    return category == 'transport' ||
        channelId.contains('media') ||
        channelId.contains('playback') ||
        channelId.contains('transport');
  }

  static String _normalize(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  }
}
