import 'dart:async';
import 'dart:io';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/chat_message.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/chat_backend.dart';
import 'package:demo_ai_even/services/chat_history_store.dart';
import 'package:demo_ai_even/services/openai_chat_backend.dart';
import 'package:demo_ai_even/services/openai_transcription_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/streaming_render_queue.dart';
import 'package:demo_ai_even/services/text_service.dart';

class ChatService {
  static const _closeGestureGraceWindow = Duration(milliseconds: 1500);
  static const _maxGlassesResponseChars = 900;
  static const _maxVisibleWrappedLines = 4;
  static const _maxCommittedWrappedLines = 12;
  static const _charsPerLine = 48;

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
  ChatStreamingState _streamingState = ChatStreamingState.idle;
  bool _streamingSurfaceVisible = false;
  StreamingRenderQueue? _renderQueue;
  Completer<void>? _renderQueueDrainedCompleter;
  List<String> _committedDisplayLines = <String>[];
  _ActiveChatDisplayTurn? _activeDisplayTurn;
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
    _renderQueue?.cancel();
    _renderQueue = null;
    _renderQueueDrainedCompleter?.complete();
    _renderQueueDrainedCompleter = null;
    _streamingState = ChatStreamingState.idle;
    _streamingSurfaceVisible = false;
    _committedDisplayLines = <String>[];
    _activeDisplayTurn = null;
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

    _renderQueue?.cancel();
    _renderQueue = null;
    _renderQueueDrainedCompleter?.complete();
    _renderQueueDrainedCompleter = null;
    await _stopStreaming(sendFinalFrame: false);
    _streamingState = ChatStreamingState.idle;
    _streamingSurfaceVisible = false;
    _activeDisplayTurn = null;
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
      await _showCommittedUserTurn(
        role: ChatRole.user,
        text: cleanedTranscript,
      );
      await _startAssistantDisplayTurn();

      if (!_isCurrentRequest(requestVersion)) {
        return 'Chat session changed';
      }
      final answer = await _streamAssistantReply(
        requestVersion,
        messages: List<ChatMessage>.from(_messages),
      );

      if (!_isCurrentRequest(requestVersion)) {
        return 'Chat session changed';
      }

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
      await _finalizeActiveDisplayTurn(textOverride: cleanedAnswer);
      await _renderDisplayBuffer(force: true);
      if (!_streamingSurfaceVisible) {
        await _showText(cleanedAnswer);
      }
      AppLog.info(
        '${DateTime.now()} assistant reply sent -> chars=${cleanedAnswer.length}, turns=${_messages.length}',
        tag: 'Chat',
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
    if (_streamingSurfaceVisible) {
      await _renderDisplayBuffer(force: true);
      return;
    }
    await _showText('Chat ready\nTilt up to talk');
  }

  Future<void> _showText(String text) async {
    if (!_modeActive) {
      return;
    }
    if (_streamingSurfaceVisible) {
      await Proto.stopStreamingText(sendFinalFrame: false);
      _streamingSurfaceVisible = false;
    }
    markDisplayVisible(value: true, source: 'Chat.showText');
    await TextService.get.startSendText(text);
  }

