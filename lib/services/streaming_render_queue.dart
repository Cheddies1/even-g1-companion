import 'dart:async';

import 'package:demo_ai_even/services/app_log.dart';

/// Paced display queue for streaming assistant text to the glasses.
///
/// The backend appends raw text chunks via [appendText]. A periodic drain
/// timer reveals 1-2 words at a time and sends only the changed 0x52 lines
/// to the glasses. The queue keeps draining after the backend finishes until
/// all text has been displayed, then fires [onDrained].
class StreamingRenderQueue {
  StreamingRenderQueue({
    required this.maxVisibleLines,
    required this.charsPerLine,
    required List<String> initialCommittedLines,
    required Future<void> Function(int line, String text, {required bool isActive}) sendLine,
    required void Function() onDrained,
  })  : _committedLines = List<String>.from(initialCommittedLines),
        _sendLine = sendLine,
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
  List<String> _committedLines;
  final StringBuffer _targetText = StringBuffer();
  int _displayedWordCount = 0;
  List<String> _displayedWrappedLines = const <String>[];
  final Map<int, String> _lastSentLines = <int, String>{};
  int? _lastSentActiveIndex;
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
      '${DateTime.now()} render queue: chunk received chars=${chunk.length}',
      tag: 'Chat',
    );
    _ensureDrainTimer();
  }

  /// Signal that the backend stream has ended. The queue keeps draining
  /// until all target text is displayed.
  void markBackendComplete() {
    if (_cancelled) return;
    _backendComplete = true;
    AppLog.info(
      '${DateTime.now()} render queue: backend complete, target len=${_targetText.length}',
      tag: 'Chat',
    );
    _ensureDrainTimer();
  }

  /// Update the committed-lines prefix (e.g. when a user turn scrolls in).
  void updateCommittedLines(List<String> lines) {
    _committedLines = List<String>.from(lines);
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
    } finally {
      _sendingInProgress = false;
    }
  }

  Future<void> _advanceAndSend() async {
    final target = _targetText.toString();
    final targetWords = _splitWords(target);
    final wordsAvailable = targetWords.length;

    if (_displayedWordCount >= wordsAvailable && !_backendComplete) {
      // Waiting for more text from the backend.
      return;
    }

    // Advance by up to wordsPerTick words.
    final newWordCount = (_displayedWordCount + wordsPerTick)
        .clamp(0, wordsAvailable);

    if (newWordCount > _displayedWordCount) {
      _displayedWordCount = newWordCount;
      final displayedText = targetWords.sublist(0, _displayedWordCount).join(' ');
      _displayedWrappedLines = wrapText('G1: $displayedText', charsPerLine);
      AppLog.info(
        '${DateTime.now()} render queue: tick words=$_displayedWordCount '
        'activeLineLen=${_displayedWrappedLines.isNotEmpty ? _displayedWrappedLines.last.length : 0}',
        tag: 'Chat',
      );
    }

    // Compute visible window.
    final combined = <String>[
      ..._committedLines,
      ..._displayedWrappedLines,
    ];
    final visible = combined.length <= maxVisibleLines
        ? combined
        : combined.sublist(combined.length - maxVisibleLines);

    final activeLineIndex = visible.isNotEmpty ? visible.length : null;

    // Send only changed lines.
    await _sendDirtyLines(visible, activeLineIndex);

    // Check drain-complete condition.
    if (_backendComplete &&
        _displayedWordCount >= wordsAvailable &&
        !_drainedFired) {
      // Ensure the final full text is displayed (catch any trailing
      // characters that don't form a complete word).
      final fullDisplayedText = target.trim();
      if (fullDisplayedText.isNotEmpty) {
        _displayedWrappedLines = wrapText('G1: $fullDisplayedText', charsPerLine);
        final finalCombined = <String>[
          ..._committedLines,
          ..._displayedWrappedLines,
        ];
        final finalVisible = finalCombined.length <= maxVisibleLines
            ? finalCombined
            : finalCombined.sublist(finalCombined.length - maxVisibleLines);
        await _sendDirtyLines(finalVisible, finalVisible.isNotEmpty ? finalVisible.length : null);
      }

      _drainedFired = true;
      _drainTimer?.cancel();
      _drainTimer = null;
      AppLog.info(
        '${DateTime.now()} render queue: display complete, '
        'words=$_displayedWordCount lines=${_displayedWrappedLines.length}',
        tag: 'Chat',
      );
      if (!_cancelled) {
        _onDrained();
      }
    }
  }

  Future<void> _sendDirtyLines(
    List<String> visible,
    int? activeLineIndex,
  ) async {
    for (int i = 0; i < visible.length; i++) {
      if (_cancelled) return;
      final lineIndex = i + 1; // 1-based for 0x52 protocol
      final lineText = visible[i];
      final isActive = activeLineIndex != null && lineIndex == activeLineIndex;
      final previousText = _lastSentLines[lineIndex];
      final previousActive = _lastSentActiveIndex;

      // Skip unchanged lines.
      if (previousText == lineText &&
          ((isActive && previousActive == activeLineIndex) ||
           (!isActive && previousActive != lineIndex))) {
        continue;
      }

      await _sendLine(lineIndex, lineText, isActive: isActive);
      _lastSentLines[lineIndex] = lineText;
    }

    // Clear lines that are no longer in the visible window.
    final staleKeys = _lastSentLines.keys
        .where((k) => k > visible.length)
        .toList(growable: false);
    for (final key in staleKeys) {
      if (_cancelled) return;
      await _sendLine(key, '', isActive: false);
      _lastSentLines.remove(key);
    }

    _lastSentActiveIndex = activeLineIndex;
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
