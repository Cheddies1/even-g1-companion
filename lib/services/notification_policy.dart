import 'package:demo_ai_even/models/companion_notification.dart';

enum NotificationDisposition {
  blocked,
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
    'com.google.android.apps.maps',
  };

  static NotificationDisposition classify(CompanionNotification notification) {
    final packageName = notification.packageName.trim().toLowerCase();
    if (_blockedPackages.contains(packageName)) {
      return NotificationDisposition.blocked;
    }
    if (_protectedPackages.contains(packageName)) {
      return NotificationDisposition.protected;
    }
    return NotificationDisposition.normal;
  }

  static bool shouldBlockFromGlance(CompanionNotification notification) {
    return classify(notification) == NotificationDisposition.blocked;
  }

  static bool canDismissFromGlance(CompanionNotification notification) {
    return classify(notification) == NotificationDisposition.normal;
  }
}
