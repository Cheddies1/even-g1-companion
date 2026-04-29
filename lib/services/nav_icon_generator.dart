import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:demo_ai_even/services/app_log.dart';

// ---------------------------------------------------------------------------
// Manoeuvre classification
// ---------------------------------------------------------------------------

/// Normalised manoeuvre types for direction icon generation.
/// Maps to the firmware's DirectionTurn byte and to a drawn arrow shape.
enum ManoeuvreType {
  straightDot(0x01), // destination marker
  straight(0x02),
  right(0x03),
  left(0x04),
  slightRight(0x05),
  slightLeft(0x06),
  sharpRight(0x07),
  sharpLeft(0x08),
  uTurnLeft(0x09),
  uTurnRight(0x0a),
  merge(0x0b),
  unknown(0x03); // fallback to right (matches captured data)

  const ManoeuvreType(this.directionTurnByte);

  /// The DirectionTurn byte used in the TRIP_STATUS packet.
  final int directionTurnByte;
}

/// Classify a navigation instruction into a [ManoeuvreType].
///
/// Checks [navIconSource] first (the notification icon-extra key name), then
/// falls back to parsing [instructionText] (turnDistance / road name fields)
/// for direction keywords.
ManoeuvreType classifyManoeuvre({
  String navIconSource = '',
  String instructionText = '',
}) {
  // Combine both sources — navIconSource rarely contains direction words
  // (it's usually "android.ongoingActivityNoti.chipIcon"), but instructionText
  // from Google Maps contains "Turn left", "Continue straight", etc.
  final lower = '$navIconSource $instructionText'.toLowerCase();

  return _classifyFromText(lower);
}

/// Legacy single-string entry point used by [Proto._directionTurnForIconSource].
ManoeuvreType manoeuvreFromIconSource(String navIconSource) {
  return _classifyFromText(navIconSource.toLowerCase());
}

ManoeuvreType _classifyFromText(String lower) {
  // U-turn (check before left/right to avoid false matches)
  if (lower.contains('u-turn') || lower.contains('uturn')) {
    if (lower.contains('right')) return ManoeuvreType.uTurnRight;
    return ManoeuvreType.uTurnLeft;
  }

  // Arrive / destination
  if (lower.contains('arrive') || lower.contains('destination')) {
    return ManoeuvreType.straightDot;
  }

  // Sharp turns
  if (lower.contains('sharp')) {
    if (lower.contains('left')) return ManoeuvreType.sharpLeft;
    return ManoeuvreType.sharpRight;
  }

  // Slight turns
  if (lower.contains('slight') || lower.contains('fork')) {
    if (lower.contains('left')) return ManoeuvreType.slightLeft;
    return ManoeuvreType.slightRight;
  }

  // Merge
  if (lower.contains('merge') || lower.contains('ramp')) {
    return ManoeuvreType.merge;
  }

  // Roundabout — treat as the exit direction if determinable, else right
  if (lower.contains('roundabout')) {
    if (lower.contains('left')) return ManoeuvreType.left;
    if (lower.contains('straight')) return ManoeuvreType.straight;
    return ManoeuvreType.right;
  }

  // "Turn left", "Turn right", "Keep left", "Keep right"
  if (lower.contains('left')) return ManoeuvreType.left;
  if (lower.contains('right')) return ManoeuvreType.right;

  // Straight / continue / towards / head / proceed
  if (lower.contains('straight') ||
      lower.contains('continue') ||
      lower.contains('towards') ||
      lower.contains('head') ||
      lower.contains('proceed')) {
    return ManoeuvreType.straight;
  }

  return ManoeuvreType.unknown;
}

// ---------------------------------------------------------------------------
// Icon generation — public API
// ---------------------------------------------------------------------------

/// Pixel dimensions of the MAP_OVERVIEW direction icon.
const int _iconSize = 136;

/// Bytes per pixel row (136 pixels / 8 bits per byte = 17).
const int _bytesPerRow = (_iconSize + 7) ~/ 8; // 17

/// Total raw bytes for a single image layer.
const int _layerBytes = _iconSize * _bytesPerRow; // 2312

/// Max RLE payload per band packet.
const int _bandPayloadMax = 185;

