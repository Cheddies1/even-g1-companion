import 'dart:async';
import 'dart:io';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/chat_message.dart';
import 'package:even_companion/models/chat_session_record.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/chat_backend.dart';
import 'package:even_companion/services/chat_history_store.dart';
import 'package:even_companion/services/openai_chat_backend.dart';
import 'package:even_companion/services/openai_transcription_service.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';

class GlanceAssistantService {
  GlanceAssistantService._({
    ChatBackend? backend,
    OpenAiTranscriptionService? transcriptionService,
  })  : _backend = backend ?? OpenAiChatBackend(),
        _transcriptionService =
            transcriptionService ?? OpenAiTranscriptionService();

  static const _sessionExpiry = Duration(minutes: 4);
  static const _responseVisibleDuration = Duration(seconds: 6);
  static const _previewDelay = Duration(milliseconds: 900);
  static const _maxGlassesResponseChars = 900;

  static GlanceAssistantService? _instance;
  static GlanceAssistantService get get => _instance ??= GlanceAssistantService._();

  final ChatBackend _backend;
  final OpenAiTranscriptionService _transcriptionService;

  final List<ChatMessage> _messages = <ChatMessage>[];
  // History session spanning the current ephemeral context window. Created
  // lazily on the first persisted user turn, ended when the window clears.
  String? _historySessionId;
  int _historySequence = 0;
  bool _isListening = false;
  bool _isThinking = false;
  bool _isDisplayVisible = false;
  int _requestVersion = 0;
  DateTime? _lastActivityAt;
  Timer? _sessionExpiryTimer;
  Timer? _displayClearTimer;

  bool get isListening => _isListening;
  bool get isThinking => _isThinking;
  bool get isDisplayVisible => _isDisplayVisible;
  bool get hasEphemeralContext => _messages.isNotEmpty;

  Future<String> startListening() async {
    if (_isThinking) {
      AppLog.debug(
        '${DateTime.now()} start ignored -> still thinking',
        tag: 'GlanceAssistant',
      );
      await _showText('Thinking...');
      return 'Assistant still thinking';
    }
    if (_isListening) {
      AppLog.debug(
        '${DateTime.now()} start ignored -> already listening',
        tag: 'GlanceAssistant',
      );
      return 'Assistant already listening';
    }

    _expireSessionIfStale();
    _displayClearTimer?.cancel();

    AppLog.debug(
      '${DateTime.now()} recorder start requested',
      tag: 'GlanceAssistant',
    );
    final started = await BleManager.invokeMethod<bool>('startGlassesCapture');
    if (started != true) {
      AppLog.error(
        '${DateTime.now()} recorder start failed',
        tag: 'GlanceAssistant',
      );
      await _showText('Mic start failed');
      _scheduleClear();
      return 'Assistant listen failed';
    }

    AppLog.debug(
      '${DateTime.now()} micOn requested',
      tag: 'GlanceAssistant',
    );
    final (_, micStarted) = await Proto.micOn(lr: 'R');
    if (!micStarted) {
      AppLog.error(
        '${DateTime.now()} micOn failed',
        tag: 'GlanceAssistant',
      );
      await BleManager.invokeMethod('cancelGlassesCapture');
      await _showText('Mic start failed');
      _scheduleClear();
      return 'Assistant mic failed';
    }

    _isListening = true;
    _lastActivityAt = DateTime.now();
    AppLog.info(
      '${DateTime.now()} listening started',
      tag: 'GlanceAssistant',
    );
    return 'Listening for glance assistant';
  }

