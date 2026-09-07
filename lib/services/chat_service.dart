import 'dart:async';
import 'dart:io';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/chat_message.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/chat_backend.dart';
import 'package:even_companion/services/chat_history_store.dart';
import 'package:even_companion/services/openai_chat_backend.dart';
import 'package:even_companion/services/openai_transcription_service.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/streaming_render_queue.dart';
import 'package:even_companion/services/text_service.dart';

class ChatService {
  static const _closeGestureGraceWindow = Duration(milliseconds: 1500);
  static const _maxGlassesResponseChars = 900;

  static ChatService? _instance;
  static ChatService get get => _instance ??= ChatService._();

  ChatService._({
    ChatBackend? backend,
    OpenAiTranscriptionService? transcriptionService,
  })  : _backend = backend ?? OpenAiChatBackend(),
        _transcriptionService =
            transcriptionService ?? OpenAiTranscriptionService();

  final ChatBackend _backend;
  final OpenAiTranscriptionService _transcriptionService;

  String? _sessionId;
  int _sessionVersion = 0;
  bool _modeActive = false;
  bool _isListening = false;
  bool _isThinking = false;
  bool _isDisplayVisible = false;
  DateTime? _lastSubmitStartedAt;
  int _messageSequence = 0;
  int _persistedMessageCount = 0;
  StreamingRenderQueue? _renderQueue;
  Completer<void>? _renderQueueDrainedCompleter;
  final List<ChatMessage> _messages = <ChatMessage>[];

  bool get hasActiveSession => _sessionId != null;
  bool get isDisplayVisible => _isDisplayVisible;
  bool get isListening => _isListening;
  bool get isThinking => _isThinking;
  bool get isReady => _modeActive && !_isListening && !_isThinking;

  void markDisplayVisible({
    required bool value,
    required String source,
  }) {
    if (_isDisplayVisible == value) {
      return;
    }
    AppLog.debug(
      '${DateTime.now()} DisplayState: source=$source service=Chat old=$_isDisplayVisible new=$value mode=Chat',
    );
    _isDisplayVisible = value;
  }

  Future<void> enterMode({
    bool showReadyCard = true,
  }) async {
    await resetSession();
    _modeActive = true;
    _sessionVersion++;
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _messageSequence = 0;
    _persistedMessageCount = 0;
    final startedAt = DateTime.now();
    await ChatHistoryStore.get.startSession(
      id: _sessionId!,
      startedAt: startedAt,
    );
    if (showReadyCard) {
      await _showText('Chat ready\nTilt up to talk');
    }
    AppLog.info(
      '${DateTime.now()} session started -> $_sessionId',
      tag: 'Chat',
    );
  }

  Future<void> resetSession() async {
    final sessionId = _sessionId;
    final shouldDeleteSession = sessionId != null && _persistedMessageCount == 0;
    final shouldCloseSession = sessionId != null && _persistedMessageCount > 0;

    _sessionVersion++;
    _modeActive = false;
    _isListening = false;
    _isThinking = false;
    markDisplayVisible(value: false, source: 'Chat.resetSession');
    _lastSubmitStartedAt = null;
    _messageSequence = 0;
    _persistedMessageCount = 0;
    _cancelRenderQueue();
    _messages.clear();
    _sessionId = null;
    await BleManager.invokeMethod('cancelGlassesCapture');
    await Proto.stopStreamingText(sendFinalFrame: false);
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    if (shouldDeleteSession) {
      await ChatHistoryStore.get.deleteSession(sessionId);
    } else if (shouldCloseSession) {
      await ChatHistoryStore.get.endSession(
        sessionId: sessionId,
        endedAt: DateTime.now(),
      );
    }
    AppLog.info('${DateTime.now()} session reset', tag: 'Chat');
  }

  Future<void> closeVisibleDisplay() async {
    if (!_modeActive) {
      return;
    }

    _cancelRenderQueue();
    await Proto.stopStreamingText(sendFinalFrame: false);
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    markDisplayVisible(value: false, source: 'Chat.closeVisibleDisplay');
    AppLog.info('${DateTime.now()} visible display closed', tag: 'Chat');
  }

  Future<String> startListening() async {
    if (!_modeActive) {
      await enterMode();
    }
    if (_isThinking) {
      await _showText('Still thinking...');
      return 'Chat still thinking';
    }
    if (_isListening) {
      return 'Already listening';
    }

    // Clean exit from any active 0x52 streaming surface from a previous
    // turn. The firmware needs 0x18 before mic audio routes correctly
    // after a 0x52 session. Skip if nothing is active to avoid unnecessary
    // BLE round-trips that can destabilise a marginal connection.
    if (_renderQueue != null || Proto.isStreamingTextActive) {
      _cancelRenderQueue();
      await Proto.stopStreamingText(sendFinalFrame: false);
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();
    }

    final started = await BleManager.invokeMethod<bool>('startGlassesCapture');
    if (started != true) {
      await _showText('Mic start failed');
      return 'Chat listen failed';
    }

    final (_, micStarted) = await Proto.micOn(lr: 'R');
    if (!micStarted) {
      await BleManager.invokeMethod('cancelGlassesCapture');
      await _showText('Mic start failed');
      return 'Chat mic failed';
    }

    _isListening = true;
    await _showText('Listening...');
    AppLog.info('${DateTime.now()} listening started', tag: 'Chat');
    return 'Listening for chat';
  }

