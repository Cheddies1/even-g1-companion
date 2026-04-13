import 'dart:async';
import 'dart:io';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/chat_message.dart';
import 'package:demo_ai_even/services/chat_backend.dart';
import 'package:demo_ai_even/services/openai_chat_backend.dart';
import 'package:demo_ai_even/services/openai_transcription_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class GlanceAssistantService {
  GlanceAssistantService._({
    OpenAiChatBackend? backend,
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

  final OpenAiChatBackend _backend;
  final OpenAiTranscriptionService _transcriptionService;

  final List<ChatMessage> _messages = <ChatMessage>[];
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
      print('${DateTime.now()} GlanceAssistant: start ignored -> still thinking');
      await _showText('Thinking...');
      return 'Assistant still thinking';
    }
    if (_isListening) {
      print('${DateTime.now()} GlanceAssistant: start ignored -> already listening');
      return 'Assistant already listening';
    }

    _expireSessionIfStale();
    _displayClearTimer?.cancel();

    print('${DateTime.now()} GlanceAssistant: recorder start requested');
    final started = await BleManager.invokeMethod<bool>('startGlassesCapture');
    if (started != true) {
      print('${DateTime.now()} GlanceAssistant: recorder start failed');
      await _showText('Mic start failed');
      _scheduleClear();
      return 'Assistant listen failed';
    }

    print('${DateTime.now()} GlanceAssistant: micOn requested');
    final (_, micStarted) = await Proto.micOn(lr: 'R');
    if (!micStarted) {
      print('${DateTime.now()} GlanceAssistant: micOn failed');
      await BleManager.invokeMethod('cancelGlassesCapture');
      await _showText('Mic start failed');
      _scheduleClear();
      return 'Assistant mic failed';
    }

    _isListening = true;
    _lastActivityAt = DateTime.now();
    print('${DateTime.now()} GlanceAssistant: listening started');
    return 'Listening for glance assistant';
  }

  Future<String> stopListeningAndSubmit() async {
    if (!_isListening) {
      print(
        '${DateTime.now()} GlanceAssistant: stop ignored -> isListening=$_isListening isThinking=$_isThinking',
      );
      return _isThinking ? 'Assistant still thinking' : 'Assistant not listening';
    }

    final requestVersion = ++_requestVersion;
    _isListening = false;
    _isThinking = true;

    try {
      print('${DateTime.now()} GlanceAssistant: recorder stopToTemp requested');
      final raw = await BleManager.invokeMethod<Map<dynamic, dynamic>>(
        'stopGlassesCaptureToTemp',
      );
      final filePath = (raw?['localPath'] as String?) ?? '';
      print(
        '${DateTime.now()} GlanceAssistant: stopToTemp result -> success=${raw?['success']} localPath=$filePath pcmBytes=${raw?['pcmBytes']} durationMs=${raw?['durationMs']}',
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

      await _showText('You said:\n${_shortPreview(cleanedTranscript)}');
      await Future<void>.delayed(_previewDelay);

      if (!_isCurrentRequest(requestVersion)) {
        return 'Glance assistant request changed';
      }

      await _showText('Thinking...');
      final answer = await _backend.send(messages: List<ChatMessage>.from(_messages));

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
    print('${DateTime.now()} GlanceAssistant: close -> cancel capture and clear');
    await BleManager.invokeMethod('cancelGlassesCapture');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
  }

  Future<void> reset() async {
    await close();
    _messages.clear();
    _lastActivityAt = null;
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = null;
  }

  Future<void> _showText(String text) async {
    _displayClearTimer?.cancel();
    _isDisplayVisible = true;
    await TextService.get.startSendText(text);
  }

  void _scheduleClear() {
    _displayClearTimer?.cancel();
    _displayClearTimer = Timer(_responseVisibleDuration, () async {
      if (_isListening || _isThinking) {
        return;
      }
      _isDisplayVisible = false;
      await TextService.get.stopTextSendingByOS();
      await Proto.exit();
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
    _messages.clear();
    _lastActivityAt = null;
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = null;
  }

  void _restartSessionExpiryTimer() {
    _sessionExpiryTimer?.cancel();
    _sessionExpiryTimer = Timer(_sessionExpiry, () {
      _messages.clear();
      _lastActivityAt = null;
    });
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
