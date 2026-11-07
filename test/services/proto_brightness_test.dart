import 'package:even_companion/services/proto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('auto on sends level 0 whatever the manual level', () {
    expect(Proto.brightnessPayload(42, true), [0x01, 0x00, 0x01]);
    expect(Proto.brightnessPayload(20, true), [0x01, 0x00, 0x01]);
  });

  test('auto off sends the manual level, clamped', () {
    expect(Proto.brightnessPayload(20, false), [0x01, 20, 0x00]);
    expect(Proto.brightnessPayload(99, false), [0x01, 42, 0x00]);
    expect(Proto.brightnessPayload(-3, false), [0x01, 0, 0x00]);
  });
}
