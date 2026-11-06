import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:even_companion/services/walknav/nav_geo.dart';

/// A cartographer trip bundle (docs/cartographer-contract.md, `/v1/route`).
/// Parsed and validated once; everything the navigator needs is in here, so a
/// cached bundle keeps working with Tailscale down.

class NavBundleException implements Exception {
  NavBundleException(this.message);
  final String message;
  @override
  String toString() => 'NavBundleException: $message';
}

class NavManeuver {
  const NavManeuver({
    required this.progressM,
    required this.instruction,
    required this.streetName,
    required this.direction,
    required this.engineType,
  });

  final double progressM;
  final String instruction;
  final String streetName;

  /// Firmware arrow value (1..0x23).
  final int direction;

  /// Valhalla manoeuvre type, for filtering decisions.
  final int engineType;

  static const int typeStart = 1;
  static const int typeStartRight = 2;
  static const int typeStartLeft = 3;
  static const int typeDestination = 4;
  static const int typeDestinationRight = 5;
  static const int typeDestinationLeft = 6;
  static const int typeRoundaboutEnter = 26;
  static const int typeRoundaboutExit = 27;

  bool get isStart =>
      engineType == typeStart ||
      engineType == typeStartRight ||
      engineType == typeStartLeft;
  bool get isArrival =>
      engineType == typeDestination ||
      engineType == typeDestinationRight ||
      engineType == typeDestinationLeft;
  bool get isRoundabout =>
      engineType == typeRoundaboutEnter || engineType == typeRoundaboutExit;
}

class NavBitmap {
  const NavBitmap({
    required this.width,
    required this.height,
    required this.encoding,
    required this.wire,
    required this.rawBytes,
  });

  final int width;
  final int height;

  /// `raw` or `rle`.
  final String encoding;

  /// The exact bytes to send to the glasses.
  final Uint8List wire;

  /// Decoded size (16,592 panoramic, 4,624 mini-map).
  final int rawBytes;
}

class NavTile {
  const NavTile({
    required this.id,
    required this.startM,
    required this.endM,
    required this.panoramic,
    required this.miniMap,
    required this.transform,
  });

  final String id;
  final double startM;
  final double endM;
  final NavBitmap panoramic;
  final NavBitmap miniMap;
  final MarkerTransform transform;

  bool contains(double progressM) => progressM >= startM && progressM <= endM;
}

class NavBundle {
  NavBundle._({
    required this.bundleId,
    required this.version,
    required this.route,
    required this.maneuvers,
    required this.tiles,
    required this.attribution,
  });

  final String bundleId;
  final String version;
  final RouteLine route;
  final List<NavManeuver> maneuvers;
  final List<NavTile> tiles;
  final String attribution;

  double get totalM => route.totalM;

  static const int panoramicRawBytes = 16592;
  static const int miniMapRawBytes = 4624;