  Future<String> stopListeningAndSubmit() async {
    if (!_isListening) {
      return _isThinking ? 'Chat still thinking' : 'Chat not listening';
    }

    final requestVersion = _sessionVersion;
    _isListening = false;
    _isThinking = true;
    _lastSubmitStartedAt = DateTime.now();

    try {
      final raw = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
        'stopGlassesCaptureToTemp',
      );
      final filePath = (raw?['localPath'] as String?) ?? '';
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();

      if (filePath.isEmpty) {
        throw const ChatFlowException('No recorded audio to transcribe');
      }

      final transcript = await _transcriptionService.transcribe(filePath);
      await _deleteTempFile(filePath);

      if (!_isCurrentRequest(requestVersion)) {
        return 'Chat session changed';
      }

      if (transcript.isEmpty) {
        await _showText("Didn't catch that");
        return 'No speech detected';
      }

      final cleanedTranscript = _cleanText(transcript);
      _messages.add(
        ChatMessage(
          role: ChatRole.user,
          content: cleanedTranscript,
        ),
      );
      await _persistMessage(
        role: ChatRole.user,
        text: cleanedTranscript,
      );

      // Phase 1: show user question via 0x4E.
      await _showText('You: $cleanedTranscript');
      AppLog.info(
        '${DateTime.now()} user question displayed -> len=${cleanedTranscript.length}',
        tag: 'Chat',
      );

      if (!_isCurrentRequest(requestVersion)) {
        return 'Chat session changed';
      }

      // Phase 2: show "Thinking..." while the backend starts.
      await _showText('Thinking...');

      // Phase 3: stream assistant reply via fresh 0x52 surface.
      // The method handles message persistence and display internally.
      await _streamAssistantReply(
        requestVersion,
        backend: _backend,
        messages: List<ChatMessage>.from(_messages),
      );
      return 'Assistant replied';
    } on ChatTranscriptionException catch (e) {
      AppLog.error(
        '${DateTime.now()} transcription error -> ${e.kind} | ${e.message}',
        tag: 'Chat',
      );
      await _showText(_transcriptionErrorMessage(e));
      return 'Speech error';
    } on ChatBackendException catch (e) {
      AppLog.error(
        '${DateTime.now()} backend error -> ${e.kind} | ${e.message}',
        tag: 'Chat',
      );
      await _showText(_backendErrorMessage(e));
      return 'Chat backend error';
    } on ChatFlowException catch (e) {
      AppLog.error(
        '${DateTime.now()} flow error -> ${e.message}',
        tag: 'Chat',
      );
      await _showText(_flowErrorMessage(e));
      return e.message;
    } catch (e) {
      await _showText('Something went wrong');
      AppLog.error('${DateTime.now()} submit failed -> $e', tag: 'Chat');
      return 'Chat failed';
    } finally {
      _isThinking = false;
    }
  }

  bool shouldIgnoreCloseGesture() {
    if (!_modeActive) {
      return false;
    }
    if (_isListening || _isThinking) {
      return true;
    }
    final lastSubmitStartedAt = _lastSubmitStartedAt;
    if (lastSubmitStartedAt == null) {
      return false;
    }
    return DateTime.now().difference(lastSubmitStartedAt) <
        _closeGestureGraceWindow;
  }

  String get summary =>
      'Chat mode reuses glasses audio capture, transcribes speech, sends it to a swappable backend, and renders the reply on the glasses while the mode stays active.';

  Future<void> showReadyPrompt() async {
    if (!_modeActive || _isListening || _isThinking) {
      return;
    }
    await _showText('Chat ready\nTilt up to talk');
  }

  // -- Display primitives --------------------------------------------------

  /// Show text via 0x4E (the proven legacy text path). Clears any active
  /// 0x52 streaming surface first.
  Future<void> _showText(String text) async {
    if (!_modeActive) {
      return;
    }
    _cancelRenderQueue();
    await Proto.stopStreamingText(sendFinalFrame: false);
    markDisplayVisible(value: true, source: 'Chat.showText');
    await TextService.get.startSendText(text);
  }

  /// Init a fresh 0x52 surface, create the render queue, and start draining.
  /// Returns when the queue has fully drained (all text displayed).
  Future<void> _streamAssistantReply(
    int requestVersion, {
    required ChatBackend backend,
    required List<ChatMessage> messages,
  }) async {
    // Clear the 0x4E "Thinking..." and start a fresh 0x52 surface.
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    await Proto.startStreamingText();

    _renderQueueDrainedCompleter = Completer<void>();
    _renderQueue = StreamingRenderQueue(
      sendLine: _sendQueuedLine,
      onDrained: _onRenderQueueDrained,
    );

    final answerBuffer = StringBuffer();

    try {
      var sawVisibleStreamChunk = false;
      await for (final chunk in backend.stream(messages: messages)) {
        if (!_isCurrentRequest(requestVersion)) {
          _cancelRenderQueue();
          return;
        }

        if (chunk.isEmpty) {
          continue;
        }

        if (!sawVisibleStreamChunk) {
          sawVisibleStreamChunk = true;
          AppLog.info('${DateTime.now()} assistant stream started', tag: 'Chat');
        }
        answerBuffer.write(chunk);
        _renderQueue?.appendText(chunk);
      }

      final streamedText = _cleanText(answerBuffer.toString());
      AppLog.info(
        '${DateTime.now()} backend complete -> len=${streamedText.length}',
        tag: 'Chat',
      );

      if (streamedText.isEmpty) {
        _cancelRenderQueue();
        throw const ChatBackendException(
          'Chat backend returned no text',
          kind: ChatBackendErrorKind.generic,
        );
      }

      // Signal the render queue to drain remaining text and wait.
      _renderQueue?.markBackendComplete();
      final drainCompleter = _renderQueueDrainedCompleter;
      if (drainCompleter != null && !drainCompleter.isCompleted) {
        await drainCompleter.future;
      }

      final cleanedAnswer = _capForGlasses(streamedText);
      _messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          content: cleanedAnswer,
        ),
      );
      await _persistMessage(
        role: ChatRole.assistant,
        text: cleanedAnswer,
      );
      AppLog.info(
        '${DateTime.now()} assistant reply sent -> chars=${cleanedAnswer.length}, turns=${_messages.length}',
        tag: 'Chat',
      );
    } on ChatBackendException catch (e) {
      final queueStarted = _renderQueue?.isDraining ?? false;
      _cancelRenderQueue();
      if (queueStarted) {
        rethrow;
      }

      AppLog.info('${DateTime.now()} fallback to 0x4E', tag: 'Chat');
      await Proto.stopStreamingText(sendFinalFrame: false);
      final answer = await backend.send(messages: messages);
      final cleanedAnswer = _capForGlasses(_cleanText(answer));
      _messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          content: cleanedAnswer,
        ),
      );
      await _persistMessage(
        role: ChatRole.assistant,
        text: cleanedAnswer,
      );
      await _showText('G1: $cleanedAnswer');
      return;
    } catch (_) {
      _cancelRenderQueue();
      rethrow;
    }
  }

  // -- Render queue callbacks ----------------------------------------------

  Future<void> _sendQueuedLine(
    int line,
    String text, {
    required bool isActive,
  }) async {
    if (!_modeActive) return;
    markDisplayVisible(value: true, source: 'Chat.stream');
    // Both lines use plain text packets (no cursor frame) — matching
    // the official app's 0x52 pattern from the BLE capture. Line 1 is
    // always '\n' (cursor marker), line 2 carries all text content.
    await Proto.sendStreamingLine(text, line: line, confirmed: false);
  }

  void _onRenderQueueDrained() {
    final completer = _renderQueueDrainedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _cancelRenderQueue() {
    _renderQueue?.cancel();
    _renderQueue = null;
    final completer = _renderQueueDrainedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _renderQueueDrainedCompleter = null;
  }

  // -- Helpers -------------------------------------------------------------

  /// Called when the BLE transport is lost (full or single-leg disconnect).
  /// Clears runtime flags and cancels the render queue so that stale
  /// _isListening/_isThinking state cannot block display recovery.
  /// Must not perform any BLE IO — transport is gone.
  void handleTransportLost() {
    _isListening = false;
    _isThinking = false;
    _lastSubmitStartedAt = null;
    markDisplayVisible(value: false, source: 'Chat.handleTransportLost');
    // Bump the session version so any in-flight completion callback finds
    // _isCurrentRequest() == false and exits its hot loop cleanly.
    _sessionVersion++;
    _cancelRenderQueue();
    AppLog.info(
      '${DateTime.now()} transport lost — flags cleared',
      tag: 'Chat',
    );
  }

  bool _isCurrentRequest(int requestVersion) {
    return _modeActive && requestVersion == _sessionVersion;
  }

  Future<void> _persistMessage({
    required ChatRole role,
    required String text,
  }) async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    await ChatHistoryStore.get.appendMessage(
      sessionId: sessionId,
      role: role.apiRole,
      text: text,
      sequence: _messageSequence,
      createdAt: DateTime.now(),
    );
    _messageSequence++;
    _persistedMessageCount++;
  }

  Future<void> _deleteTempFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
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
        // Transcription runs on the self-hosted whisper-server, so a
        // transport failure here usually means that box is unreachable
        // rather than the phone being offline. "Network problem" sent
        // people looking at the wrong thing.
        return 'Whisper unreachable';
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

  String _flowErrorMessage(ChatFlowException error) {
    switch (error.message) {
      case 'No recorded audio to transcribe':
        return 'Transcription failed';
    }
    return 'Something went wrong';
  }
}

class ChatFlowException implements Exception {
  const ChatFlowException(this.message);

  final String message;
}
