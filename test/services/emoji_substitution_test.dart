import 'package:even_companion/services/emoji_substitution.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EmojiSubstitution.apply', () {
    test('single emoji is replaced with its token', () {
      expect(EmojiSubstitution.apply('👍'), '{thumbs up}');
    });

    test('mixed emoji and text preserves the text', () {
      expect(EmojiSubstitution.apply('ok 👍'), 'ok {thumbs up}');
      expect(EmojiSubstitution.apply('great work 🎉🔥'), 'great work {party}{fire}');
    });

    test('multi-codepoint sequences are handled (heart with VS-16)', () {
      // U+2764 U+FE0F — the variation-selector form most apps emit.
      expect(EmojiSubstitution.apply('I ❤️ you'), 'I {heart} you');
      // Bare heart codepoint without VS-16.
      expect(EmojiSubstitution.apply('I ❤ you'), 'I {heart} you');
    });

    test('unknown emoji passes through unchanged', () {
      // U+1F47D alien — not in the V1 map.
      expect(EmojiSubstitution.apply('👽 hello'), '👽 hello');
    });

    test('pure ASCII is untouched', () {
      const input = 'Meeting at 15:00 with Jan';
      expect(EmojiSubstitution.apply(input), same(input));
    });

    test('empty string is untouched', () {
      expect(EmojiSubstitution.apply(''), '');
    });

    test('repeated emoji are all replaced', () {
      expect(EmojiSubstitution.apply('😂😂😂'), '{laugh}{laugh}{laugh}');
    });
  });
}
