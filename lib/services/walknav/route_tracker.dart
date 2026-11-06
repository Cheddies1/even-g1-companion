import 'package:even_companion/services/walknav/nav_geo.dart';

/// One location fix, from the live provider or a replayed trace.
class NavFix {
  const NavFix({
    required this.position,
    required this.timeMs,
    this.accuracyM,
    this.speedMps,
  });

  final LatLon position;

  /// Monotonic milliseconds (elapsed realtime), not wall clock.
  final int timeMs;
  final double? accuracyM;
  final double? speedMps;
}

class TrackerUpdate {
  const TrackerUpdate({
    required this.progressM,
    required this.distanceFromRouteM,
    required this.accepted,
    required this.offRoute,
    required this.arrived,
  });

  /// Matched distance along the route; null until the first good fix.
  final double? progressM;

  /// Distance from the route of the last accepted fix.
  final double? distanceFromRouteM;

  /// False when the fix was ignored (accuracy too poor).
  final bool accepted;

  /// Sustained disagreement with the route: time to reroute.
  final bool offRoute;
  final bool arrived;
}

/// Map-matches fixes onto a route.
///
/// Gate C (docs/FINDINGS-screen-off-gps.md): walking fixes are 1 Hz with p95
/// ~14 m; poor fixes (100 m+) only appear stationary indoors. So fixes worse
/// than [maxAccuracyM] are ignored outright rather than smoothed, the
/// corridor is generous, and off-route needs [offRouteAfterMs] of sustained
/// disagreement so one bad fix never triggers a reroute.
class RouteTracker {
  RouteTracker(
    this.route, {
    this.maxAccuracyM = 25,
    this.corridorM = 20,
    this.offRouteAfterMs = 10000,
    this.arrivalWithinM = 15,
    this.searchBehindM = 40,
    this.searchAheadM = 150,
  });

  final RouteLine route;
  final double maxAccuracyM;
  final double corridorM;
  final int offRouteAfterMs;
  final double arrivalWithinM;
  final double searchBehindM;
  final double searchAheadM;

  double? _progressM;
  double? _distanceM;
  int? _offSinceMs;
  bool _offRoute = false;
  bool _arrived = false;

  double? get progressM => _progressM;
  bool get offRoute => _offRoute;
  bool get arrived => _arrived;

  TrackerUpdate update(NavFix fix) {
    final acc = fix.accuracyM;
    if (acc != null && acc > maxAccuracyM) {
      return _state(accepted: false);
    }
    PolylineMatch? m;
    var atWindowEdge = false;
    final p = _progressM;
    if (p != null) {
      final lo = (p - searchBehindM).clamp(0.0, route.totalM).toDouble();
      final hi = (p + searchAheadM).clamp(0.0, route.totalM).toDouble();
      m = route.match(fix.position, fromM: lo, toM: hi);
      atWindowEdge = m != null &&
          ((m.progressM >= hi - 0.5 && hi < route.totalM) ||
              (m.progressM <= lo + 0.5 && lo > 0));
    }
    if (m == null || m.distanceM > corridorM || atWindowEdge) {
      // First fix, lost the local window, or the walker is beyond it (a
      // gap in fixes): search the whole route.
      final global = route.match(fix.position);
      if (global != null && (m == null || global.distanceM < m.distanceM)) {
        m = global;
      }
    }
    if (m == null) return _state(accepted: false);

    _distanceM = m.distanceM;
    if (m.distanceM <= corridorM) {
      _progressM = m.progressM;
      _offSinceMs = null;
      _offRoute = false;
    } else {
      _offSinceMs ??= fix.timeMs;
      if (fix.timeMs - _offSinceMs! >= offRouteAfterMs) {
        _offRoute = true;
      }
    }
    final prog = _progressM;
    if (!_arrived &&
        prog != null &&
        m.distanceM <= corridorM &&
        route.totalM - prog <= arrivalWithinM) {
      _arrived = true;
    }
    return _state(accepted: true);
  }

  TrackerUpdate _state({required bool accepted}) => TrackerUpdate(
        progressM: _progressM,
        distanceFromRouteM: _distanceM,
        accepted: accepted,
        offRoute: _offRoute,
        arrived: _arrived,
      );
}