/// The captured MAP_OVERVIEW uses exactly 13 bands. The firmware appears to
/// expect this count — variable band counts cause display position issues.
const int _expectedBandCount = 13;

/// Minimum RLE stream size to guarantee [_expectedBandCount] bands when
/// chunked at [_bandPayloadMax]. (12 full bands + at least 1 byte for band 13)
const int _minRleSize = (_expectedBandCount - 1) * _bandPayloadMax + 1;

/// Packet header size (opcode + length + null + seq + sub-cmd + count + null + bandNum + null).
const int _bandHeaderSize = 9;

/// Generate MAP_OVERVIEW packets for the given [manoeuvre].
///
/// Returns a list of framed `0x0a` packets ready to splice into the replay
/// list, or `null` if generation fails (caller should fall back to captured
/// data).
///
/// [startSeq] is the sequence number for the first band packet; subsequent
/// bands increment from there.
List<Uint8List>? generateMapOverviewPackets(
  ManoeuvreType manoeuvre,
  int startSeq,
) {
  try {
    // 1. Draw icon on a blank canvas.
    final canvas = Uint8List(_layerBytes);
    _drawIcon(canvas, manoeuvre);

    // 2. Build raw buffer: image layer + overlay layer (all zeros).
    final rawBytes = Uint8List(_layerBytes * 2);
    rawBytes.setRange(0, _layerBytes, canvas);
    // overlay remains all-zero — no need to write anything.

    // 3. RLE-encode.
    final rle = _rleEncode(rawBytes);

    // 4. Pad RLE stream to ensure exactly 13 bands.
    //    Append (0x01, 0x00) pairs — each decodes to a single zero byte.
    //    The firmware's RLE decoder stops after filling the image buffer;
    //    extra decoded zeros are discarded harmlessly.
    final Uint8List paddedRle;
    if (rle.length >= _minRleSize) {
      paddedRle = rle;
    } else {
      final padBytes = _minRleSize - rle.length;
      // Ensure even padding (each RLE pair is 2 bytes).
      final padPairs = (padBytes + 1) ~/ 2;
      final padded = Uint8List(rle.length + padPairs * 2);
      padded.setRange(0, rle.length, rle);
      for (int i = 0; i < padPairs; i++) {
        padded[rle.length + i * 2] = 0x01; // count = 1
        padded[rle.length + i * 2 + 1] = 0x00; // byte = 0x00
      }
      paddedRle = padded;
    }

    // 5. Chunk into bands.
    final chunks = <Uint8List>[];
    for (int offset = 0; offset < paddedRle.length; offset += _bandPayloadMax) {
      final end =
          (offset + _bandPayloadMax < paddedRle.length)
              ? offset + _bandPayloadMax
              : paddedRle.length;
      chunks.add(Uint8List.sublistView(paddedRle, offset, end));
    }

    final bandCount = chunks.length;
    if (bandCount < 1 || bandCount > 255) {
      AppLog.error(
        'MAP_OVERVIEW generation: unexpected bandCount=$bandCount for $manoeuvre',
        tag: 'Navigate',
      );
      return null;
    }

    // 5. Frame each chunk into a full packet.
    final packets = <Uint8List>[];
    for (int i = 0; i < bandCount; i++) {
      final chunk = chunks[i];
      final totalLen = _bandHeaderSize + chunk.length;
      final seq = (startSeq + i) & 0xff;
      final bandNum = i + 1; // 1-indexed

      final packet = Uint8List(totalLen);
      packet[0] = 0x0a; // opcode
      packet[1] = totalLen & 0xff; // length byte = total packet length
      packet[2] = 0x00; // null
      packet[3] = seq; // sequence
      packet[4] = 0x02; // MAP_OVERVIEW sub-command
      packet[5] = bandCount & 0xff; // band count
      packet[6] = 0x00; // null
      packet[7] = bandNum & 0xff; // band number (1-indexed)
      packet[8] = 0x00; // trailing null before payload
      packet.setRange(_bandHeaderSize, totalLen, chunk);

      packets.add(packet);
    }

    AppLog.info(
      'MAP_OVERVIEW generated manoeuvre=$manoeuvre bands=$bandCount '
      'rleBytes=${rle.length} paddedRleBytes=${paddedRle.length} '
      'rawBytes=${rawBytes.length}',
      tag: 'Navigate',
    );
    return packets;
  } catch (e) {
    AppLog.error(
      'MAP_OVERVIEW generation failed for $manoeuvre: $e',
      tag: 'Navigate',
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// PNG icon conversion — scrape the Google Maps notification icon
// ---------------------------------------------------------------------------

/// Convert a Google Maps notification icon PNG (base64-encoded) into
/// MAP_OVERVIEW packets. The PNG is decoded, resized to 136×136, converted
/// to monochrome, then RLE-encoded and framed.
///
/// Returns `null` if conversion fails (caller should fall back).
Future<List<Uint8List>?> convertPngToMapOverviewPackets(
  String base64Png,
  int startSeq,
) async {
  if (base64Png.isEmpty) return null;

  try {
    // 1. Decode PNG and resize to 136×136.
    final pngBytes = base64Decode(base64Png);
    final codec = await ui.instantiateImageCodec(
      Uint8List.fromList(pngBytes),
      targetWidth: _iconSize,
      targetHeight: _iconSize,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;

    // 2. Get RGBA pixel data.
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    final rgba = byteData.buffer.asUint8List();

    // 3. Convert RGBA to monochrome bitmap (row-major, LSB-first).
    //    The Google Maps icon is a white arrow on transparent background
    //    (tint=0xffffffff). Use alpha channel to detect foreground:
    //    alpha > 128 → set bit (arrow pixel), else clear (background).
    final canvas = Uint8List(_layerBytes);
    for (int y = 0; y < _iconSize; y++) {
      for (int x = 0; x < _iconSize; x++) {
        final rgbaIndex = (y * _iconSize + x) * 4;
        final a = rgba[rgbaIndex + 3]; // alpha channel
        if (a > 128) {
          final byteIndex = y * _bytesPerRow + (x ~/ 8);
          canvas[byteIndex] |= 1 << (x % 8);
        }
      }
    }

    // 4. Build raw buffer: image + overlay (zeros).
    final rawBytes = Uint8List(_layerBytes * 2);
    rawBytes.setRange(0, _layerBytes, canvas);

    // 5. RLE encode + pad to 13 bands.
    final rle = _rleEncode(rawBytes);
    final Uint8List paddedRle;
    if (rle.length >= _minRleSize) {
      paddedRle = rle;
    } else {
      final padPairs = (_minRleSize - rle.length + 1) ~/ 2;
      final padded = Uint8List(rle.length + padPairs * 2);
      padded.setRange(0, rle.length, rle);
      for (int i = 0; i < padPairs; i++) {
        padded[rle.length + i * 2] = 0x01;
        padded[rle.length + i * 2 + 1] = 0x00;
      }
      paddedRle = padded;
    }

    // 6. Chunk + frame.
    final chunks = <Uint8List>[];
    for (int offset = 0; offset < paddedRle.length; offset += _bandPayloadMax) {
      final end =
          (offset + _bandPayloadMax < paddedRle.length)
              ? offset + _bandPayloadMax
              : paddedRle.length;
      chunks.add(Uint8List.sublistView(paddedRle, offset, end));
    }

    final bandCount = chunks.length;
    if (bandCount < 1 || bandCount > 255) return null;

    final packets = <Uint8List>[];
    for (int i = 0; i < bandCount; i++) {
      final chunk = chunks[i];
      final totalLen = _bandHeaderSize + chunk.length;
      final seq = (startSeq + i) & 0xff;
      final bandNum = i + 1;

      final packet = Uint8List(totalLen);
      packet[0] = 0x0a;
      packet[1] = totalLen & 0xff;
      packet[2] = 0x00;
      packet[3] = seq;
      packet[4] = 0x02; // MAP_OVERVIEW
      packet[5] = bandCount & 0xff;
      packet[6] = 0x00;
      packet[7] = bandNum & 0xff;
      packet[8] = 0x00;
      packet.setRange(_bandHeaderSize, totalLen, chunk);
      packets.add(packet);
    }

    AppLog.info(
      'MAP_OVERVIEW from PNG: bands=$bandCount '
      'rleBytes=${rle.length} paddedRleBytes=${paddedRle.length} '
      'pngInputBytes=${pngBytes.length}',
      tag: 'Navigate',
    );
    return packets;
  } catch (e) {
    AppLog.error(
      'MAP_OVERVIEW PNG conversion failed: $e',
      tag: 'Navigate',
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// RLE codec — simple <count> <byte> pairs, count capped at 255
// ---------------------------------------------------------------------------

Uint8List _rleEncode(Uint8List input) {
  if (input.isEmpty) return Uint8List(0);

  final result = <int>[];
  int currentByte = input[0];
  int count = 1;

  for (int i = 1; i < input.length; i++) {
    if (input[i] == currentByte && count < 255) {
      count++;
    } else {
      result.add(count);
      result.add(currentByte);
      currentByte = input[i];
      count = 1;
    }
  }
  result.add(count);
  result.add(currentByte);

  return Uint8List.fromList(result);
}

// ---------------------------------------------------------------------------
// 136×136 monochrome canvas — row-major, LSB-first bit packing
// ---------------------------------------------------------------------------

/// Set pixel at (x, y) to black. Out-of-bounds calls are silently ignored.
void _setPixel(Uint8List canvas, int x, int y) {
  if (x < 0 || x >= _iconSize || y < 0 || y >= _iconSize) return;
  final byteIndex = y * _bytesPerRow + (x ~/ 8);
  final bitIndex = x % 8; // LSB-first
  canvas[byteIndex] |= (1 << bitIndex);
}

/// Bresenham line from (x0,y0) to (x1,y1).
void _drawLine(Uint8List canvas, int x0, int y0, int x1, int y1) {
  int dx = (x1 - x0).abs();
  int dy = -(y1 - y0).abs();
  int sx = x0 < x1 ? 1 : -1;
  int sy = y0 < y1 ? 1 : -1;
  int err = dx + dy;

  int cx = x0, cy = y0;
  while (true) {
    _setPixel(canvas, cx, cy);
    if (cx == x1 && cy == y1) break;
    int e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      cx += sx;
    }
    if (e2 <= dx) {
      err += dx;
      cy += sy;
    }
  }
}

/// Draw a thick line by drawing parallel lines offset perpendicular to the
/// main line direction.
void _drawThickLine(
  Uint8List canvas,
  int x0,
  int y0,
  int x1,
  int y1,
  int thickness,
) {
  final half = thickness ~/ 2;
  final dx = (x1 - x0).abs();
  final dy = (y1 - y0).abs();

  if (dx >= dy) {
    // More horizontal — offset vertically
    for (int t = -half; t <= half; t++) {
      _drawLine(canvas, x0, y0 + t, x1, y1 + t);
    }
  } else {
    // More vertical — offset horizontally
    for (int t = -half; t <= half; t++) {
      _drawLine(canvas, x0 + t, y0, x1 + t, y1);
    }
  }
}

/// Fill a triangle defined by three vertices using horizontal scanlines.
void _fillTriangle(
  Uint8List canvas,
  int x0,
  int y0,
  int x1,
  int y1,
  int x2,
  int y2,
) {
  // Sort by y.
  if (y0 > y1) {
    int tx = x0, ty = y0;
    x0 = x1;
    y0 = y1;
    x1 = tx;
    y1 = ty;
  }
  if (y0 > y2) {
    int tx = x0, ty = y0;
    x0 = x2;
    y0 = y2;
    x2 = tx;
    y2 = ty;
  }
  if (y1 > y2) {
    int tx = x1, ty = y1;
    x1 = x2;
    y1 = y2;
    x2 = tx;
    y2 = ty;
  }

  for (int y = y0; y <= y2; y++) {
    int xStart, xEnd;

    if (y <= y1) {
      xStart = _edgeX(x0, y0, x2, y2, y);
      xEnd = (y0 == y1) ? x1 : _edgeX(x0, y0, x1, y1, y);
    } else {
      xStart = _edgeX(x0, y0, x2, y2, y);
      xEnd = _edgeX(x1, y1, x2, y2, y);
    }

    if (xStart > xEnd) {
      final tmp = xStart;
      xStart = xEnd;
      xEnd = tmp;
    }

    for (int x = xStart; x <= xEnd; x++) {
      _setPixel(canvas, x, y);
    }
  }
}

/// Interpolate x along an edge from (xa,ya) to (xb,yb) at the given y.
int _edgeX(int xa, int ya, int xb, int yb, int y) {
  if (ya == yb) return xa;
  return xa + ((xb - xa) * (y - ya)) ~/ (yb - ya);
}

/// Fill a circle (solid disc) at (cx, cy) with given radius.
void _fillCircle(Uint8List canvas, int cx, int cy, int radius) {
  for (int dy = -radius; dy <= radius; dy++) {
    final w = _isqrt(radius * radius - dy * dy);
    for (int dx = -w; dx <= w; dx++) {
      _setPixel(canvas, cx + dx, cy + dy);
    }
  }
}

/// Integer square root.
int _isqrt(int n) {
  if (n < 0) return 0;
  int r = 0;
  while ((r + 1) * (r + 1) <= n) {
    r++;
  }
  return r;
}

// ---------------------------------------------------------------------------
// Arrow drawing — one function per manoeuvre shape
// ---------------------------------------------------------------------------

/// Centre of the 136×136 canvas.
const int _cx = _iconSize ~/ 2; // 68
const int _cy = _iconSize ~/ 2; // 68

/// Standard arrow shaft thickness.
const int _shaftThickness = 8;

/// Standard arrowhead size.
const int _headSize = 28;

void _drawIcon(Uint8List canvas, ManoeuvreType manoeuvre) {
  switch (manoeuvre) {
    case ManoeuvreType.straight:
      _drawStraightArrow(canvas);
    case ManoeuvreType.right:
      _drawRightArrow(canvas);
    case ManoeuvreType.left:
      _drawLeftArrow(canvas);
    case ManoeuvreType.slightRight:
    case ManoeuvreType.merge:
      _drawSlightRightArrow(canvas);
    case ManoeuvreType.slightLeft:
      _drawSlightLeftArrow(canvas);
    case ManoeuvreType.sharpRight:
      _drawSharpRightArrow(canvas);
    case ManoeuvreType.sharpLeft:
      _drawSharpLeftArrow(canvas);
    case ManoeuvreType.uTurnLeft:
      _drawUTurnLeftArrow(canvas);
    case ManoeuvreType.uTurnRight:
      _drawUTurnRightArrow(canvas);
    case ManoeuvreType.straightDot:
      _drawStraightDotArrow(canvas);
    case ManoeuvreType.unknown:
      _drawRightArrow(canvas); // fallback matches captured icon
  }
}

// -- Straight ↑ -----------------------------------------------------------

void _drawStraightArrow(Uint8List canvas) {
  // Vertical shaft from bottom to near top.
  _drawThickLine(canvas, _cx, 120, _cx, 40, _shaftThickness);
  // Upward-pointing arrowhead.
  _fillTriangle(canvas, _cx, 10, _cx - _headSize, 50, _cx + _headSize, 50);
}

// -- Right → --------------------------------------------------------------

void _drawRightArrow(Uint8List canvas) {
  // Shaft: up from bottom, then bend right.
  _drawThickLine(canvas, _cx - 20, 120, _cx - 20, _cy, _shaftThickness);
  _drawThickLine(canvas, _cx - 20, _cy, 110, _cy, _shaftThickness);
  // Rounded corner fill.
  _fillCircle(canvas, _cx - 16, _cy, _shaftThickness ~/ 2);
  // Right-pointing arrowhead.
  _fillTriangle(canvas, 126, _cy, 96, _cy - _headSize, 96, _cy + _headSize);
}

// -- Left ← ---------------------------------------------------------------

void _drawLeftArrow(Uint8List canvas) {
  // Shaft: up from bottom, then bend left.
  _drawThickLine(canvas, _cx + 20, 120, _cx + 20, _cy, _shaftThickness);
  _drawThickLine(canvas, _cx + 20, _cy, 26, _cy, _shaftThickness);
  _fillCircle(canvas, _cx + 16, _cy, _shaftThickness ~/ 2);
  // Left-pointing arrowhead.
  _fillTriangle(canvas, 10, _cy, 40, _cy - _headSize, 40, _cy + _headSize);
}

// -- Slight right ↗ -------------------------------------------------------

void _drawSlightRightArrow(Uint8List canvas) {
  // Diagonal shaft from lower-left to upper-right.
  _drawThickLine(canvas, 30, 110, 106, 30, _shaftThickness);
  // Arrowhead pointing upper-right.
  _fillTriangle(canvas, 120, 14, 80, 20, 100, 54);
}

// -- Slight left ↖ --------------------------------------------------------

void _drawSlightLeftArrow(Uint8List canvas) {
  // Mirror of slight right.
  _drawThickLine(canvas, 106, 110, 30, 30, _shaftThickness);
  _fillTriangle(canvas, 16, 14, 56, 20, 36, 54);
}

// -- Sharp right ↘ --------------------------------------------------------

void _drawSharpRightArrow(Uint8List canvas) {
  // Shaft from top-left to lower-right.
  _drawThickLine(canvas, 30, 20, 106, 100, _shaftThickness);
  // Arrowhead pointing lower-right.
  _fillTriangle(canvas, 120, 114, 80, 108, 100, 74);
}

// -- Sharp left ↙ ---------------------------------------------------------

void _drawSharpLeftArrow(Uint8List canvas) {
  // Mirror of sharp right.
  _drawThickLine(canvas, 106, 20, 30, 100, _shaftThickness);
  _fillTriangle(canvas, 16, 114, 56, 108, 36, 74);
}

// -- U-turn left ↩ --------------------------------------------------------

void _drawUTurnLeftArrow(Uint8List canvas) {
  // Right leg (entry): shaft going up.
  _drawThickLine(canvas, _cx + 20, 126, _cx + 20, 40, _shaftThickness);
  // Arc at top connecting right leg to left leg.
  for (int angle = 0; angle <= 180; angle++) {
    final rad = angle * 3.14159265 / 180.0;
    final ax = _cx + (20 * _cos(rad)).round();
    final ay = 40 - (20 * _sin(rad)).round();
    for (int t = -(_shaftThickness ~/ 2); t <= _shaftThickness ~/ 2; t++) {
      _setPixel(canvas, ax, ay + t);
    }
  }
  // Left leg (exit): shaft going down.
  _drawThickLine(canvas, _cx - 20, 40, _cx - 20, 90, _shaftThickness);
  // Downward arrowhead on left leg.
  _fillTriangle(
    canvas,
    _cx - 20,
    120,
    _cx - 20 - _headSize,
    85,
    _cx - 20 + _headSize,
    85,
  );
}

// -- U-turn right (mirror) ------------------------------------------------

void _drawUTurnRightArrow(Uint8List canvas) {
  // Left leg (entry): shaft going up.
  _drawThickLine(canvas, _cx - 20, 126, _cx - 20, 40, _shaftThickness);
  // Arc.
  for (int angle = 0; angle <= 180; angle++) {
    final rad = angle * 3.14159265 / 180.0;
    final ax = _cx - (20 * _cos(rad)).round();
    final ay = 40 - (20 * _sin(rad)).round();
    for (int t = -(_shaftThickness ~/ 2); t <= _shaftThickness ~/ 2; t++) {
      _setPixel(canvas, ax, ay + t);
    }
  }
  // Right leg (exit): shaft going down.
  _drawThickLine(canvas, _cx + 20, 40, _cx + 20, 90, _shaftThickness);
  // Downward arrowhead on right leg.
  _fillTriangle(
    canvas,
    _cx + 20,
    120,
    _cx + 20 - _headSize,
    85,
    _cx + 20 + _headSize,
    85,
  );
}

// -- Straight + dot (arrive / destination) --------------------------------

void _drawStraightDotArrow(Uint8List canvas) {
  // Vertical shaft from bottom to centre.
  _drawThickLine(canvas, _cx, 120, _cx, 55, _shaftThickness);
  // Destination dot at top.
  _fillCircle(canvas, _cx, 30, 16);
}

// -- Trig helpers ---------------------------------------------------------

double _sin(double radians) {
  // Taylor series approximation — sufficient for integer pixel coords.
  double x = radians;
  // Normalise to [-pi, pi].
  while (x > 3.14159265) {
    x -= 6.2831853;
  }
  while (x < -3.14159265) {
    x += 6.2831853;
  }
  final x2 = x * x;
  final x3 = x2 * x;
  final x5 = x3 * x2;
  final x7 = x5 * x2;
  return x - x3 / 6.0 + x5 / 120.0 - x7 / 5040.0;
}

double _cos(double radians) => _sin(radians + 1.5707963);
