/// Replaces emoji glyphs with bracketed ASCII tokens (e.g. `👍` → `{thumbs up}`)
/// so notifications remain readable on the G1, whose font has no emoji glyphs
/// and renders unknown codepoints as blanks.
///
/// Applied at notification ingest (`CompanionNotification.fromMap`) so all
/// downstream renders, truncation, and BLE chunking see the substituted text.
class EmojiSubstitution {
  EmojiSubstitution._();

  // Multi-codepoint sequences (with VS-16 / ZWJ) are listed before their
  // single-codepoint fallbacks so longest-match substitution wins.
  static const Map<String, String> _map = {
    '👍': '{thumbs up}',
    '👎': '{thumbs down}',
    '❤️': '{heart}',
    '❤': '{heart}',
    '😀': '{smile}',
    '😃': '{smile}',
    '😄': '{smile}',
    '😊': '{smile}',
    '😍': '{love}',
    '😂': '{laugh}',
    '🤣': '{laugh}',
    '😢': '{sad}',
    '😭': '{crying}',
    '🙏': '{pray}',
    '🔥': '{fire}',
    '🎉': '{party}',
    '✅': '{check}',
    '✔️': '{check}',
    '❌': '{x}',
    '⭐': '{star}',
    '⭐️': '{star}',
    '💯': '{100}',
    '🤔': '{thinking}',
    '👋': '{wave}',
    '🙄': '{eye roll}',
    '😉': '{wink}',
    '😘': '{kiss}',
  };

  // Pre-sorted keys, longest first, so multi-codepoint sequences match before
  // their single-codepoint prefixes (e.g. `❤️` before `❤`).
  static final List<String> _keysLongestFirst = _map.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  /// Returns [input] with known emoji glyphs replaced by ASCII tokens.
  /// Unknown emoji pass through unchanged; ASCII input is untouched.
  static String apply(String input) {
    if (input.isEmpty) return input;
    var out = input;
    for (final key in _keysLongestFirst) {
      if (out.contains(key)) {
        out = out.replaceAll(key, _map[key]!);
      }
    }
    return out;
  }
}