  Future<String> _streamAssistantReply(
    int requestVersion, {
    required List<ChatMessage> messages,
  }) async {
    _streamingState = ChatStreamingState.streaming;
    final answerBuffer = StringBuffer();

    try {
      var sawVisibleStreamChunk = false;
      await for (final chunk in _backend.stream(messages: messages)) {
        if (!_isCurrentRequest(requestVersion)) {
          _renderQueue?.cancel();
          _renderQueue = null;
          return _cleanText(answerBuffer.toString());
        }

        if (chunk.isEmpty) {
          continue;
        }

        if (!sawVisibleStreamChunk) {
          sawVisibleStreamChunk = true;
          AppLog.info('${DateTime.now()} assistant stream started', tag: 'Chat');
        }
        answerBuffer.write(chunk);
        _activeDisplayTurn = _ActiveChatDisplayTurn(
          role: ChatRole.assistant,
          text: '${_activeDisplayTurn?.text ?? ''}$chunk',
        );
        _renderQueue?.appendText(chunk);
      }

      final streamedText = _cleanText(answerBuffer.toString());
      AppLog.info(
        '${DateTime.now()} backend complete -> len=${streamedText.length}',
        tag: 'Chat',
      );

      if (streamedText.isEmpty) {
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
      _streamingState = ChatStreamingState.completed;
      AppLog.info(
        '${DateTime.now()} assistant stream completed -> len=${streamedText.length}',
        tag: 'Chat',
      );
      return streamedText;
    } on ChatBackendException catch (e) {
      final queueStarted = _renderQueue?.isDraining ?? false;
      if (queueStarted) {
        _streamingState = ChatStreamingState.error;
        rethrow;
      }

      _streamingState = ChatStreamingState.error;
      AppLog.info('${DateTime.now()} fallback to 0x4E', tag: 'Chat');
      final answer = await _backend.send(messages: messages);
      return answer;
    } catch (_) {
      _streamingState = ChatStreamingState.error;
      rethrow;
    }
  }

  Future<void> _stopStreaming({required bool sendFinalFrame}) async {
    _renderQueue?.cancel();
    _renderQueue = null;
    _renderQueueDrainedCompleter?.complete();
    _renderQueueDrainedCompleter = null;
    if (_streamingSurfaceVisible) {
      await Proto.stopStreamingText(sendFinalFrame: sendFinalFrame);
      _streamingSurfaceVisible = false;
    }
  }

  Future<void> _showCommittedUserTurn({
    required ChatRole role,
    required String text,
  }) async {
    _commitWrappedLines(_wrapTurn(role, text));
    AppLog.info(
      '${DateTime.now()} chat display buffer appended ${role == ChatRole.user ? 'user' : 'assistant'} turn -> len=${text.length}',
      tag: 'Chat',
    );
    await _renderDisplayBuffer(force: true);
  }

  Future<void> _startAssistantDisplayTurn() async {
    _activeDisplayTurn = const _ActiveChatDisplayTurn(
      role: ChatRole.assistant,
      text: '',
    );
    await _ensureStreamingConversationSurface();
    // Show "G1: Thinking..." while waiting for first backend chunk.
    await _flushNonQueueVisibleWindow();
    // Create the paced render queue for the assistant reply.
    _renderQueueDrainedCompleter = Completer<void>();
    _renderQueue = StreamingRenderQueue(
      maxVisibleLines: _maxVisibleWrappedLines,
      charsPerLine: _charsPerLine,
      initialCommittedLines: List<String>.from(_committedDisplayLines),
      sendLine: _sendQueuedLine,
      onDrained: _onRenderQueueDrained,
    );
  }

  Future<void> _finalizeActiveDisplayTurn({String? textOverride}) async {
    final activeTurn = _activeDisplayTurn;
    if (activeTurn == null) {
      return;
    }
    final finalText = textOverride ?? activeTurn.text;
    if (finalText.isNotEmpty) {
      _commitWrappedLines(_wrapTurn(activeTurn.role, finalText));
    }
    _activeDisplayTurn = null;
  }

  Future<void> _renderDisplayBuffer({bool force = false}) async {
    if (!_modeActive) {
      return;
    }
    await _ensureStreamingConversationSurface();
    await _flushNonQueueVisibleWindow();
  }

  Future<void> _ensureStreamingConversationSurface() async {
    if (_streamingSurfaceVisible) {
      return;
    }
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    await Proto.startStreamingText();
    _streamingSurfaceVisible = true;
  }

  /// Flush the visible window for non-queue renders (user turns, Thinking...,
  /// final committed view). The render queue handles its own sends.
  Future<void> _flushNonQueueVisibleWindow() async {
    if (!_streamingSurfaceVisible) {
      return;
    }
    final window = _currentVisibleWindow();
    markDisplayVisible(value: true, source: 'Chat.stream');
    for (int i = 0; i < window.visibleLines.length; i++) {
      final lineIndex = i + 1;
      final lineText = window.visibleLines[i];
      final isActiveLine = window.activeLineIndex == lineIndex;
      if (isActiveLine) {
        await Proto.sendStreamingText(
          lineText,
          line: lineIndex,
          isFinal: false,
        );
      } else {
        await Proto.sendStreamingLine(
          lineText,
          line: lineIndex,
          confirmed: true,
        );
      }
    }
  }

  ({List<String> visibleLines, int? activeLineIndex}) _currentVisibleWindow() {
    final combined = <String>[
      ..._committedDisplayLines,
      ..._currentActiveWrappedLines(),
    ];
    final visible = combined.length <= _maxVisibleWrappedLines
        ? combined
        : combined.sublist(combined.length - _maxVisibleWrappedLines);
    if (visible.isEmpty) {
      return (visibleLines: const <String>[], activeLineIndex: null);
    }
    if (_activeDisplayTurn == null) {
      return (
        visibleLines: visible.map(_capForGlasses).toList(growable: false),
        activeLineIndex: null,
      );
    }
    return (
      visibleLines: visible.map(_capForGlasses).toList(growable: false),
      activeLineIndex: visible.length,
    );
  }

  List<String> _currentActiveWrappedLines() {
    final activeTurn = _activeDisplayTurn;
    if (activeTurn == null) {
      return const <String>[];
    }
    if (activeTurn.text.isEmpty) {
      return const <String>['G1: Thinking...'];
    }
    return _wrapTurn(activeTurn.role, activeTurn.text);
  }

  Future<void> _sendQueuedLine(
    int line,
    String text, {
    required bool isActive,
  }) async {
    if (!_streamingSurfaceVisible || !_modeActive) return;
    markDisplayVisible(value: true, source: 'Chat.stream');
    if (isActive) {
      await Proto.sendStreamingText(text, line: line, isFinal: false);
    } else {
      await Proto.sendStreamingLine(text, line: line, confirmed: true);
    }
  }

  void _onRenderQueueDrained() {
    final completer = _renderQueueDrainedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  List<String> _wrapTurn(ChatRole role, String text) {
    final raw = '${role == ChatRole.user ? 'You:' : 'G1:'} $text';
    return _measureWrappedLines(raw);
  }

  List<String> _measureWrappedLines(String text) {
    return StreamingRenderQueue.wrapText(text, _charsPerLine);
  }

  void _commitWrappedLines(List<String> lines) {
    if (lines.isEmpty) {
      return;
    }
    _committedDisplayLines = <String>[
      ..._committedDisplayLines,
      ...lines,
    ];
    if (_committedDisplayLines.length > _maxCommittedWrappedLines) {
      _committedDisplayLines = _committedDisplayLines.sublist(
        _committedDisplayLines.length - _maxCommittedWrappedLines,
      );
      AppLog.info(
        '${DateTime.now()} display buffer trimmed -> lines=${_committedDisplayLines.length}',
        tag: 'Chat',
      );
    }
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

enum ChatStreamingState {
  idle,
  streaming,
  completed,
  error,
}

class _ActiveChatDisplayTurn {
  const _ActiveChatDisplayTurn({
    required this.role,
    required this.text,
  });

  final ChatRole role;
  final String text;
}
