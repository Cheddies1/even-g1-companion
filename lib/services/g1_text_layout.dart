/// Pixel-aware text layout for the G1's firmware-native `0x4E` text renderer.
///
/// Uses a hardcoded per-glyph pixel-width table sourced from MentraOS
/// `G1Text.kt` (~120 glyphs covering ASCII plus a documented set of Latin-1+
/// accented characters that the G1 firmware font renders). For glyphs outside
/// the table a conservative default width is used so unknown characters do not
/// silently overflow the display.
///
/// The G1 display is 488 px wide; standard renders use 5 visible text rows.
/// Wrapping prefers space boundaries; falls back to a character-position split
/// when no space is available within the candidate run.
library;

class G1TextLayout {
  static const int displayWidth = 488;
  static const int linesPerScreen = 5;
  static const int _defaultGlyphWidth = 6;

  static const int _glyphHeight = 26;
  static int get glyphHeight => _glyphHeight;

  /// Width of a single glyph in display pixels (without inter-character
  /// spacing). Inter-character spacing of 1 pixel is added by
  /// [calculateTextWidth] so this returns the bare glyph width.
  static int glyphWidth(int codeUnit) {
    return _glyphWidths[codeUnit] ?? _defaultGlyphWidth;
  }

  /// Pixel width of [text] when rendered by the G1 firmware font, including
  /// 1 px inter-character spacing. Matches the algorithm MentraOS uses to
  /// compute its display-width metric in `G1Text.kt:calculateTextWidth`.
  static int calculateTextWidth(String text) {
    var width = 0;
    for (final codeUnit in text.codeUnits) {
      width += glyphWidth(codeUnit) + 1;
    }
    // The MentraOS algorithm doubles the accumulated width to reach the
    // visible pixel value used in their layout calculations; mirror that.
    return width * 2;
  }

  /// Splits [text] into rendered lines that each fit within [maxDisplayWidth]
  /// pixels. Honours embedded newlines; prefers space boundaries when
  /// wrapping; falls back to a character-position split for runs without a
  /// space. Returns lines trimmed of leading whitespace introduced by wrap.
  static List<String> splitIntoLines(String text, int maxDisplayWidth) {
    final lines = <String>[];
    final processed = _normaliseSymbols(text);

    if (processed.isEmpty || processed == ' ') {
      lines.add(processed);
      return lines;
    }

    for (final rawLine in processed.split('\n')) {
      if (rawLine.isEmpty) {
        lines.add('');
        continue;
      }
      var start = 0;
      final lineLength = rawLine.length;
      while (start < lineLength) {
        final remainingWidth =
            calculateTextWidth(rawLine.substring(start, lineLength));
        if (remainingWidth <= maxDisplayWidth) {
          lines.add(rawLine.substring(start));
          break;
        }

        // Binary search for the longest prefix that fits.
        var left = start + 1;
        var right = lineLength;
        var bestSplit = start + 1;
        while (left <= right) {
          final mid = left + ((right - left) >> 1);
          final width =
              calculateTextWidth(rawLine.substring(start, mid));
          if (width <= maxDisplayWidth) {
            bestSplit = mid;
            left = mid + 1;
          } else {
            right = mid - 1;
          }
        }

        // Prefer breaking at the last space within the candidate run.
        var splitIndex = bestSplit;
        var foundSpace = false;
        for (var i = bestSplit; i > start + 1; i--) {
          if (rawLine[i - 1] == ' ') {
            splitIndex = i;
            foundSpace = true;
            break;
          }
        }
        if (!foundSpace && bestSplit - start <= 2) {
          // Very narrow runs (single-character glyph wider than width):
          // fall through with the binary-search split to make forward progress.
          splitIndex = bestSplit;
        }

        lines.add(rawLine.substring(start, splitIndex).trimRight());
        // Skip leading spaces on the next line — they came from the wrap, not
        // the source text.
        var next = splitIndex;
        while (next < lineLength && rawLine[next] == ' ') {
          next++;
        }
        start = next;
      }
    }

    return lines;
  }

  /// Convenience wrapper: split using the standard G1 display width.
  static List<String> splitForDisplay(String text) =>
      splitIntoLines(text, displayWidth);

