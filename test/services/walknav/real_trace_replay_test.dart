import 'dart:io';

import 'package:even_companion/services/walknav/maneuver_plan.dart';
import 'package:even_companion/services/walknav/nav_bundle.dart';
import 'package:even_companion/services/walknav/nav_geo.dart';
import 'package:even_companion/services/walknav/route_tracker.dart';
import 'package:even_companion/services/walknav/tile_selector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Local-only replay of a real GPS trace against a real cartographer bundle.
/// Skipped unless both paths are set (real coordinates never enter the repo):
///   NAV_BUNDLE=/path/bundle.json NAV_TRACE=logs/gps/trace.csv \
///     flutter test test/services/walknav/real_trace_replay_test.dart
void main() {
  final bundlePath = Platform.environment['NAV_BUNDLE'];
  final tracePath = Platform.environment['NAV_TRACE'];
  final skip = bundlePath == null || tracePath == null
      ? 'set NAV_BUNDLE and NAV_TRACE to run'
      : null;

  test('replay a real walk', () {
    final bundle = NavBundle.parse(File(bundlePath!).readAsStringSync());
    final plan = ManeuverPlan.fromBundle(bundle);
    final tracker = RouteTracker(bundle.route);
    final tiles = TileSelector(bundle.tiles);

    final lines = File(tracePath!).readAsLinesSync();
    final header = lines.first.split(',');
    int col(String n) => header.indexOf(n);
    final cT = col('t_ms'), cK = col('kind'), cLat = col('lat');
    final cLon = col('lon'), cAcc = col('acc_m'), cSp = col('speed_mps');

    // ignore: avoid_print
    void log(String s) => print(s);
    log('route ${bundle.totalM.toStringAsFixed(0)} m, '
        '${bundle.maneuvers.length} raw manoeuvres -> ${plan.turns.length} turns');
    for (final t in plan.turns) {
      log('  turn @${t.progressM.toStringAsFixed(0)} m '
          'arrow 0x${t.direction.toRadixString(16)} "${t.text}"');
    }

    int? t0;
    String? lastTurn;
    var offRoute = false;
    var rejected = 0;
    int? arrivedAt;
    for (final line in lines.skip(1)) {
      final f = line.split(',');
      if (f[cK] != 'fix') continue;
      final t = int.parse(f[cT]);
      t0 ??= t;
      final sec = ((t - t0) / 1000).round();
      final fix = NavFix(
        position: LatLon(double.parse(f[cLat]), double.parse(f[cLon])),
        timeMs: t,
        accuracyM: double.tryParse(f[cAcc]),
        speedMps: double.tryParse(f[cSp]),
      );
      final u = tracker.update(fix);
      if (!u.accepted) rejected++;
      if (u.offRoute != offRoute) {
        offRoute = u.offRoute;
        log('${sec}s off-route=${u.offRoute} '
            'dist=${u.distanceFromRouteM?.toStringAsFixed(0)} m');
      }
      final p = u.progressM;
      if (p == null) continue;
      final next = tiles.nextTransfer(p);
      if (next != null) {
        tiles.beginTransfer(next);
        tiles.completeTransfer(next); // instant in the replay
        log('${sec}s @${p.toStringAsFixed(0)} m tile ${bundle.tiles[next].id}');
      }
      final turn = plan.nextTurn(p);
      final label = turn == null ? 'none' : turn.text;
      if (label != lastTurn) {
        lastTurn = label;
        log('${sec}s @${p.toStringAsFixed(0)} m next: $label');
      }
      final tile = tiles.shown!;
      final (x, y) = tile.transform
          .project(bundle.route.pointAt(tiles.markerProgress(p)));
      expect(x, inInclusiveRange(6, 482));
      expect(y, inInclusiveRange(6, 130));
      if (u.arrived && arrivedAt == null) {
        arrivedAt = sec;
        log('${sec}s ARRIVED');
        break;
      }
    }
    log('rejected (accuracy) fixes: $rejected');
    expect(arrivedAt, isNotNull, reason: 'the walk reaches the destination');
  }, skip: skip);
}
