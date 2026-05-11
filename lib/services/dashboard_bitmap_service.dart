import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/dashboard_service.dart';
import 'package:even_companion/services/features_services.dart';
import 'package:flutter/material.dart';

class DashboardBitmapService {
  DashboardBitmapService._();

  static const _width = 576;
  static const _height = 135;
  static const _widthD = 576.0;
  static const _heightD = 135.0;
  static const _dividerX = 212.0;
  static const _topInset = 10.0;
  static const _leftInset = 20.0;
  static const _rightInset = 18.0;

  static DashboardBitmapService? _instance;
  static DashboardBitmapService get get =>
      _instance ??= DashboardBitmapService._();

  final Map<String, Uint8List> _bmpCache = {};

  Future<void> primeCache({
    required DateTime now,
    required List<DashboardNotification> notifications,
  }) async {
    _bmpCache.clear();
    if (notifications.isEmpty) {
      final bmpBytes = await _buildBmpBytes(now: now, notification: null);
      _bmpCache[_cacheKey(now, null)] = bmpBytes;
      return;
    }

    for (final notification in notifications) {
      final bmpBytes =
          await _buildBmpBytes(now: now, notification: notification);
      _bmpCache[_cacheKey(now, notification)] = bmpBytes;
    }
  }

  Future<void> renderAndSend({
    required DateTime now,
    required DashboardNotification? notification,
  }) async {
    final cacheKey = _cacheKey(now, notification);
    final bmpBytes =
        _bmpCache[cacheKey] ?? await _buildBmpBytes(now: now, notification: notification);
    AppLog.debug(
      '${DateTime.now()} render complete -> bytes=${bmpBytes.length}, source=${notification?.source ?? 'Notifications'}',
      tag: 'DashboardBmp',
    );
    await FeaturesServices().sendBmpData(bmpBytes);
  }

  Future<Uint8List> _buildBmpBytes({
    required DateTime now,
    required DashboardNotification? notification,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, _widthD, _heightD),
    );

    canvas.drawRect(
      const Rect.fromLTWH(0, 0, _widthD, _heightD),
      Paint()..color = Colors.black,
    );

    final dividerPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(
      const Offset(_dividerX, 20),
      const Offset(_dividerX, _height - 12),
      dividerPaint,
    );

    final timeString =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    _paintText(
      canvas,
      'Time',
      const Offset(_leftInset, _topInset + 6),
      const TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w500,
      ),
      maxWidth: _dividerX - 36,
    );
    _paintText(
      canvas,
      timeString,
      const Offset(_leftInset, _topInset + 28),
      const TextStyle(
        color: Colors.white,
        fontSize: 42,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
      maxWidth: _dividerX - 36,
    );
    _paintText(
      canvas,
      'Next: No calendar sync yet',
      const Offset(_leftInset, _topInset + 88),
      const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w400,
      ),
      maxWidth: _dividerX - 36,
      maxLines: 2,
    );

    final source = notification?.source ?? 'Notifications';
    final message = notification?.message ?? 'No notifications';
    _paintText(
      canvas,
      source,
      const Offset(_dividerX + _rightInset, _topInset + 12),
      const TextStyle(
        color: Colors.white,
        fontSize: 24,
        fontWeight: FontWeight.w700,
      ),
      maxWidth: _width - _dividerX - 30,
      maxLines: 1,
    );
    _paintText(
      canvas,
      message,
      const Offset(_dividerX + _rightInset, _topInset + 44),
      const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w400,
        height: 1.2,
      ),
      maxWidth: _width - _dividerX - 30,
      maxLines: 3,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(_width, _height);
    return _encodeMonochromeBmp(image);
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    required double maxWidth,
    int? maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
  }

  Future<Uint8List> _encodeMonochromeBmp(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      throw StateError('Failed to read dashboard image bytes');
    }
    final rgba = byteData.buffer.asUint8List();
    final rowBytes = (_width / 8).ceil();
    final paddedRowBytes = ((rowBytes + 3) ~/ 4) * 4;
    final pixelBytes = paddedRowBytes * _height;
    const fileHeaderSize = 14;
    const dibHeaderSize = 40;
    const colorTableSize = 8;
    const pixelOffset = fileHeaderSize + dibHeaderSize + colorTableSize;
    final fileSize = pixelOffset + pixelBytes;
    final out = Uint8List(fileSize);

    out[0] = 0x42;
    out[1] = 0x4D;
    _writeUint32LE(out, 2, fileSize);
    _writeUint32LE(out, 10, pixelOffset);
    _writeUint32LE(out, 14, dibHeaderSize);
    _writeUint32LE(out, 18, _width);
    _writeUint32LE(out, 22, _height);
    _writeUint16LE(out, 26, 1);
    _writeUint16LE(out, 28, 1);
    _writeUint32LE(out, 34, pixelBytes);
    _writeUint32LE(out, 38, 2835);
    _writeUint32LE(out, 42, 2835);
    _writeUint32LE(out, 46, 2);
    _writeUint32LE(out, 50, 2);

    out.setRange(54, 58, [0x00, 0x00, 0x00, 0x00]);
    out.setRange(58, 62, [0xFF, 0xFF, 0xFF, 0x00]);

    for (var y = 0; y < _height; y++) {
      final srcY = _height - 1 - y;
      final rowStart = pixelOffset + (y * paddedRowBytes);
      for (var x = 0; x < _width; x++) {
        final rgbaIndex = (srcY * _width + x) * 4;
        final r = rgba[rgbaIndex];
        final g = rgba[rgbaIndex + 1];
        final b = rgba[rgbaIndex + 2];
        final luminance = ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
        final isBlack = luminance < 200;
        if (isBlack) {
          final byteIndex = rowStart + (x ~/ 8);
          out[byteIndex] |= 1 << (7 - (x % 8));
        }
      }
    }

    return out;
  }

  String _cacheKey(DateTime now, DashboardNotification? notification) {
    final minuteKey =
        '${now.year}-${now.month}-${now.day}-${now.hour}-${now.minute}';
    if (notification == null) {
      return '$minuteKey::empty';
    }
    return '$minuteKey::${notification.source}::${notification.message}';
  }

  void _writeUint16LE(Uint8List buffer, int offset, int value) {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
  }

  void _writeUint32LE(Uint8List buffer, int offset, int value) {
    buffer[offset] = value & 0xFF;
    buffer[offset + 1] = (value >> 8) & 0xFF;
    buffer[offset + 2] = (value >> 16) & 0xFF;
    buffer[offset + 3] = (value >> 24) & 0xFF;
  }
}