  /// Symbols that MentraOS substitutes ahead of wrapping because the G1
  /// firmware font cannot render them. Mirrors `G1Text.kt:52`.
  static String _normaliseSymbols(String input) {
    return input.replaceAll('⬆', '^').replaceAll('⟶', '-');
  }

  /// Per-glyph pixel-width table, sourced from MentraOS
  /// `G1Text.kt:_hardcodedGlyphs`. Keys are Unicode code points; values are
  /// pixel widths from the G1 firmware font. Characters not present here fall
  /// back to [_defaultGlyphWidth].
  static const Map<int, int> _glyphWidths = <int, int>{
    // ASCII printable range
    32: 2, // ' '
    33: 1, // !
    34: 2, // "
    35: 6, // #
    36: 5, // $
    37: 6, // %
    38: 7, // &
    39: 1, // '
    40: 2, // (
    41: 2, // )
    42: 3, // *
    43: 4, // +
    44: 1, // ,
    45: 4, // -
    46: 1, // .
    47: 3, // /
    48: 5, // 0
    49: 3, // 1
    50: 5, // 2
    51: 5, // 3
    52: 5, // 4
    53: 5, // 5
    54: 5, // 6
    55: 5, // 7
    56: 5, // 8
    57: 5, // 9
    58: 1, // :
    59: 1, // ;
    60: 4, // <
    61: 4, // =
    62: 4, // >
    63: 5, // ?
    64: 7, // @
    65: 6, // A
    66: 5, // B
    67: 5, // C
    68: 5, // D
    69: 4, // E
    70: 4, // F
    71: 5, // G
    72: 5, // H
    73: 2, // I
    74: 3, // J
    75: 5, // K
    76: 4, // L
    77: 7, // M
    78: 5, // N
    79: 5, // O
    80: 5, // P
    81: 5, // Q
    82: 5, // R
    83: 5, // S
    84: 5, // T
    85: 5, // U
    86: 6, // V
    87: 7, // W
    88: 6, // X
    89: 6, // Y
    90: 5, // Z
    91: 2, // [
    92: 3, // \
    93: 2, // ]
    94: 4, // ^
    95: 3, // _
    96: 2, // `
    97: 5, // a
    98: 4, // b
    99: 4, // c
    100: 4, // d
    101: 4, // e
    102: 4, // f
    103: 4, // g
    104: 4, // h
    105: 1, // i
    106: 2, // j
    107: 4, // k
    108: 1, // l
    109: 7, // m
    110: 4, // n
    111: 4, // o
    112: 4, // p
    113: 4, // q
    114: 3, // r
    115: 4, // s
    116: 3, // t
    117: 5, // u
    118: 5, // v
    119: 7, // w
    120: 5, // x
    121: 5, // y
    122: 4, // z
    123: 3, // {
    124: 1, // |
    125: 3, // }
    126: 7, // ~
    // Latin-1+ accented characters that the G1 firmware font renders.
    192: 6, // À
    193: 6, // Á
    194: 6, // Â
    196: 6, // Ä
    199: 5, // Ç
    200: 4, // È
    201: 4, // É
    202: 4, // Ê
    203: 4, // Ë
    205: 2, // Í
    206: 3, // Î
    207: 3, // Ï
    209: 5, // Ñ
    211: 5, // Ó
    212: 5, // Ô
    214: 5, // Ö
    217: 5, // Ù
    218: 5, // Ú
    219: 5, // Û
    220: 5, // Ü
    223: 4, // ß
    224: 5, // à
    225: 5, // á
    226: 5, // â
    228: 5, // ä
    231: 4, // ç
    232: 4, // è
    233: 4, // é
    234: 4, // ê
    235: 4, // ë
    237: 2, // í
    238: 3, // î
    239: 3, // ï
    241: 4, // ñ
    243: 4, // ó
    244: 4, // ô
    246: 4, // ö
    249: 5, // ù
    250: 5, // ú
    251: 5, // û
    252: 5, // ü
    255: 5, // ÿ
    376: 6, // Ÿ
    7838: 5, // ẞ
  };
}
