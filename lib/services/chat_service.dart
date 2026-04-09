class ChatService {
  static ChatService? _instance;
  static ChatService get get => _instance ??= ChatService._();

  ChatService._();

  String? _sessionId;

  bool get hasActiveSession => _sessionId != null;

  void startSession() {
    _sessionId ??= DateTime.now().millisecondsSinceEpoch.toString();
  }

  void resetSession() {
    _sessionId = null;
  }

  String get summary =>
      'Chat mode is scaffolded only in this phase. Future work will plug Android speech recognition into a session-based ChatGPT flow tied to your account.';
}
