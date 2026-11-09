import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:even_companion/services/walknav/maneuver_plan.dart';
import 'package:even_companion/services/walknav/maps_share.dart';
import 'package:even_companion/services/walknav/nav_bundle.dart';
import 'package:even_companion/services/walknav/nav_geo.dart';
import 'package:even_companion/services/walknav/nav_wire.dart';
import 'package:even_companion/services/walknav/route_tracker.dart';
import 'package:even_companion/services/walknav/tile_selector.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic geometry only: the repo is public, so no real places.
const _origin = LatLon(50.0, 0.0);
const _mPerDegLat = kEarthRadiusM * math.pi / 180.0;
final _mPerDegLon = _mPerDegLat * math.cos(50.0 * math.pi / 180.0);

/// Point [east]/[north] metres from the synthetic origin.
LatLon at(double east, double north) =>
    LatLon(_origin.lat + north / _mPerDegLat, _origin.lon + east / _mPerDegLon);

/// 200 m north, then 200 m east (a right turn at 200 m).
RouteLine lRoute() => RouteLine([at(0, 0), at(0, 200), at(200, 200)]);

NavFix fix(LatLon p, int tSec, {double acc = 5}) =>
    NavFix(position: p, timeMs: tSec * 1000, accuracyM: acc);

void main() {
  group('geometry', () {
    test('cumulative distance matches the tangent-plane formula', () {
      final r = lRoute();
      expect(r.totalM, closeTo(400, 0.5));
      final mid = r.pointAt(300);
      final (e, n) = toLocalMetres(_origin, mid);
      expect(e, closeTo(100, 0.5));
      expect(n, closeTo(200, 0.5));
    });

    test('match projects onto the nearest segment', () {
      final m = lRoute().match(at(8, 120))!;
      expect(m.progressM, closeTo(120, 0.5));
      expect(m.distanceM, closeTo(8, 0.5));
    });

    test('roundHalfEven matches Python round', () {
      expect(roundHalfEven(2.5), 2);
      expect(roundHalfEven(3.5), 4);
      expect(roundHalfEven(-0.5), 0);
      expect(roundHalfEven(1.49), 1);
    });

    test('marker transform places forward along x and clamps', () {
      const t = MarkerTransform(
        origin: _origin,
        orientationDeg: 0, // forward = north
        metresPerPixel: 1.5,
        offsetX: 244,
        offsetY: 68,
      );
      expect(t.project(_origin), (244, 68));
      expect(t.project(at(0, 30)), (264, 68)); // 30 m ahead = +20 px
      expect(t.project(at(15, 0)), (244, 78)); // 15 m right = +10 px
      expect(t.project(at(0, 10000)), (482, 68)); // clamped
    });
  });

  group('route tracker', () {
    test('ignores fixes worse than the accuracy gate', () {
      final tr = RouteTracker(lRoute());
      final u = tr.update(fix(at(0, 50), 0, acc: 80));
      expect(u.accepted, isFalse);
      expect(u.progressM, isNull);
    });

    test('follows the route and arrives', () {
      final tr = RouteTracker(lRoute());
      var u = tr.update(fix(at(2, 10), 0));
      expect(u.progressM, closeTo(10, 1));
      u = tr.update(fix(at(-3, 190), 140));
      expect(u.progressM, closeTo(190, 1));
      u = tr.update(fix(at(150, 203), 270));
      expect(u.progressM, closeTo(350, 1));
      expect(u.arrived, isFalse);
      u = tr.update(fix(at(192, 201), 300));
      expect(u.arrived, isTrue);
    });

    test('one bad fix does not take you off route', () {
      final tr = RouteTracker(lRoute());
      tr.update(fix(at(0, 50), 0));
      final u = tr.update(fix(at(60, 60), 1)); // 60 m off, accurate
      expect(u.offRoute, isFalse);
      expect(u.progressM, closeTo(50, 1), reason: 'progress held');
      final back = tr.update(fix(at(1, 55), 2));
      expect(back.offRoute, isFalse);
    });

    test('sustained disagreement for 10 s goes off route, and recovers', () {
      final tr = RouteTracker(lRoute());
      tr.update(fix(at(0, 50), 0));
      var u = tr.update(fix(at(60, 60), 1));
      for (var t = 2; t <= 10; t++) {
        u = tr.update(fix(at(60, 60), t));
      }
      expect(u.offRoute, isFalse, reason: '9 s is not enough');
      u = tr.update(fix(at(60, 60), 11));
      expect(u.offRoute, isTrue);
      u = tr.update(fix(at(0, 70), 12));
      expect(u.offRoute, isFalse);
    });

    test('does not jump to a far part of the route that passes nearby', () {
      // A hairpin: north 100 m, east 30 m, south 100 m.
      final r = RouteLine([at(0, 0), at(0, 100), at(30, 100), at(30, 0)]);
      final tr = RouteTracker(r);
      tr.update(fix(at(0, 10), 0));
      final u = tr.update(fix(at(14, 20), 1)); // nearer the return leg
      expect(u.progressM, lessThan(60), reason: 'stays on the outbound leg');
    });
  });

  group('manoeuvre plan', () {
    NavManeuver m(double p, int dir, int type,
            {String text = 'Turn', String street = ''}) =>
        NavManeuver(
            progressM: p,
            instruction: text,
            streetName: street,
            direction: dir,
            engineType: type);

    test('a real turn is kept with a geometric arrow', () {
      final plan = ManeuverPlan.buildTurns(lRoute(), [
        m(0, 2, 1),
        m(200, 3, 10, text: 'Turn right onto Test Road.'),
        m(400, 2, 4),
      ]);
      expect(plan.length, 2);
      expect(plan[0].direction, ManeuverPlan.arrowRight);
      expect(plan[0].text, 'Turn right onto Test Road');
      expect(plan[1].isArrival, isTrue);
    });

    test('a left-right jog onto the pavement is dropped', () {
      // North 100, jog 4 m west over 5 m, continue north.
      final r = RouteLine([
        at(0, 0),
        at(0, 100),
        at(-4, 100),
        at(-4, 105),
        at(-4, 250),
      ]);
      final plan = ManeuverPlan.buildTurns(r, [
        m(0, 2, 1),
        m(100, 4, 15),
        m(104, 3, 10),
        m(r.totalM, 2, 4),
      ]);
      expect(plan.length, 1);
      expect(plan.single.isArrival, isTrue);
    });

    test('roundabouts are kept with the engine arrow', () {
      final plan = ManeuverPlan.buildTurns(RouteLine([at(0, 0), at(0, 400)]), [
        m(150, 0x1d, 26, text: 'Enter the roundabout.'),
        m(160, 0x0f, 27, text: 'Exit the roundabout.'),
      ]);
      expect(plan.map((t) => t.direction), [0x1d, 0x0f]);
    });

    test('a sharp bend with no engine manoeuvre becomes a turn', () {
      // One continuous footway: north 200 m, then east. Valhalla says nothing.
      final plan = ManeuverPlan.buildTurns(lRoute(), [
        m(0, 2, 1),
        m(400, 2, 4),
      ]);
      expect(plan.length, 2);
      expect(plan[0].direction, ManeuverPlan.arrowRight);
      expect(plan[0].text, 'Turn right');
      expect(plan[0].progressM, closeTo(200, 5));
      expect(plan[1].isArrival, isTrue);
    });

    test('a bend the engine already names is not doubled', () {
      final plan = ManeuverPlan.buildTurns(lRoute(), [
        m(0, 2, 1),
        m(195, 3, 10, text: 'Turn right onto Test Road.'),
        m(400, 2, 4),
      ]);
      expect(plan.where((t) => !t.isArrival).length, 1);
      expect(plan.first.text, 'Turn right onto Test Road');
    });

    test('a gentle curve is not a turn', () {
      // 90 degrees spread over about 160 m.
      final pts = <LatLon>[];
      for (var k = 0; k <= 10; k++) {
        final a = k * 9 * math.pi / 180;
        pts.add(at(100 - 100 * math.cos(a), 100 * math.sin(a)));
      }
      final r = RouteLine([at(0, -100), ...pts, at(200, 100)]);
      final plan = ManeuverPlan.buildTurns(r, [m(r.totalM, 2, 4)]);
      expect(plan.single.isArrival, isTrue);
    });

    test('arrowForDelta bands', () {
      expect(ManeuverPlan.arrowForDelta(35), ManeuverPlan.arrowSlightRight);
      expect(ManeuverPlan.arrowForDelta(-90), ManeuverPlan.arrowLeft);
      expect(ManeuverPlan.arrowForDelta(150), ManeuverPlan.arrowSharpRight);
      expect(ManeuverPlan.arrowForDelta(-170), ManeuverPlan.arrowUturnLeft);
    });

    test('nextTurn skips turns already passed', () {
      final p = ManeuverPlan([
        const WalkTurn(progressM: 100, direction: 3, text: 'a', isArrival: false),
        const WalkTurn(progressM: 300, direction: 2, text: 'b', isArrival: true),
      ]);
      expect(p.nextTurn(50)!.text, 'a');
      expect(p.nextTurn(99)!.text, 'a');
      expect(p.nextTurn(110)!.text, 'b');
      expect(p.nextTurn(400), isNull);
    });
  });

  group('tile selector', () {
    NavTile tile(String id, double s, double e) => NavTile(
          id: id,
          startM: s,
          endM: e,
          panoramic: NavBitmap(
              width: 488,
              height: 136,
              encoding: 'raw',
              wire: Uint8List(0),
              rawBytes: 16592),
          miniMap: NavBitmap(
              width: 136,
              height: 136,
              encoding: 'raw',
              wire: Uint8List(0),
              rawBytes: 4624),
          transform: const MarkerTransform(
              origin: _origin,
              orientationDeg: 0,
              metresPerPixel: 1.5,
              offsetX: 244,
              offsetY: 68),
        );

    test('switches at the start of the next tile and holds the marker', () {
      final s = TileSelector([tile('a', 0, 190), tile('b', 140, 330)]);
      expect(s.nextTransfer(0), 0);
      s.beginTransfer(0);
      expect(s.nextTransfer(10), isNull, reason: 'one transfer at a time');
      s.completeTransfer(0);
      expect(s.nextTransfer(139), isNull);
      expect(s.nextTransfer(141), 1);
      s.beginTransfer(1);
      expect(s.markerProgress(200), 190, reason: 'held at old tile end');
      s.completeTransfer(1);
      expect(s.markerProgress(200), 200);
    });
  });

  group('trip text', () {
    test('formats distance, time and speed', () {
      expect(TripText.distance(83), '85 m');
      expect(TripText.distance(437), '440 m');
      expect(TripText.distance(1260), '1.3 km');
      expect(TripText.remainingTime(723), '10 min');
      expect(TripText.remainingTime(10), '1 min');
      expect(TripText.speed(1.3), '4.7 km/h');
      expect(TripText.speed(null), '');
    });

    test('clamps UTF-8 on a character boundary', () {
      expect(TripText.clampUtf8('Náměstí', 3), 'Ná');
      expect(utf8.encode(TripText.clampUtf8('x' * 80, 63)).length, 63);
    });
  });

  group('maps share', () {
    test('finds the URL in shared text', () {
      expect(
          MapsShare.firstUrl('A Pub\n1 High St\nhttps://maps.app.goo.gl/AbC123'),
          'https://maps.app.goo.gl/AbC123');
      expect(MapsShare.needsResolving('https://maps.app.goo.gl/AbC123'), isTrue);
    });

    test('takes the place name from the first plain line', () {
      expect(
          MapsShare.placeName(
              'Windsor Castle\nWindsor SL4 1NJ\nhttps://maps.app.goo.gl/AbC123'),
          'Windsor Castle');
      expect(MapsShare.placeName('\n  A Pub  \nhttps://x.y/z'), 'A Pub');
      expect(MapsShare.placeName('https://maps.app.goo.gl/AbC123'), isNull);
      expect(MapsShare.placeName('51.48, -0.60\nhttps://x.y/z'), isNull);
      expect(MapsShare.placeName('${'x' * 45} ', maxLength: 40), 'x' * 40);
    });

    test('prefers the place pin over the viewport centre', () {
      const url = 'https://www.google.com/maps/place/A+Pub/@50.10,0.20,17z/'
          'data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d50.1234!4d0.2345!16s';
      final p = MapsShare.coordinatesFromUrl(url)!;
      expect(p.lat, 50.1234);
      expect(p.lon, 0.2345);
    });

    test('directions and query links', () {
      expect(
          MapsShare.coordinatesFromUrl(
                  'https://www.google.com/maps/dir/?api=1&destination=50.5,0.25')!
              .lat,
          50.5);
      expect(
          MapsShare.coordinatesFromUrl(
                  'https://maps.google.com/?q=50.25,-0.75')!
              .lon,
          -0.75);
      expect(
          MapsShare.coordinatesFromUrl(
                  'https://www.google.com/maps/dir/50.1,0.1/50.2,0.2/@50.15,0.15,14z')!
              .lat,
          50.2);
    });

    test('a shared route takes its last stop (lon first)', () {
      const url = 'https://www.google.com/maps/dir/Current+Location/A+Pub/'
          'data=!4m14!4m13!1m5!1m1!1s0x0:0x0!2m2!1d0.11!2d50.11'
          '!1m5!1m1!1s0x0:0x0!2m2!1d0.2345!2d50.1234!3e2';
      final p = MapsShare.coordinatesFromUrl(url)!;
      expect(p.lat, 50.1234);
      expect(p.lon, 0.2345);
    });

    test('unwraps the EU consent page', () {
      final inner = Uri.encodeComponent(
          'https://www.google.com/maps/place/X/data=!3d50.3!4d0.4');
      final p = MapsShare.coordinatesFromUrl(
          'https://consent.google.com/m?continue=$inner&gl=GB')!;
      expect(p.lat, 50.3);
    });

    test('no coordinates gives null', () {
      expect(
          MapsShare.coordinatesFromUrl(
              'https://www.google.com/maps/search/a+pub'),
          isNull);
    });
  });

  group('bundle parsing', () {
    Map<String, dynamic> bitmap(int w, int h, Uint8List wire, String enc,
            Uint8List raw) =>
        {
          'width': w,
          'height': h,
          'encoding': enc,
          'raw_bytes': raw.length,
          'wire_bytes': wire.length,
          'sha256': sha256.convert(wire).toString(),
          'raw_sha256': sha256.convert(raw).toString(),
          'data_base64': base64Encode(wire),
        };

    Map<String, dynamic> bundleJson() {
      final pano = Uint8List(16592);
      final miniRaw = Uint8List(4624);
      // RLE of 4624 zero bytes: 18 runs of 255 + one of 34.
      final rle = <int>[];
      var left = 4624;
      while (left > 0) {
        final n = left > 255 ? 255 : left;
        rle.addAll([n, 0]);
        left -= n;
      }
      final r = lRoute();
      return {
        'bundle_id': 'abc',
        'version': '1.0.0',
        'region_id': 'home',
        'data_id': 'd',
        'coordinate_order': 'lat,lon',
        'polyline': r.points.map((p) => [p.lat, p.lon]).toList(),
        'total_m': r.totalM,
        'maneuvers': [
          {
            'progress_m': 200.0,
            'instruction': 'Turn right.',
            'street_name': '',
            'direction': 3,
            'engine_type': 10
          }
        ],
        'tiles': [
          {
            'id': 't000',
            'progress_start_m': 0,
            'progress_end_m': r.totalM,
            'orientation_deg': 0.0,
            'panoramic': bitmap(488, 136, pano, 'raw', pano),
            'mini_map':
                bitmap(136, 136, Uint8List.fromList(rle), 'rle', miniRaw),
            'marker_transform': {
              'projection_origin_lat_lon': [_origin.lat, _origin.lon],
              'orientation_deg': 0.0,
              'metres_per_pixel': 1.5,
              'pixel_offset': [244, 68],
              'earth_radius_m': kEarthRadiusM,
              'clamp': {
                'x': [6, 482],
                'y': [6, 130]
              }
            }
          }
        ],
        'attribution': 'OSM',
      };
    }

    test('parses and validates a well-formed bundle', () {
      final b = NavBundle.parse(jsonEncode(bundleJson()));
      expect(b.tiles.single.miniMap.encoding, 'rle');
      expect(b.totalM, closeTo(400, 0.5));
      expect(b.maneuvers.single.direction, 3);
    });

    test('rejects a tampered bitmap', () {
      final j = bundleJson();
      (j['tiles'] as List).first['panoramic']['sha256'] = '00';
      expect(() => NavBundle.parse(jsonEncode(j)),
          throwsA(isA<NavBundleException>()));
    });

    test('rejects tiles that do not cover the route', () {
      final j = bundleJson();
      (j['tiles'] as List).first['progress_end_m'] = 100;
      expect(() => NavBundle.parse(jsonEncode(j)),
          throwsA(isA<NavBundleException>()));
    });
  });

  group('nav wire', () {
    test('frames carry the validated total length', () {
      final w = NavWire();
      final p = w.init();
      expect(p.length, 6);
      expect(p[0], 0x0a);
      expect(p[1] | (p[2] << 8), 6);
      expect(p.sublist(4), [0x00, 0x01]);
    });

    test('panoramic is 90 packets, 1-based, flag byte, last ack detected', () {
      final pk = NavWire().panoramicPackets(Uint8List(16592));
      expect(pk.length, 90);
      expect(pk.first.length, 10 + 185);
      expect(pk.last.length, 10 + 16592 - 89 * 185);
      expect(pk.last[7] | (pk.last[8] << 8), 90);
      expect(pk.first[9], 0);
      for (final p in pk) {
        expect(p[1] | (p[2] << 8), p.length);
      }
      final ack = Uint8List.fromList([...pk.last.sublist(0, 10), 0]);
      expect(NavWire.isFinalMapAck(ack, 3, 90), isTrue);
      final mid = Uint8List.fromList([...pk[10].sublist(0, 10), 0]);
      expect(NavWire.isFinalMapAck(mid, 3, 90), isFalse);
    });

    test('mini-map packets have the 9-byte header', () {
      final pk = NavWire().miniMapPackets(Uint8List(4624));
      expect(pk.length, 25);
      expect(pk.first.length, 9 + 185);
      expect(pk.first[4], 0x02);
    });

    test('trip status caps every string field', () {
      final p = NavWire().tripStatus(
        direction: 3,
        x: 300,
        y: 70,
        timeRemaining: 'x' * 40,
        road: 'y' * 100,
      );
      expect(p[1] | (p[2] << 8), p.length);
      expect(p[5], 3);
      expect(p[6] | (p[7] << 8), 300);
      expect(p[8] | (p[9] << 8), 70);
      final fields = <List<int>>[];
      var cur = <int>[];
      for (final b in p.sublist(10)) {
        if (b == 0) {
          fields.add(cur);
          cur = [];
        } else {
          cur.add(b);
        }
      }
      expect(fields.map((f) => f.length).toList(), [23, 0, 63, 0, 0]);
    });

    test('sync reply running flag', () {
      expect(NavWire.syncSaysRunning(Uint8List.fromList([0x0a, 6, 0, 1, 4, 0])),
          isFalse);
      expect(NavWire.syncSaysRunning(Uint8List.fromList([0x0a, 6, 0, 1, 4, 1])),
          isTrue);
    });
  });
}
