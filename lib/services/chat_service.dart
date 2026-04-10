import 'dart:io';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/chat_message.dart';
import 'package:demo_ai_even/services/chat_backend.dart';
import 'package:demo_ai_even/services/openai_chat_backend.dart';
import 'package:demo_ai_even/services/openai_transcription_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class ChatService {
  static const _closeGestureGraceWindow = Duration(milliseconds: 1500);

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
  DateTime? _lastSubmitStartedAt;
  final List<ChatMessage> _messages = <ChatMessage>[];

  bool get hasActiveSession => _sessionId != null;
  bool get isListening => _isListening;
  bool get isThinking => _isThinking;
  bool get isReady => _modeActive && !_isListening && !_isThinking;

  Future<void> enterMode() async {
    await resetSession();
    _modeActive = true;
    _sessionVersion++;
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    await _showText('Chat ready\nTilt up to talk');
    print('${DateTime.now()} Chat: session started -> $_sessionId');
  }

  Future<void> resetSession() async {
    _sessionVersion++;
    _modeActive = false;
    _isListening = false;
    _isThinking = false;
    _lastSubmitStartedAt = null;
    _messages.clear();
    _sessionId = null;
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Chat: session reset');
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
      await _showText('Chat listen failed');
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
    print('${DateTime.now()} Chat: listening started');
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
        await _showText('No speech detected');
        return 'No speech detected';
      }

      final cleanedTranscript = _cleanText(transcript);
      _messages.add(
        ChatMessage(
          role: ChatRole.user,
          content: cleanedTranscript,
        ),
      );

      await _showText('You said:\n${_shortPreview(cleanedTranscript)}');
      await Future<void>.delayed(const Duration(milliseconds: 900));

      if (!_isCurrentRequest(requestVersion)) {
        return 'Chat session changed';
      }

      await _showText('Thinking...');
      final answer = await _backend.send(messages: List<ChatMessage>.from(_messages));

      if (!_isCurrentRequest(requestVersion)) {
        return 'Chat session changed';
      }

      final cleanedAnswer = _cleanText(answer);
      _messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          content: cleanedAnswer,
        ),
      );
      await _showText(cleanedAnswer);
      print(
        '${DateTime.now()} Chat: assistant reply sent -> chars=${cleanedAnswer.length}, turns=${_messages.length}',
      );
      return 'Assistant replied';
    } on ChatTranscriptionException catch (e) {
      await _showText('Speech error\n${_shortPreview(e.message, max: 40)}');
      return 'Speech error';
    } on ChatBackendException catch (e) {
      await _showText('Chat error\n${_shortPreview(e.message, max: 40)}');
      return 'Chat backend error';
    } on ChatFlowException catch (e) {
      await _showText(_shortPreview(e.message, max: 60));
      return e.message;
    } catch (e) {
      await _showText('Chat failed');
      print('${DateTime.now()} Chat: submit failed -> $e');
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

  Future<void> _showText(String text) async {
    if (!_modeActive) {
      return;
    }
    await TextService.get.startSendText(text);
  }

  bool _isCurrentRequest(int requestVersion) {
    return _modeActive && requestVersion == _sessionVersion;
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
}

class ChatFlowException implements Exception {
  const ChatFlowException(this.message);

  final String message;
}
