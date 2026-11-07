import 'dart:typed_data';

import 'package:even_companion/services/nav_card_session.dart';
import 'package:even_companion/services/nav_manoeuvre.dart';
import 'package:even_companion/services/walknav/nav_wire.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('blank mini-map is RLE that decodes to 4,624 zero bytes', () {
    final rle = NavCardSession.blankMiniMap;
    expect(rle.length, isNot(4624)); // exactly 4,624 B would be read as raw
    var n = 0;
    for (var i = 0; i < rle.length; i += 2) {
      expect(rle[i + 1], 0);
      n += rle[i];
    }
    expect(n, 4624);
    expect(NavWire().miniMapPackets(rle), hasLength(1));
  });

  test('blank panoramic map is raw and 90 packets', () {
    expect(NavCardSession.blankPanoramic, hasLength(16592));
    expect(NavWire().panoramicPackets(NavCardSession.blankPanoramic),
        hasLength(90));
  });

  test('SYNC echo byte 5 is the running flag', () {
    expect(NavWire.syncSaysRunning(Uint8List.fromList([0x0a, 6, 0, 9, 4, 1])),
        isTrue);
    expect(NavWire.syncSaysRunning(Uint8List.fromList([0x0a, 6, 0, 9, 4, 0])),
        isFalse);
    expect(NavWire.syncSaysRunning(Uint8List.fromList([0x0a, 6, 0, 9, 0, 0])),
        isNull);
  });

  test('Maps instructions map to built-in arrows', () {
    int dir(String t) =>
        classifyManoeuvre(instructionText: t).directionTurnByte;
    expect(dir('Turn left onto Church Road'), 0x04);
    expect(dir('Slight right'), 0x05);
    expect(dir('Make a U-turn'), 0x09);
    expect(dir('46 m'), 0x02);
  });
}
