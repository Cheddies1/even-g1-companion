import 'dart:async';

import 'package:demo_ai_even/services/app_log.dart';

/// Paced display queue for streaming assistant text to the glasses.
///
/// Matches the official app's 0x52 protocol usage discovered from the BLE
/// capture: line 1 is a cursor marker (empty), line 2 carries ALL the text.
/// Every update sends both packets. The firmware handles wrapping and
/// scrolling of line 2's content natively.
class StreamingRenderQueue {
  StreamingRenderQueue({
    required Future<void> Function(int line, String text, {required bool isActive}) sendLine,
    required void Function() onDrained,
  })  : _sendLine = sendLine,
        _onDrained = onDrained;

  // -- Tuning constants (easy to tweak) ------------------------------------
  static const int wordsPerTick = 2;
  static const Duration drainInterval = Duration(milliseconds: 150);

  /// Max text bytes in a single 0x52 packet (length byte is 1 byte, minus
  /// header overhead). If the text exceeds this, only the tail is sent.
  static const int _maxTextBytes = 230;

  // -- Configuration -------------------------------------------------------
  final Future<void> Function(int line, String text, {required bool isActive}) _sendLine;
  final void Function() _onDrained;

  // -- State ---------------------------------------------------------------
  final StringBuffer _targetText = StringBuffer();
  int _displayedWordCount = 0;
  String _displayedText = '';
  String _lastSentText = '';
  Timer? _drainTimer;
  bool _backendComplete = false;
  bool _cancelled = false;
  bool _drainedFired = false;
  bool _sendingInProgress = false;

  bool get isDraining => _drainTimer != null && !_cancelled;

  /// Feed a backend chunk into the target buffer.
  void appendText(String chunk) {
    if (_cancelled) return;
    _targetText.write(chunk);
    AppLog.info(
      '${DateTime.now()} render queue: chunk chars=${chunk.length} targetLen=${_targetText.length}',
      tag: 'Chat',
    );
    _ensureDrainTimer();
  }

  /// Signal that the backend stream has ended.
  void markBackendComplete() {
    if (_cancelled) return;
    _backendComplete = true;
    final targetWords = _splitWords(_targetText.toString());
    AppLog.info(
      '${DateTime.now()} render queue: backend complete, '
      'targetLen=${_targetText.length} targetWords=${targetWords.length} '
      'displayedWords=$_displayedWordCount',
      tag: 'Chat',
    );
    _ensureDrainTimer();
  }

  /// Cancel the queue.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _drainTimer?.cancel();
    _drainTimer = null;
    AppLog.info('${DateTime.now()} render queue: cancelled', tag: 'Chat');
  }

  // -- Drain loop ----------------------------------------------------------

  void _ensureDrainTimer() {
    if (_drainTimer != null || _cancelled) return;
    AppLog.info('${DateTime.now()} render queue: started', tag: 'Chat');
    _drainTimer = Timer.periodic(drainInterval, (_) => _drainTick());
  }

  Future<void> _drainTick() async {
    if (_cancelled || _sendingInProgress) return;
    _sendingInProgress = true;
    try {
      await _advanceAndSend();
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} render queue: tick error -> $e',
        tag: 'Chat',
      );
    } finally {
      _sendingInProgress = false;
    }
  }

  Future<void> _advanceAndSend() async {
    final target = _targetText.toString();
    final targetWords = _splitWords(target);
    final wordsAvailable = targetWords.length;

    if (_displayedWordCount >= wordsAvailable && !_backendComplete) {
      return;
    }

    // Advance by up to wordsPerTick words.
    final newWordCount = (_displayedWordCount + wordsPerTick)
        .clamp(0, wordsAvailable);

    if (newWordCount > _displayedWordCount) {
      _displayedWordCount = newWordCount;
      _displayedText =
          'G1: ${targetWords.sublist(0, _displayedWordCount).join(' ')}';
    }

    // Send if text changed.
    final textToSend = _capForPacket(_displayedText);
    if (!_cancelled && textToSend != _lastSentText) {
      // Line 1: cursor marker (matches official app pattern).
      await _sendLine(1, '', isActive: false);
      // Line 2: all text content — firmware wraps and scrolls.
      await _sendLine(2, textToSend, isActive: true);
      _lastSentText = textToSend;
    }

    AppLog.debug(
      '${DateTime.now()} render queue: tick words=$_displayedWordCount/$wordsAvailable '
      'textLen=${_displayedText.length}',
      tag: 'Chat',
    );

    // Check drain-complete.
    if (_backendComplete &&
        _displayedWordCount >= wordsAvailable &&
        !_drainedFired) {
      // Final: ensure the full text is displayed.
      final fullText = 'G1: ${target.trim()}';
      final finalToSend = _capForPacket(fullText);
      if (!_cancelled && finalToSend != _lastSentText) {
        await _sendLine(1, '', isActive: false);
        await _sendLine(2, finalToSend, isActive: true);
        _lastSentText = finalToSend;
      }

      _drainedFired = true;
      _drainTimer?.cancel();
      _drainTimer = null;
      AppLog.info(
        '${DateTime.now()} render queue: display complete, '
        'words=$_displayedWordCount/$wordsAvailable textLen=${fullText.length}',
        tag: 'Chat',
      );
      if (!_cancelled) {
        _onDrained();
      }
    }
  }

  /// If text exceeds the max 0x52 packet payload, send only the tail.
  /// The firmware scrolls, so the user sees the most recent content.
  String _capForPacket(String text) {
    if (text.length <= _maxTextBytes) return text;
    return text.substring(text.length - _maxTextBytes);
  }

  /// Split text into words.
  static List<String> _splitWords(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const <String>[];
    return trimmed.split(RegExp(r'\s+'));
  }

  /// Wrap [text] into lines of at most [maxChars] characters, breaking at
  /// word boundaries. Used by ChatService for non-queue renders (0x4E).
  static List<String> wrapText(String text, int maxChars) {
    final paragraphs = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.isEmpty) return const <String>[];

    final result = <String>[];
    for (final paragraph in paragraphs) {
      final words = paragraph.split(RegExp(r'\s+'));
      final buffer = StringBuffer();
      for (final word in words) {
        if (buffer.isEmpty) {
          buffer.write(word);
        } else if (buffer.length + 1 + word.length <= maxChars) {
          buffer.write(' ');
          buffer.write(word);
        } else {
          result.add(buffer.toString());
          buffer.clear();
          buffer.write(word);
        }
      }
      if (buffer.isNotEmpty) {
        result.add(buffer.toString());
      }
    }
    return result;
  }
}
