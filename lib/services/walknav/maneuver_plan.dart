import 'package:even_companion/services/walknav/nav_bundle.dart';
import 'package:even_companion/services/walknav/nav_geo.dart';

/// Turns cartographer's raw manoeuvre list into the turns a walker should be
/// told about.
///
/// Valhalla's pedestrian output is noisy: stepping from the road onto the
/// pavement comes out as "left onto the walkway" then "right onto the walkway"
/// 5 m apart, and a fork straight after a turn adds another arrow. On the
/// 724 m acceptance route 14 manoeuvres collapse to 6 real ones with these
/// rules (calibrated 2026-11-06):
/// - manoeuvres less than [clusterGapM] apart form one cluster;
/// - a cluster's turn is the net heading change from [clusterWindowM] before
///   its first manoeuvre to [clusterWindowM] after its last; a lone
///   manoeuvre uses [singleWindowM] either side;
/// - a turn under [suppressBelowDeg] is dropped (a jog, not a turn);
/// - roundabouts are always kept with the engine's arrow; the arrival is
///   always kept;
/// - a bend in the route geometry of [geometryTurnDeg] or more with no engine
///   manoeuvre within [geometryClearM] becomes a turn too. Valhalla emits
///   nothing when one continuous footway bends sharply, so a 70 degree right
///   turn on the 2026-11-09 walk was never guided.
class WalkTurn {
  const WalkTurn({
    required this.progressM,
    required this.direction,
    required this.text,
    required this.isArrival,
  });

  /// Where the turn happens, metres along the route.
  final double progressM;

  /// Firmware arrow value.
  final int direction;

  /// Human text for the HUD road line (not yet byte-clamped).
  final String text;

  final bool isArrival;
}

class ManeuverPlan {
  ManeuverPlan(this.turns);

  final List<WalkTurn> turns;

  static const double clusterGapM = 15;
  static const double clusterWindowM = 25;
  static const double singleWindowM = 15;
  static const double suppressBelowDeg = 30;
  static const double geometryWindowM = 20;
  static const double geometryStepM = 5;
  static const double geometryTurnDeg = 45;
  static const double geometryClearM = 25;

  // Firmware arrows (docs/FINDINGS-nav-marker-tiles.md, built-in arrows).
  static const int arrowStraight = 0x02;
  static const int arrowRight = 0x03;
  static const int arrowLeft = 0x04;
  static const int arrowSlightRight = 0x05;
  static const int arrowSlightLeft = 0x06;
  static const int arrowSharpRight = 0x07;
  static const int arrowSharpLeft = 0x08;
  static const int arrowUturnLeft = 0x09;
  static const int arrowUturnRight = 0x0a;

  factory ManeuverPlan.fromBundle(NavBundle bundle) =>
      ManeuverPlan(buildTurns(bundle.route, bundle.maneuvers));

  /// Next turn strictly ahead of [progressM] (with a small tolerance so a turn
  /// being walked through is still shown), or null when none is left.
  WalkTurn? nextTurn(double progressM, {double passedToleranceM = 3}) {
    for (final t in turns) {
      if (t.progressM > progressM - passedToleranceM) return t;
    }
    return null;
  }

  static List<WalkTurn> buildTurns(
      RouteLine route, List<NavManeuver> maneuvers) {
    final out = <WalkTurn>[];
    final candidates =
        maneuvers.where((m) => !m.isStart).toList(growable: false);
    var i = 0;
    while (i < candidates.length) {
      final first = candidates[i];
      if (first.isArrival) {
        out.add(WalkTurn(
          progressM: first.progressM,
          direction: arrowStraight,
          text: 'Arrive',
          isArrival: true,
        ));
        i++;
        continue;
      }
      if (first.isRoundabout) {
        out.add(WalkTurn(
          progressM: first.progressM,
          direction: first.direction,
          text: _trimInstruction(first.instruction),
          isArrival: false,
        ));
        i++;
        continue;
      }
      // Grow a cluster of closely spaced ordinary manoeuvres.
      var j = i;
      while (j + 1 < candidates.length &&
          !candidates[j + 1].isArrival &&
          !candidates[j + 1].isRoundabout &&
          candidates[j + 1].progressM - candidates[j].progressM <
              clusterGapM) {
        j++;
      }
      final last = candidates[j];
      final window = i == j ? singleWindowM : clusterWindowM;
      final before = route.headingBetween(
          first.progressM - window, first.progressM);
      final after =
          route.headingBetween(last.progressM, last.progressM + window);
      final delta = headingDelta(before, after);
      if (delta.abs() >= suppressBelowDeg) {
        final arrow = arrowForDelta(delta);
        out.add(WalkTurn(
          progressM: first.progressM,
          direction: arrow,
          text: i == j
              ? _trimInstruction(first.instruction)
              : _synthesise(arrow, last.streetName),
          isArrival: false,
        ));
      }
      i = j + 1;
    }
    out.addAll(_geometryTurns(route, maneuvers));
    out.sort((a, b) => a.progressM.compareTo(b.progressM));
    return out;
  }

