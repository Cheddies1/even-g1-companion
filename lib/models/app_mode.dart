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
}
