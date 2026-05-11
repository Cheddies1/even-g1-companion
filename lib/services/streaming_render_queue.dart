import 'dart:async';

import 'package:even_companion/services/app_log.dart';

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
  static const Duration drainInterval = Duration(milliseconds: 200);

  // -- Configuration -------------------------------------------------------
  final Future<void> Function(int line, String text, {required bool isActive}) _sendLine;
  final void Function() _onDrained;

  /// Firmware display width in characters (confirmed from live testing:
  /// ~43 chars per visual row, 3 visible rows).
  static const int _displayLineWidth = 43;

  /// Number of visible rows on the firmware display.
  static const int _displayVisibleRows = 3;

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
      // Build text with embedded \n at word-wrap boundaries, then keep
      // only the last N lines (the firmware's visible area). This creates
      // the scrolling effect: as new content wraps to a new line, the
      // oldest visible line is trimmed off the front.
      final wrapped = _wrapWithNewlines(
        'G1: ${targetWords.sublist(0, _displayedWordCount).join(' ')}',
      );
      _displayedText = _tailLines(wrapped, _displayVisibleRows);
    }

    // Send if text changed.
    if (!_cancelled && _displayedText != _lastSentText) {
      // Line 1: cursor marker with '\n' (matches official app pattern).
      await _sendLine(1, '\n', isActive: false);
      // Line 2: all text content — firmware wraps and scrolls.
      await _sendLine(2, _displayedText, isActive: true);
      _lastSentText = _displayedText;
    }

    AppLog.debug(
      '${DateTime.now()} render queue: tick words=$_displayedWordCount/$wordsAvailable '
      'textLen=${_displayedText.length}',
      tag: 'Chat',
    );

    // Check drain-complete. The last normal tick already sent all words
    // to line 2 — no final re-send needed. Re-sending the full text with
    // original whitespace (newlines etc.) causes the firmware to re-render
    // from the top, jumping the display back to the beginning.
    if (_backendComplete &&
        _displayedWordCount >= wordsAvailable &&
        !_drainedFired) {
      _drainedFired = true;
      _drainTimer?.cancel();
      _drainTimer = null;
      AppLog.info(
        '${DateTime.now()} render queue: display complete, '
        'words=$_displayedWordCount/$wordsAvailable textLen=${_displayedText.length}',
        tag: 'Chat',
      );
      if (!_cancelled) {
        _onDrained();
      }
    }
  }

  /// Keep only the last [maxLines] lines from [text] (split on `\n`).
  static String _tailLines(String text, int maxLines) {
    final lines = text.split('\n');
    if (lines.length <= maxLines) return text;
    return lines.sublist(lines.length - maxLines).join('\n');
  }

  /// Insert `\n` at word boundaries every ~[_displayLineWidth] chars.
  /// The firmware uses these as paragraph breaks for scrolling.
  static String _wrapWithNewlines(String text) {
    final words = text.split(' ');
    final buffer = StringBuffer();
    int lineLen = 0;
    for (int i = 0; i < words.length; i++) {
      final word = words[i];
      if (i == 0) {
        buffer.write(word);
        lineLen = word.length;
      } else if (lineLen + 1 + word.length > _displayLineWidth) {
        buffer.write('\n');
        buffer.write(word);
        lineLen = word.length;
      } else {
        buffer.write(' ');
        buffer.write(word);
        lineLen += 1 + word.length;
      }
    }
    return buffer.toString();
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