  Future<String> stopListeningAndSubmit() async {
    if (!_isListening) {
      AppLog.debug(
        '${DateTime.now()} stop ignored -> isListening=$_isListening isThinking=$_isThinking',
        tag: 'GlanceAssistant',
      );
      return _isThinking ? 'Assistant still thinking' : 'Assistant not listening';
    }

    final requestVersion = ++_requestVersion;
    _isListening = false;
    _isThinking = true;

    try {
      AppLog.debug(
        '${DateTime.now()} recorder stopToTemp requested',
        tag: 'GlanceAssistant',
      );
      final raw = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
        'stopGlassesCaptureToTemp',
      );
      final filePath = (raw?['localPath'] as String?) ?? '';
      AppLog.debug(
        '${DateTime.now()} stopToTemp result -> success=${raw?['success']} localPath=$filePath pcmBytes=${raw?['pcmBytes']} durationMs=${raw?['durationMs']}',
        tag: 'GlanceAssistant',
      );
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();

      if (filePath.isEmpty) {
        throw const GlanceAssistantFlowException('No recorded audio to transcribe');
      }

      final transcript = await _transcriptionService.transcribe(filePath);
      await _deleteTempFile(filePath);

      if (!_isCurrentRequest(requestVersion)) {
        return 'Glance assistant request changed';
      }

      if (transcript.isEmpty) {
        await _showText("Didn't catch that");
        _scheduleClear();
        return 'No speech detected';
      }

      final cleanedTranscript = _cleanText(transcript);
      _messages.add(
        ChatMessage(
          role: ChatRole.user,
          content: cleanedTranscript,
        ),
      );
      await _ensureHistorySession();
      await _persistGlanceMessage(role: 'user', text: cleanedTranscript);

      await _showText('You said:\n${_shortPreview(cleanedTranscript)}');
      await Future<void>.delayed(_previewDelay);

      if (!_isCurrentRequest(requestVersion)) {
        return 'Glance assistant request changed';
      }

      await _showText('Thinking...');
      final answer =
          await _backend.send(messages: List<ChatMessage>.from(_messages));

      if (!_isCurrentRequest(requestVersion)) {
        return 'Glance assistant request changed';
      }

      final cleanedAnswer = _capForGlasses(_cleanText(answer));
      _messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          content: cleanedAnswer,
        ),
      );
      await _persistGlanceMessage(role: 'assistant', text: cleanedAnswer);
      _lastActivityAt = DateTime.now();
      _restartSessionExpiryTimer();

      await _showText(cleanedAnswer);
      _scheduleClear();
      return 'Assistant replied';
    } on ChatTranscriptionException catch (e) {
      await _showText(_transcriptionErrorMessage(e));
      _scheduleClear();
      return 'Speech error';
    } on ChatBackendException catch (e) {
      await _showText(_backendErrorMessage(e));
      _scheduleClear();
      return 'Assistant backend error';
    } on GlanceAssistantFlowException catch (e) {
      await _showText(_flowErrorMessage(e));
      _scheduleClear();
      return e.message;
    } catch (_) {
      await _showText('Something went wrong');
      _scheduleClear();
      return 'Assistant failed';
    } finally {
      _isThinking = false;
    }
  }

  Future<void> close() async {
    _requestVersion++;
    _isListening = false;
    _isThinking = false;
    _displayClearTimer?.cancel();
    _displayClearTimer = null;
    _isDisplayVisible = false;
    AppLog.info(
      '${DateTime.now()} close -> cancel capture and clear',
      tag: 'GlanceAssistant',
    );
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.clearDisplay();
  }

  Future<void> reset() async {
    await close();
    _clearEphemeralContext();
    _lastActivityAt = null;
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = null;
  }

  /// Called when the BLE transport is lost (full or single-leg disconnect).
  /// Clears runtime state so that stale _isListening/_isThinking flags cannot
  /// block the _scheduleClear() auto-clear once the transport recovers.
  /// Must not perform any BLE IO — transport is gone.
  void handleTransportLost() {
    _isListening = false;
    _isThinking = false;
    _isDisplayVisible = false;
    _displayClearTimer?.cancel();
    _displayClearTimer = null;
    // Bump the request version so any in-flight transcription/completion
    // callback finds _isCurrentRequest() == false and bails cleanly.
    _requestVersion++;
    AppLog.info(
      '${DateTime.now()} transport lost — flags cleared',
      tag: 'GlanceAssistant',
    );
  }

  Future<void> _showText(String text) async {
    _displayClearTimer?.cancel();
    _isDisplayVisible = true;
    await TextService.get.startSendText(text);
  }

  void _scheduleClear() {
    _displayClearTimer?.cancel();
    AppLog.info(
      '${DateTime.now()} assistant clear timer STARTED (${_responseVisibleDuration.inSeconds}s)',
      tag: 'GlanceClear',
    );
    _displayClearTimer = Timer(_responseVisibleDuration, () async {
      if (_isListening || _isThinking) {
        AppLog.info(
          '${DateTime.now()} assistant clear timer FIRED but skipped — listening=$_isListening thinking=$_isThinking',
          tag: 'GlanceClear',
        );
        return;
      }
      AppLog.info(
        '${DateTime.now()} assistant clear timer FIRED — clearing display',
        tag: 'GlanceClear',
      );
      _isDisplayVisible = false;
      await TextService.get.stopTextSendingByOS();
      await Proto.clearDisplay();
    });
  }

  void _expireSessionIfStale() {
    final lastActivityAt = _lastActivityAt;
    if (lastActivityAt == null) {
      return;
    }
    if (DateTime.now().difference(lastActivityAt) < _sessionExpiry) {
      return;
    }
    _clearEphemeralContext();
    _lastActivityAt = null;
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = null;
  }

  void _restartSessionExpiryTimer() {
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = Timer(_sessionExpiry, () {
      _clearEphemeralContext();
      _lastActivityAt = null;
    });
  }

  /// Lazily open a history session for the current ephemeral window, tagged as
  /// a Quick Ask so the chat log can distinguish it from full Chat-mode
  /// conversations.
  Future<void> _ensureHistorySession() async {
    if (_historySessionId != null) {
      return;
    }
    final id = 'qa-${DateTime.now().millisecondsSinceEpoch}';
    _historySessionId = id;
    _historySequence = 0;
    await ChatHistoryStore.get.startSession(
      id: id,
      startedAt: DateTime.now(),
      kind: ChatSessionKind.quickAsk,
    );
  }

  Future<void> _persistGlanceMessage({
    required String role,
    required String text,
  }) async {
    final sessionId = _historySessionId;
    if (sessionId == null) {
      return;
    }
    await ChatHistoryStore.get.appendMessage(
      sessionId: sessionId,
      role: role,
      text: text,
      sequence: _historySequence,
      createdAt: DateTime.now(),
    );
    _historySequence++;
  }

  /// Clear the in-memory context and close its history session. The 4-minute
  /// window maps to one Quick Ask session, mirroring Chat mode's per-session
  /// persistence. endSession is fire-and-forget — it only stamps ended_at.
  void _clearEphemeralContext() {
    _messages.clear();
    final sessionId = _historySessionId;
    _historySessionId = null;
    _historySequence = 0;
    if (sessionId != null) {
      unawaited(
        ChatHistoryStore.get.endSession(
          sessionId: sessionId,
          endedAt: DateTime.now(),
        ),
      );
    }
  }

  bool _isCurrentRequest(int requestVersion) {
    return requestVersion == _requestVersion;
  }

  Future<void> _deleteTempFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  String _shortPreview(String text, {int max = 80}) {
    final cleaned = _cleanText(text);
    if (cleaned.length <= max) {
      return cleaned;
    }
    return '${cleaned.substring(0, max - 1)}…';
  }

  String _cleanText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _capForGlasses(String value) {
    if (value.length <= _maxGlassesResponseChars) {
      return value;
    }
    return '${value.substring(0, _maxGlassesResponseChars).trimRight()}…';
  }

  String _transcriptionErrorMessage(ChatTranscriptionException error) {
    switch (error.kind) {
      case ChatTranscriptionErrorKind.auth:
        return 'API key issue';
      case ChatTranscriptionErrorKind.timeout:
        return 'Transcription timed out';
      case ChatTranscriptionErrorKind.network:
        return 'Network problem';
      case ChatTranscriptionErrorKind.generic:
        return 'Transcription failed';
    }
  }

  String _backendErrorMessage(ChatBackendException error) {
    switch (error.kind) {
      case ChatBackendErrorKind.auth:
        return 'API key issue';
      case ChatBackendErrorKind.timeout:
        return 'Request timed out';
      case ChatBackendErrorKind.network:
        return 'Network problem';
      case ChatBackendErrorKind.generic:
        return 'Something went wrong';
    }
  }

  String _flowErrorMessage(GlanceAssistantFlowException error) {
    if (error.message == 'No recorded audio to transcribe') {
      return "Didn't catch that";
    }
    return 'Something went wrong';
  }
}

class GlanceAssistantFlowException implements Exception {
  const GlanceAssistantFlowException(this.message);

  final String message;

  @override
  String toString() => message;
}
