enum AppMode {
  glance,
  capture,
  navigate,
  chat,
}

extension AppModeX on AppMode {
  String get label {
    switch (this) {
      case AppMode.glance:
        return 'Glance';
      case AppMode.capture:
        return 'Capture';
      case AppMode.navigate:
        return 'Navigate';
      case AppMode.chat:
        return 'Chat';
    }
  }

  String get notificationLabel => 'Even Companion - $label';

  AppMode get nextMode {
    switch (this) {
      case AppMode.glance:
        return AppMode.navigate;
      case AppMode.navigate:
        return AppMode.chat;
      case AppMode.chat:
        return AppMode.capture;
      case AppMode.capture:
        return AppMode.glance;
    }
  }
}

extension AppModeParseX on AppMode {
  static AppMode fromLabel(String label) {
    switch (label.toLowerCase().trim()) {
      case 'glance':
        return AppMode.glance;
      case 'capture':
        return AppMode.capture;
      case 'navigate':
        return AppMode.navigate;
      case 'chat':
        return AppMode.chat;
      default:
        return AppMode.glance;
    }
  }
}
