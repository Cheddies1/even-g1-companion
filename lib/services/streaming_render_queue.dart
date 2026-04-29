import 'dart:async';

import 'package:demo_ai_even/services/app_log.dart';

/// Paced display queue for streaming assistant text to the glasses.
///
/// The backend appends raw text chunks via [appendText]. A periodic drain
/// timer reveals 1-2 words at a time and sends 0x52 lines to the glasses.
///
/// The queue fills line 1 first, then wraps to line 2, 3, 4 — matching the
/// firmware's expected sequential line progression. When line 4 fills, the
/// window scrolls: all 4 lines are resent with the new content, and the
/// cursor stays on line 4.
///
/// The queue keeps draining after the backend finishes until all text has
/// been displayed, then fires [onDrained].
class StreamingRenderQueue {
  StreamingRenderQueue({
    required this.maxVisibleLines,
    required this.charsPerLine,
    required Future<void> Function(int line, String text, {required bool isActive}) sendLine,
    required void Function() onDrained,
  })  : _sendLine = sendLine,
        _onDrained = onDrained;

  // -- Tuning constants (easy to tweak) ------------------------------------
  static const int wordsPerTick = 2;
  static const Duration drainInterval = Duration(milliseconds: 150);

  // -- Configuration -------------------------------------------------------
  final int maxVisibleLines;
  final int charsPerLine;
  final Future<void> Function(int line, String text, {required bool isActive}) _sendLine;
  final void Function() _onDrained;

  // -- State ---------------------------------------------------------------
  final StringBuffer _targetText = StringBuffer();
  int _displayedWordCount = 0;
  List<String> _wrappedLines = const <String>[];
  final Map<int, String> _lastSentLines = <int, String>{};
  int _lastSentActiveLine = 0;
  Timer? _drainTimer;
  bool _backendComplete = false;
  bool _cancelled = false;
  bool _drainedFired = false;
  bool _sendingInProgress = false;

  bool get isDraining => _drainTimer != null && !_cancelled;

  /// Feed a backend chunk into the target buffer. Starts the drain timer
  /// on first non-empty chunk.
  void appendText(String chunk) {
    if (_cancelled) return;
    _targetText.write(chunk);
    AppLog.info(
      '${DateTime.now()} render queue: chunk chars=${chunk.length} targetLen=${_targetText.length}',
      tag: 'Chat',
    );
    _ensureDrainTimer();
  }

  /// Signal that the backend stream has ended. The queue keeps draining
  /// until all target text is displayed.
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

  /// Cancel the queue. Stops the drain timer and prevents further sends.
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
      final displayedText = targetWords.sublist(0, _displayedWordCount).join(' ');
      _wrappedLines = wrapText('G1: $displayedText', charsPerLine);
    }

    await _sendVisibleWindow();

    // Check drain-complete.
    if (_backendComplete &&
        _displayedWordCount >= wordsAvailable &&
        !_drainedFired) {
      // Final full-text render.
      final fullText = target.trim();
      if (fullText.isNotEmpty) {
        _wrappedLines = wrapText('G1: $fullText', charsPerLine);
        // Force resend all lines for the final frame.
        _lastSentLines.clear();
        _lastSentActiveLine = 0;
        await _sendVisibleWindow();
      }

      _drainedFired = true;
      _drainTimer?.cancel();
      _drainTimer = null;
      AppLog.info(
        '${DateTime.now()} render queue: display complete, '
        'words=$_displayedWordCount/$wordsAvailable wrappedLines=${_wrappedLines.length}',
        tag: 'Chat',
      );
      if (!_cancelled) {
        _onDrained();
      }
    }
  }

  /// Send the current visible window using sequential line filling.
  ///
  /// The assistant text starts at line 1 and fills down. When there are
  /// more wrapped lines than [maxVisibleLines], the window is the last
  /// N lines. The cursor (active flag) is always on the last line.
  ///
  /// This matches the firmware's expectation: line 1 fills, wraps to
  /// line 2, etc., with the cursor progressing sequentially.
  Future<void> _sendVisibleWindow() async {
    if (_wrappedLines.isEmpty || _cancelled) return;

    final visible = _wrappedLines.length <= maxVisibleLines
        ? _wrappedLines
        : _wrappedLines.sublist(_wrappedLines.length - maxVisibleLines);

    // The active (cursor) line is always the last displayed line.
    final activeLineIndex = visible.length;

    AppLog.debug(
      '${DateTime.now()} render queue: tick words=$_displayedWordCount '
      'wrappedLines=${_wrappedLines.length} visibleLines=${visible.length} '
      'activeLine=$activeLineIndex',
      tag: 'Chat',
    );

    for (int i = 0; i < visible.length; i++) {
      if (_cancelled) return;
      final lineIndex = i + 1; // 1-based for 0x52 protocol
      final lineText = visible[i];
      final isActive = lineIndex == activeLineIndex;
      final prevText = _lastSentLines[lineIndex];
      final wasActive = _lastSentActiveLine == lineIndex;

      if (prevText == lineText && isActive == wasActive) {
        continue;
      }

      await _sendLine(lineIndex, lineText, isActive: isActive);
      _lastSentLines[lineIndex] = lineText;
    }

    // Clear stale lines beyond the current visible count.
    final staleKeys = _lastSentLines.keys
        .where((k) => k > visible.length)
        .toList(growable: false);
    for (final key in staleKeys) {
      if (_cancelled) return;
      await _sendLine(key, '', isActive: false);
      _lastSentLines.remove(key);
    }

    _lastSentActiveLine = activeLineIndex;
  }

  // -- Word-boundary text wrapping -----------------------------------------

  /// Wrap [text] into lines of at most [maxChars] characters, breaking at
  /// word boundaries. Pure function, no side effects.
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

  /// Split text into words. Returns an empty list for empty/whitespace text.
  static List<String> _splitWords(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const <String>[];
    return trimmed.split(RegExp(r'\s+'));
  }
}
