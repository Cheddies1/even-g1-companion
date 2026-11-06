import 'dart:convert';
import 'dart:typed_data';

/// Production `0x0a` navigation packet builders, pure and testable.
///
/// Formats are from the 1.66 firmware source and device-proven by the gate A
/// harness (`tool/nav_harness.py`; docs/FINDINGS-nav-marker-tiles.md):
///   INIT         0a <len16> <seq> 00 01
///   TRIP_STATUS  0a <len16> <seq> 01 <dir> <x16> <y16> 5 x NUL-terminated str
///   MAP_OVERVIEW 0a <len16> <seq> 02 <total16> <idx16> <=185 B
///   PANORAMIC    0a <len16> <seq> 03 <total16> <idx16> <flag=0> <=185 B
///   SYNC         0a <len16> <seq> 04 01
///   EXIT         0a <len16> <seq> 05 01
///   ARRIVED      0a <len16> <seq> 06 <status> <prompt, <=63 B>
/// `len16` is the validated little-endian total length; a mismatch is
/// silently dropped. idx is 1-based.
class NavWire {
  static const int chunkBytes = 185;
  static const int shortFieldBytes = 23;
  static const int roadFieldBytes = 63;
  static const int promptBytes = 63;

  /// ARRIVED status 2: "arrived complete" page (prompt + clock, 5 s).
  static const int arrivedComplete = 2;

  int _seq = 0x40;

  int _next() {
    final s = _seq & 0xFF;
    _seq = (_seq + 1) & 0xFF;
    return s;
  }

  static Uint8List frame(List<int> body) {
    final total = 3 + body.length;
    return Uint8List.fromList(
        [0x0A, total & 0xFF, (total >> 8) & 0xFF, ...body]);
  }

  static List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

  Uint8List init() => frame([_next(), 0x00, 0x01]);
  Uint8List sync() => frame([_next(), 0x04, 0x01]);
  Uint8List exit() => frame([_next(), 0x05, 0x01]);

  Uint8List arrived(String prompt, {int status = arrivedComplete}) =>
      frame([_next(), 0x06, status, ..._cut(prompt, promptBytes)]);

  /// TRIP_STATUS. Strings are cut to their byte caps here, so an overlong
  /// field can never abort the whole packet.
  Uint8List tripStatus({
    required int direction,
    required int x,
    required int y,
    String timeRemaining = '',
    String distanceRemaining = '',
    String road = '',
    String turnDistance = '',
    String speed = '',
  }) {
    final strs = <int>[
      ..._cut(timeRemaining, shortFieldBytes), 0,
      ..._cut(distanceRemaining, shortFieldBytes), 0,
      ..._cut(road, roadFieldBytes), 0,
      ..._cut(turnDistance, shortFieldBytes), 0,
      ..._cut(speed, shortFieldBytes), 0,
    ];
    return frame([
      _next(),
      0x01,
      direction & 0xFF,
      ..._le16(x),
      ..._le16(y),
      ...strs,
    ]);
  }

  /// MAP_OVERVIEW packets for the exact wire bytes from the bundle (raw at
  /// 4,624 B, otherwise RLE - the firmware tells them apart by size).
  List<Uint8List> miniMapPackets(Uint8List wire) {
    final chunks = _chunks(wire);
    return [
      for (var i = 0; i < chunks.length; i++)
        frame([
          _next(),
          0x02,
          ..._le16(chunks.length),
          ..._le16(i + 1),
          ...chunks[i],
        ]),
    ];
  }

  /// PANORAMIC_MAP packets (raw only, 16,592 B -> 90 packets).
  List<Uint8List> panoramicPackets(Uint8List wire) {
    final chunks = _chunks(wire);
    return [
      for (var i = 0; i < chunks.length; i++)
        frame([
          _next(),
          0x03,
          ..._le16(chunks.length),
          ..._le16(i + 1),
          0x00,
          ...chunks[i],
        ]),
    ];
  }

  static List<Uint8List> _chunks(Uint8List data) => [
        for (var i = 0; i < data.length; i += chunkBytes)
          Uint8List.sublistView(
              data, i, i + chunkBytes > data.length ? data.length : i + chunkBytes),
      ];

  /// UTF-8 bytes of [s], cut to [max] on a character boundary.
  static List<int> _cut(String s, int max) {
    final b = utf8.encode(s);
    if (b.length <= max) return b;
    var end = max;
    while (end > 0 && (b[end] & 0xC0) == 0x80) {
      end--;
    }
    return b.sublist(0, end);
  }

  /// For acks: is [frame] the firmware's response to the last packet of a map
  /// transfer of type [sub] (2 or 3) with [total] packets?
  static bool isFinalMapAck(Uint8List frame, int sub, int total) {
    if (frame.length < 9 || frame[0] != 0x0A || frame[4] != sub) return false;
    final t = frame[5] | (frame[6] << 8);
    final idx = frame[7] | (frame[8] << 8);
    return t == total && idx == total;
  }

  /// For SYNC replies: byte 5 = 0 means the firmware says nav is not running.
  static bool? syncSaysRunning(Uint8List frame) {
    if (frame.length < 6 || frame[0] != 0x0A || frame[4] != 0x04) return null;
    return frame[5] != 0;
  }
}