  /// Sharp bends the engine said nothing about. Samples the heading change
  /// across [geometryWindowM] either side every [geometryStepM]; each run of
  /// samples at or over [geometryTurnDeg] with one sign is one turn, placed at
  /// its peak. Skipped near any engine manoeuvre (it already covers the spot,
  /// or deliberately dropped it as a jog), near the route ends, and through a
  /// roundabout.
  static List<WalkTurn> _geometryTurns(
      RouteLine route, List<NavManeuver> maneuvers) {
    bool covered(double s) {
      if (s < geometryClearM || s > route.totalM - geometryClearM) return true;
      for (final m in maneuvers) {
        if ((m.progressM - s).abs() < geometryClearM) return true;
      }
      // Inside a roundabout: between an enter and the following exit.
      for (var k = 0; k < maneuvers.length; k++) {
        if (maneuvers[k].engineType != NavManeuver.typeRoundaboutEnter) {
          continue;
        }
        final exit = maneuvers.skip(k + 1).firstWhere(
            (m) => m.engineType == NavManeuver.typeRoundaboutExit,
            orElse: () => maneuvers[k]);
        if (s >= maneuvers[k].progressM && s <= exit.progressM) return true;
      }
      return false;
    }

    final out = <WalkTurn>[];
    double? peakS;
    var peakDelta = 0.0;
    void flush() {
      if (peakS != null && !covered(peakS!)) {
        final arrow = arrowForDelta(peakDelta);
        out.add(WalkTurn(
          progressM: peakS!,
          direction: arrow,
          text: _synthesise(arrow, ''),
          isArrival: false,
        ));
      }
      peakS = null;
      peakDelta = 0;
    }

    for (var s = geometryWindowM;
        s <= route.totalM - geometryWindowM;
        s += geometryStepM) {
      final d = headingDelta(route.headingBetween(s - geometryWindowM, s),
          route.headingBetween(s, s + geometryWindowM));
      if (d.abs() < geometryTurnDeg ||
          (peakS != null && d.sign != peakDelta.sign)) {
        flush();
        if (d.abs() < geometryTurnDeg) continue;
      }
      if (d.abs() > peakDelta.abs()) {
        peakS = s;
        peakDelta = d;
      }
    }
    flush();
    return out;
  }

  /// Arrow for a signed heading change (positive = right).
  static int arrowForDelta(double delta) {
    final a = delta.abs();
    final right = delta > 0;
    if (a >= 165) return right ? arrowUturnRight : arrowUturnLeft;
    if (a >= 135) return right ? arrowSharpRight : arrowSharpLeft;
    if (a >= 45) return right ? arrowRight : arrowLeft;
    return right ? arrowSlightRight : arrowSlightLeft;
  }

  static String _synthesise(int arrow, String street) {
    final verb = switch (arrow) {
      arrowRight => 'Turn right',
      arrowLeft => 'Turn left',
      arrowSlightRight => 'Bear right',
      arrowSlightLeft => 'Bear left',
      arrowSharpRight => 'Sharp right',
      arrowSharpLeft => 'Sharp left',
      arrowUturnLeft || arrowUturnRight => 'Turn around',
      _ => 'Continue',
    };
    final s = street.trim();
    return s.isEmpty ? verb : '$verb onto $s';
  }

  static String _trimInstruction(String instruction) {
    final t = instruction.trim();
    return t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  }
}
