import 'dart:math' as math;

/// Geometry for walking navigation, matching cartographer's maths exactly
/// (docs/cartographer-contract.md, "Tiles and marker transform"): local
/// tangent-plane distances, linear interpolation in lat/lon, and the marker
/// projection. Pure, no IO.

const double kEarthRadiusM = 6371008.8;

double _rad(double deg) => deg * math.pi / 180.0;
double _deg(double rad) => rad * 180.0 / math.pi;

class LatLon {
  const LatLon(this.lat, this.lon);
  final double lat;
  final double lon;

  @override
  String toString() => 'LatLon($lat, $lon)';
}

/// Segment distance as cartographer computes it: tangent plane at [a].
double segmentDistanceM(LatLon a, LatLon b) {
  final east =
      kEarthRadiusM * _rad(b.lon - a.lon) * math.cos(_rad(a.lat));
  final north = kEarthRadiusM * _rad(b.lat - a.lat);
  return math.sqrt(east * east + north * north);
}

/// East/north metres of [p] relative to [origin] (tangent plane at origin).
(double east, double north) toLocalMetres(LatLon origin, LatLon p) {
  final east =
      kEarthRadiusM * _rad(p.lon - origin.lon) * math.cos(_rad(origin.lat));
  final north = kEarthRadiusM * _rad(p.lat - origin.lat);
  return (east, north);
}

/// Bearing in degrees clockwise from true north, from [a] to [b].
double bearingDeg(LatLon a, LatLon b) {
  final (east, north) = toLocalMetres(a, b);
  return (_deg(math.atan2(east, north)) + 360.0) % 360.0;
}

/// Signed smallest difference `to - from` in degrees, in (-180, 180].
double headingDelta(double from, double to) {
  var d = (to - from + 180.0) % 360.0;
  if (d < 0) d += 360.0;
  return d - 180.0;
}

/// Result of projecting a point onto a polyline.
class PolylineMatch {
  const PolylineMatch({
    required this.progressM,
    required this.distanceM,
    required this.segment,
  });

  /// Distance along the route of the closest point.
  final double progressM;

  /// Perpendicular (or end-point) distance from the point to the route.
  final double distanceM;

  /// Index of the segment the closest point lies on.
  final int segment;
}

/// A route polyline with cumulative distances, as cartographer measures them.
class RouteLine {
  RouteLine(List<LatLon> points)
      : points = List<LatLon>.unmodifiable(points),
        cumulativeM = _cumulative(points) {
    if (points.length < 2) {
      throw ArgumentError('route needs at least two points');
    }
  }

  final List<LatLon> points;
  final List<double> cumulativeM;

  double get totalM => cumulativeM.last;

  static List<double> _cumulative(List<LatLon> pts) {
    final out = <double>[0.0];
    for (var i = 1; i < pts.length; i++) {
      out.add(out.last + segmentDistanceM(pts[i - 1], pts[i]));
    }
    return List<double>.unmodifiable(out);
  }

  /// Position at route progress [s] metres, clamped to the route.
  LatLon pointAt(double s) {
    if (s <= 0) return points.first;
    if (s >= totalM) return points.last;
    var lo = 0;
    var hi = cumulativeM.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cumulativeM[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final len = cumulativeM[hi] - cumulativeM[lo];
    final f = len <= 0 ? 0.0 : (s - cumulativeM[lo]) / len;
    final a = points[lo];
    final b = points[hi];
    return LatLon(a.lat + f * (b.lat - a.lat), a.lon + f * (b.lon - a.lon));
  }

  /// Heading of travel along the route between progress [s0] and [s1].
  double headingBetween(double s0, double s1) =>
      bearingDeg(pointAt(s0), pointAt(s1));

  /// Closest point on the route to [p], searching only segments that overlap
  /// progress [fromM]..[toM] (whole route when omitted).
  PolylineMatch? match(LatLon p, {double? fromM, double? toM}) {
    final lo = fromM ?? 0.0;
    final hi = toM ?? totalM;
    PolylineMatch? best;
    for (var i = 0; i < points.length - 1; i++) {
      final s0 = cumulativeM[i];
      final s1 = cumulativeM[i + 1];
      if (s1 < lo || s0 > hi) continue;
      final a = points[i];
      // Project in the tangent plane at the segment start.
      final (bx, by) = toLocalMetres(a, points[i + 1]);
      final (px, py) = toLocalMetres(a, p);
      final len2 = bx * bx + by * by;
      var t = len2 <= 0 ? 0.0 : (px * bx + py * by) / len2;
      // Keep the projected point inside both the segment and the search
      // window, and measure the distance to that clamped point.
      final segLen = s1 - s0;
      final tMin = segLen <= 0 ? 0.0 : ((lo - s0) / segLen).clamp(0.0, 1.0);
      final tMax = segLen <= 0 ? 1.0 : ((hi - s0) / segLen).clamp(0.0, 1.0);
      t = t.clamp(tMin, tMax).toDouble();
      final dx = px - t * bx;
      final dy = py - t * by;
      final dist = math.sqrt(dx * dx + dy * dy);
      final progress = s0 + t * segLen;
      if (best == null || dist < best.distanceM) {
        best = PolylineMatch(progressM: progress, distanceM: dist, segment: i);
      }
    }
    return best;
  }
}

/// Cartographer's per-tile marker transform (contract: `marker_transform`).
class MarkerTransform {
  const MarkerTransform({
    required this.origin,
    required this.orientationDeg,
    required this.metresPerPixel,
    required this.offsetX,
    required this.offsetY,
    this.earthRadiusM = kEarthRadiusM,
    this.clampX = const (6, 482),
    this.clampY = const (6, 130),
  });

  final LatLon origin;
  final double orientationDeg;
  final double metresPerPixel;
  final double offsetX;
  final double offsetY;
  final double earthRadiusM;
  final (int, int) clampX;
  final (int, int) clampY;

  /// Pixel position of [p] on the panoramic map, clamped to the safe
  /// rectangle. Rounds half to even, as cartographer's Python does.
  (int x, int y) project(LatLon p) {
    final east =
        earthRadiusM * _rad(p.lon - origin.lon) * math.cos(_rad(origin.lat));
    final north = earthRadiusM * _rad(p.lat - origin.lat);
    final theta = _rad(orientationDeg);
    final forward = east * math.sin(theta) + north * math.cos(theta);
    final right = east * math.cos(theta) - north * math.sin(theta);
    final x = roundHalfEven(forward / metresPerPixel + offsetX);
    final y = roundHalfEven(right / metresPerPixel + offsetY);
    return (
      x.clamp(clampX.$1, clampX.$2).toInt(),
      y.clamp(clampY.$1, clampY.$2).toInt(),
    );
  }
}

/// Python's round(): nearest integer, ties to even.
int roundHalfEven(double v) {
  final floor = v.floorToDouble();
  final diff = v - floor;
  if (diff < 0.5) return floor.toInt();
  if (diff > 0.5) return floor.toInt() + 1;
  final f = floor.toInt();
  return f.isEven ? f : f + 1;
}
