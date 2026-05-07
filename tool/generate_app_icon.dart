// One-shot tool script: generates assets/icon/foreground.png
//
// Run from the project root with:
//   flutter test tool/generate_app_icon.dart
//
// Uses dart:ui via the Flutter test binding to draw the eyeglasses glyph with
// Skia anti-aliasing, then writes the result to assets/icon/foreground.png.
//
// Design:
//   - 1024×1024 transparent background
//   - White (#FFFFFF) glyph in the central ~400×250 region (~40% of canvas)
//   - Two open lens rings + horizontal bridge + two short temple arms
//   - Stroke 55 px at 1024 scale (survives down to 48 dp mipmap as ~2-3 px)

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generate eyeglasses icon', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    const double canvasSize = 1024.0;
    const double cx = canvasSize / 2; // horizontal centre: 512
    const double cy = canvasSize / 2; // vertical centre: 512

    // Lens geometry
    // The adaptive-icon safe zone is the central ~576 px (66/108 of 1024).
    // Glyph spans roughly 400 px wide × 250 px tall, well inside safe zone.
    const double lensRadius = 95.0; // outer radius of each ring
    const double strokeWidth = 55.0; // ring/line stroke (open rings, not fills)
    const double lensGap = 30.0; // gap between inner edges of the two lenses
    const double lensOffsetX = lensRadius + lensGap / 2; // 110 px from centre

    const double leftCx = cx - lensOffsetX; // 402
    const double rightCx = cx + lensOffsetX; // 622

    // Temple arms: extend outward from outer edge of each lens, angled
    // slightly upward (-10°) to suggest the arms folding back to the ears.
    const double templeLength = 70.0;
    const double templeAngleRad = -10.0 * math.pi / 180.0;

    final paint = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = ui.StrokeCap.round
      ..isAntiAlias = true;

    // Left lens ring
    canvas.drawCircle(ui.Offset(leftCx, cy), lensRadius, paint);

    // Right lens ring
    canvas.drawCircle(ui.Offset(rightCx, cy), lensRadius, paint);

    // Bridge: short line connecting the inner edges of the two lenses.
    // Sits slightly below vertical centre to mimic a real nose bridge.
    const double bridgeY = cy + 12.0;
    // Overlap the line endpoints slightly into the ring stroke for a clean join.
    final double bridgeLeft = leftCx + lensRadius - strokeWidth * 0.25;
    final double bridgeRight = rightCx - lensRadius + strokeWidth * 0.25;
    canvas.drawLine(
      ui.Offset(bridgeLeft, bridgeY),
      ui.Offset(bridgeRight, bridgeY),
      paint,
    );

    // Left temple arm: starts at the outer edge of the left lens, angles up.
    final double templeStartY = cy - 8.0; // slight offset above centre
    final double dx = templeLength * math.cos(templeAngleRad);
    final double dy = templeLength * math.sin(templeAngleRad);

    canvas.drawLine(
      ui.Offset(leftCx - lensRadius, templeStartY),
      ui.Offset(leftCx - lensRadius - dx, templeStartY + dy),
      paint,
    );

    // Right temple arm: mirror of left
    canvas.drawLine(
      ui.Offset(rightCx + lensRadius, templeStartY),
      ui.Offset(rightCx + lensRadius + dx, templeStartY + dy),
      paint,
    );

    // Render to image and write PNG
    final picture = recorder.endRecording();
    final image = await picture.toImage(1024, 1024);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData == null) {
      fail('toByteData returned null');
    }

    final outputFile = File('assets/icon/foreground.png');
    await outputFile.writeAsBytes(Uint8List.view(byteData.buffer));

    final fileSize = await outputFile.length();
    expect(fileSize, greaterThan(1000),
        reason: 'PNG should be larger than 1 KB');

    // ignore: avoid_print
    print('Written: ${outputFile.path} ($fileSize bytes)');
  });
}
