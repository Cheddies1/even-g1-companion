import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:even_companion/models/companion_notification.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/features_services.dart';
import 'package:flutter/material.dart';

class NavigateBitmapService {
  NavigateBitmapService._();

  static const _width = 576;
  static const _height = 135;
  static const _widthD = 576.0;
  static const _heightD = 135.0;
  static const _iconBox = 108.0;
  static const _iconInset = 16.0;
  static const _contentLeft = 144.0;
  static const _contentRight = 18.0;
  static const _distanceTop = 18.0;
  static const _contextTop = 60.0;
  static const _metaTop = 100.0;
  static const _fileHeaderSize = 14;
  static const _dibHeaderSize = 40;
  static const _colorTableSize = 8;
  static const _pixelOffset = _fileHeaderSize + _dibHeaderSize + _colorTableSize;

  static NavigateBitmapService? _instance;
  static NavigateBitmapService get get => _instance ??= NavigateBitmapService._();

  Future<void> renderAndSend(CompanionNotification? notification) async {
    final bmpBytes = await _buildBmpBytes(notification);
    final rowBytes = (_width / 8).ceil();
    final paddedRowBytes = ((rowBytes + 3) ~/ 4) * 4;
    final expectedPixelBytes = paddedRowBytes * _height;
    final expectedFileBytes = _pixelOffset + expectedPixelBytes;
    AppLog.debug(
      '${DateTime.now()} render complete -> bytes=${bmpBytes.length}, expectedFileBytes=$expectedFileBytes, expectedPixelBytes=$expectedPixelBytes, width=$_width, height=$_height, bpp=1, iconSource=${notification?.navIconSource ?? ''}',
      tag: 'NavigateBmp',
    );
    await FeaturesServices().sendNavigateBmpData(bmpBytes);
  }

  Future<Uint8List> _buildBmpBytes(CompanionNotification? notification) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, _widthD, _heightD),
    );

    canvas.drawRect(
      const Rect.fromLTWH(0, 0, _widthD, _heightD),
      Paint()..color = Colors.black,
    );

    if (notification == null) {
      _paintText(
        canvas,
        'Start navigation in Google Maps',
        const Offset(24, 42),
        const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w600,
        ),
        maxWidth: _widthD - 48,
        maxLines: 2,
      );
    } else {
      final snapshot = _NavigateCardSnapshot.fromNotification(notification);
      final iconImage = await _decodeNavIcon(notification.navIconPngBase64);

      if (iconImage != null) {
        paintImage(
          canvas: canvas,
          rect: const Rect.fromLTWH(_iconInset, 14, _iconBox, _iconBox),
          image: iconImage,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      } else {
        _paintText(
          canvas,
          'NAV',
          const Offset(28, 44),
          const TextStyle(
            color: Colors.white,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
          maxWidth: 88,
          maxLines: 1,
        );
      }

      _paintText(
        canvas,
        snapshot.distanceLine,
        const Offset(_contentLeft, _distanceTop),
        const TextStyle(
          color: Colors.white,
          fontSize: 36,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
        maxWidth: _widthD - _contentLeft - _contentRight,
        maxLines: 1,
      );
      _paintText(
        canvas,
        snapshot.contextLine,
        const Offset(_contentLeft, _contextTop),
        const TextStyle(
          color: Colors.white,
          fontSize: 25,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
        maxWidth: _widthD - _contentLeft - _contentRight,
        maxLines: 2,
      );
      _paintText(
        canvas,
        snapshot.metaLine,
        const Offset(_contentLeft, _metaTop),
        const TextStyle(
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
        maxWidth: _widthD - _contentLeft - _contentRight,
        maxLines: 1,
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(_width, _height);
    return _encodeMonochromeBmp(image);
  }

  Future<ui.Image?> _decodeNavIcon(String base64Png) async {
    if (base64Png.isEmpty) {
      return null;
    }

    try {
      final bytes = base64Decode(base64Png);
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 108,
        targetHeight: 108,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} icon decode failed -> $e',
        tag: 'NavigateBmp',
      );
      return null;
    }
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
      throw StateError('Failed to read navigate image bytes');
    }
    final rgba = byteData.buffer.asUint8List();
    final rowBytes = (_width / 8).ceil();
    final paddedRowBytes = ((rowBytes + 3) ~/ 4) * 4;
    final pixelBytes = paddedRowBytes * _height;
    final fileSize = _pixelOffset + pixelBytes;
    final out = Uint8List(fileSize);

    out[0] = 0x42;
    out[1] = 0x4D;
    _writeUint32LE(out, 2, fileSize);
    _writeUint32LE(out, 10, _pixelOffset);
    _writeUint32LE(out, 14, _dibHeaderSize);
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

    // Convert RGBA source pixels into a 1bpp, bit-packed BMP payload.
    for (var y = 0; y < _height; y++) {
      final srcY = _height - 1 - y;
      final rowStart = _pixelOffset + (y * paddedRowBytes);
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

class _NavigateCardSnapshot {
  const _NavigateCardSnapshot({
    required this.distanceLine,
    required this.contextLine,
    required this.metaLine,
  });

  final String distanceLine;
  final String contextLine;
  final String metaLine;

  factory _NavigateCardSnapshot.fromNotification(CompanionNotification notification) {
    final distanceLine = _clean(
      notification.navPrimaryInfo.isNotEmpty
          ? notification.navPrimaryInfo
          : notification.navChipExpandedText.isNotEmpty
              ? notification.navChipExpandedText
              : notification.title,
    );
    final contextLine = _clean(
      notification.navSecondaryInfo.isNotEmpty
          ? notification.navSecondaryInfo
          : notification.text.isNotEmpty
              ? notification.text
              : notification.message,
    );
    final metaLine = _clean(
      notification.subText.isNotEmpty ? notification.subText : 'Google Maps',
    );

    return _NavigateCardSnapshot(
      distanceLine: distanceLine.isEmpty ? 'Navigation' : distanceLine,
      contextLine: contextLine.isEmpty ? 'Google Maps' : contextLine,
      metaLine: metaLine,
    );
  }

  static String _clean(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