  /// Parse and fully validate a `/v1/route` response. Throws
  /// [NavBundleException] on anything that would fail on the glasses.
  static NavBundle parse(String jsonText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw NavBundleException('not JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw NavBundleException('not a JSON object');
    }
    final j = decoded;
    final version = _str(j, 'version');
    if (!version.startsWith('1.')) {
      throw NavBundleException('unsupported bundle version $version');
    }
    if (j['coordinate_order'] != 'lat,lon') {
      throw NavBundleException('unexpected coordinate order');
    }
    final poly = (j['polyline'] as List?) ?? const [];
    final points = <LatLon>[];
    for (final p in poly) {
      if (p is! List || p.length != 2) {
        throw NavBundleException('bad polyline point');
      }
      points.add(LatLon((p[0] as num).toDouble(), (p[1] as num).toDouble()));
    }
    if (points.length < 2) throw NavBundleException('polyline too short');
    final route = RouteLine(points);

    final maneuvers = <NavManeuver>[];
    for (final m in (j['maneuvers'] as List? ?? const [])) {
      final mm = m as Map<String, dynamic>;
      final direction = (mm['direction'] as num).toInt();
      if (direction < 1 || direction > 0x23) {
        throw NavBundleException('arrow $direction out of range');
      }
      maneuvers.add(NavManeuver(
        progressM: (mm['progress_m'] as num).toDouble(),
        instruction: (mm['instruction'] as String?) ?? '',
        streetName: (mm['street_name'] as String?) ?? '',
        direction: direction,
        engineType: (mm['engine_type'] as num?)?.toInt() ?? 0,
      ));
    }

    final tiles = <NavTile>[];
    for (final t in (j['tiles'] as List? ?? const [])) {
      final tt = t as Map<String, dynamic>;
      final mt = tt['marker_transform'] as Map<String, dynamic>;
      final origin = mt['projection_origin_lat_lon'] as List;
      final offset = mt['pixel_offset'] as List;
      final clamp = mt['clamp'] as Map<String, dynamic>?;
      (int, int) pair(Object? v, (int, int) dflt) {
        if (v is List && v.length == 2) {
          return ((v[0] as num).toInt(), (v[1] as num).toInt());
        }
        return dflt;
      }

      tiles.add(NavTile(
        id: _str(tt, 'id'),
        startM: (tt['progress_start_m'] as num).toDouble(),
        endM: (tt['progress_end_m'] as num).toDouble(),
        panoramic: _bitmap(tt['panoramic'], 488, 136, panoramicRawBytes,
            allowRle: false),
        miniMap: _bitmap(tt['mini_map'], 136, 136, miniMapRawBytes,
            allowRle: true),
        transform: MarkerTransform(
          origin: LatLon((origin[0] as num).toDouble(),
              (origin[1] as num).toDouble()),
          orientationDeg: (mt['orientation_deg'] as num).toDouble(),
          metresPerPixel: (mt['metres_per_pixel'] as num).toDouble(),
          offsetX: (offset[0] as num).toDouble(),
          offsetY: (offset[1] as num).toDouble(),
          earthRadiusM:
              (mt['earth_radius_m'] as num?)?.toDouble() ?? kEarthRadiusM,
          clampX: pair(clamp?['x'], (6, 482)),
          clampY: pair(clamp?['y'], (6, 130)),
        ),
      ));
    }
    if (tiles.isEmpty) throw NavBundleException('no tiles');
    for (var i = 0; i < tiles.length; i++) {
      final t = tiles[i];
      if (t.endM <= t.startM) throw NavBundleException('empty tile ${t.id}');
      if (i == 0 && t.startM > 0.5) {
        throw NavBundleException('first tile does not start at 0');
      }
      if (i > 0 && t.startM > tiles[i - 1].endM) {
        throw NavBundleException('gap before tile ${t.id}');
      }
    }
    if (tiles.last.endM < route.totalM - 0.5) {
      throw NavBundleException('tiles do not reach the end of the route');
    }

    return NavBundle._(
      bundleId: _str(j, 'bundle_id'),
      version: version,
      route: route,
      maneuvers: List.unmodifiable(maneuvers),
      tiles: List.unmodifiable(tiles),
      attribution: (j['attribution'] as String?) ?? '',
    );
  }

  static String _str(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v is! String || v.isEmpty) throw NavBundleException('missing $key');
    return v;
  }

  static NavBitmap _bitmap(
    Object? raw,
    int width,
    int height,
    int rawBytes, {
    required bool allowRle,
  }) {
    if (raw is! Map<String, dynamic>) {
      throw NavBundleException('missing bitmap');
    }
    if (raw['width'] != width || raw['height'] != height) {
      throw NavBundleException('bitmap is not ${width}x$height');
    }
    final encoding = raw['encoding'] as String?;
    if (encoding != 'raw' && !(allowRle && encoding == 'rle')) {
      throw NavBundleException('bitmap encoding $encoding not allowed');
    }
    final wire = base64Decode(raw['data_base64'] as String);
    if (wire.length != (raw['wire_bytes'] as num).toInt()) {
      throw NavBundleException('bitmap wire size mismatch');
    }
    final sha = sha256.convert(wire).toString();
    if (sha != raw['sha256']) {
      throw NavBundleException('bitmap sha256 mismatch');
    }
    final decoded = encoding == 'raw' ? wire : rleDecode(wire);
    if (decoded.length != rawBytes) {
      throw NavBundleException(
          'bitmap decodes to ${decoded.length} B, expected $rawBytes');
    }
    if (encoding == 'raw' && rawBytes == miniMapRawBytes) {
      // Exactly 4,624 B is what tells the firmware "raw".
    } else if (encoding == 'rle' && wire.length == miniMapRawBytes) {
      throw NavBundleException('RLE mini-map would be read as raw');
    }
    final rawSha = raw['raw_sha256'];
    if (rawSha is String && sha256.convert(decoded).toString() != rawSha) {
      throw NavBundleException('bitmap raw_sha256 mismatch');
    }
    return NavBitmap(
      width: width,
      height: height,
      encoding: encoding!,
      wire: wire,
      rawBytes: rawBytes,
    );
  }
}

/// `<count><value>` pairs, the mini-map RLE the firmware decodes.
Uint8List rleDecode(Uint8List data) {
  if (data.length.isOdd) throw NavBundleException('odd-length RLE');
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < data.length; i += 2) {
    final count = data[i];
    if (count == 0) throw NavBundleException('zero RLE run');
    out.add(Uint8List(count)..fillRange(0, count, data[i + 1]));
  }
  return out.toBytes();
}
