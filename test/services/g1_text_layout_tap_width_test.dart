import 'package:even_companion/services/g1_text_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Even AI (tap surface) layout wraps narrower than full width', () {
    const text = 'Messages  -  12:34 a fairly long line of notification text';
    final full = G1TextLayout.splitIntoLines(text, G1TextLayout.displayWidth);
    final narrow =
        G1TextLayout.splitIntoLines(text, G1TextLayout.evenAiLayoutWidth);
    expect(narrow.length, greaterThanOrEqualTo(full.length));
    for (final line in narrow) {
      expect(
        G1TextLayout.calculateTextWidth(line),
        lessThanOrEqualTo(G1TextLayout.evenAiLayoutWidth),
      );
    }
  });

  test('evenAiLayoutWidth is the 472/576 share of the full-width budget', () {
    expect(
      G1TextLayout.evenAiLayoutWidth,
      (G1TextLayout.displayWidth * 472 / 576).round(),
    );
  });
}
