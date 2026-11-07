import 'dart:convert';

import 'package:even_companion/services/walknav/region_model.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _region(String id,
        {String? name,
        bool pinned = false,
        String? lastUsed,
        String created = '2026-11-01T10:00:00Z',
        Object? size = const {'total': 3002619}}) =>
    {
      'region_id': id,
      'name': name,
      'centre': {'lat': 51.46, 'lon': -0.30},
      'bbox_wsen': [-0.37, 51.41, -0.23, 51.51],
      'created': created,
      'last_used': lastUsed,
      'pinned': pinned,
      'routing_port': 8004,
      'size_bytes': size,
    };

void main() {
  group('parseRegionList', () {
    test('parses, sorts pinned first then by name, skips malformed', () {
      final body = jsonEncode({
        'regions': [
          _region('prague-x1', name: 'prague'),
          _region('home', name: 'Home', pinned: true),
          _region('a-b', name: 'Acton'),
          {'region_id': 'broken'},
          'nonsense',
        ]
      });
      final r = parseRegionList(body);
      expect(r.regions.map((e) => e.id), ['home', 'a-b', 'prague-x1']);
      expect(r.skipped, 2);
      final home = r.regions.first;
      expect(home.pinned, isTrue);
      expect(home.sizeBytes, 3002619);
      expect(home.lastUsed, isNull);
      expect(home.created, DateTime.utc(2026, 11, 1, 10));
    });

    test('name falls back to id; size may be a bare number or absent', () {
      final r = parseRegionList(jsonEncode({
        'regions': [
          _region('x', name: '  ', size: 12),
          _region('y', size: null),
        ]
      })).regions;
      expect(r[0].name, 'x');
      expect(r[0].sizeBytes, 12);
      expect(r[1].sizeBytes, isNull);
    });

    test('missing regions list throws', () {
      expect(() => parseRegionList('{}'), throwsA(isA<RegionFormatException>()));
    });
  });

  test('contains uses the WSEN bbox inclusively', () {
    final r = WalkRegion.fromJson(_region('r'));
    expect(r.contains(51.46, -0.30), isTrue);
    expect(r.contains(51.41, -0.37), isTrue);
    expect(r.contains(51.52, -0.30), isFalse);
    expect(r.contains(51.46, -0.20), isFalse);
  });

  group('daysUntilExpiry', () {
    final now = DateTime.utc(2026, 11, 7, 12);
    test('pinned never expires', () {
      expect(WalkRegion.fromJson(_region('p', pinned: true)).daysUntilExpiry(now),
          isNull);
    });
    test('falls back to created when never used', () {
      expect(WalkRegion.fromJson(_region('u')).daysUntilExpiry(now), 24);
    });
    test('uses last_used when set, and goes negative when overdue', () {
      expect(
          WalkRegion.fromJson(_region('u', lastUsed: '2026-11-06T12:00:00Z'))
              .daysUntilExpiry(now),
          29);
      expect(
          WalkRegion.fromJson(_region('u', created: '2026-09-01T00:00:00Z'))
              .daysUntilExpiry(now),
          lessThan(0));
    });
  });

  test('cache round-trips regions and fetch time', () {
    final regions = parseRegionList(jsonEncode({
      'regions': [_region('home', name: 'Home', pinned: true, lastUsed: '2026-11-06T08:00:00Z')]
    })).regions;
    final at = DateTime.utc(2026, 11, 7, 9, 30);
    final back = decodeRegionCache(encodeRegionCache(regions, at))!;
    expect(back.fetchedAt, at);
    final r = back.regions.single;
    expect(r.id, 'home');
    expect(r.name, 'Home');
    expect(r.pinned, isTrue);
    expect(r.lastUsed, DateTime.utc(2026, 11, 6, 8));
    expect(r.sizeBytes, 3002619);
    expect(r.contains(51.46, -0.30), isTrue);
    expect(decodeRegionCache('garbage'), isNull);
    expect(decodeRegionCache(null), isNull);
  });

  group('RegionApiError', () {
    test('reads the error code and maps known ones', () {
      final e = RegionApiError.fromResponse(409, '{"error":"build_busy"}');
      expect(e.code, 'build_busy');
      expect(e.userMessage, contains('Another region'));
      expect(RegionApiError.fromResponse(409, '{"error":"region_exists"}').userMessage,
          contains('already inside'));
    });
    test('unknown or unparseable bodies still produce a message', () {
      expect(RegionApiError.fromResponse(502, '<html>').code, 'http_502');
      final e = RegionApiError.fromResponse(413, '{"error":"body_size","message":"Body must be 1..4096 bytes"}');
      expect(e.userMessage, 'body_size: Body must be 1..4096 bytes');
    });
  });

  test('parseBuildAccepted', () {
    final a = parseBuildAccepted('{"job_id":"j1","region_id":"r1"}');
    expect(a.jobId, 'j1');
    expect(a.regionId, 'r1');
    expect(() => parseBuildAccepted('{"job_id":"j1"}'),
        throwsA(isA<RegionFormatException>()));
  });

  test('PendingRegionJob labels stages', () {
    PendingRegionJob job(String? state, String? stage) => PendingRegionJob.fromMap(
        {'jobId': 'j', 'regionId': 'r', 'name': 'Prague', 'state': state, 'stage': stage});
    expect(job('queued', null).statusLabel, 'queued');
    expect(job('running', 'geometry').statusLabel, 'building map geometry');
    expect(job('running', 'something_new').statusLabel, 'something_new');
  });

  test('formatBytes', () {
    expect(formatBytes(null), '-');
    expect(formatBytes(3002619), '2.9 MiB');
    expect(formatBytes(2048), '2 KiB');
  });

  group('tripCoverage', () {
    WalkRegion box(String id, double w, double s, double e, double n) =>
        WalkRegion(
          id: id,
          name: id,
          lat: (s + n) / 2,
          lon: (w + e) / 2,
          west: w,
          south: s,
          east: e,
          north: n,
          pinned: false,
        );
    // Synthetic test boxes, not real places.
    final big = box('big', 0, 50, 2, 52);
    final small = box('small', 0.5, 50.5, 1.0, 51.0);
    final far = box('far', 10, 50, 11, 51);

    test('no cached regions is unknown', () {
      expect(tripCoverage(const [], destLat: 1, destLon: 1).kind,
          CoverageKind.unknown);
    });

    test('destination-only check at share time', () {
      final c = tripCoverage([big, far], destLat: 50.7, destLon: 10.5);
      expect(c.kind, CoverageKind.covered);
      expect(c.region!.id, 'far');
      final out = tripCoverage([big, far], destLat: 40, destLon: 5);
      expect(out.kind, CoverageKind.uncovered);
      expect((out.syncLat, out.syncLon), (40.0, 5.0));
    });

    test('picks the smallest bbox holding both endpoints', () {
      final c = tripCoverage([big, small],
          destLat: 50.7, destLon: 0.7, originLat: 50.8, originLon: 0.8);
      expect(c.region!.id, 'small');
      final wide = tripCoverage([big, small],
          destLat: 50.7, destLon: 0.7, originLat: 51.5, originLon: 1.5);
      expect(wide.region!.id, 'big');
    });

    test('uncovered destination syncs at the destination', () {
      final c = tripCoverage([big],
          destLat: 30, destLon: 3, originLat: 51, originLon: 1);
      expect(c.kind, CoverageKind.uncovered);
      expect((c.syncLat, c.syncLon), (30.0, 3.0));
    });

    test('covered destination with an uncovered origin syncs at the origin',
        () {
      final c = tripCoverage([big],
          destLat: 51, destLon: 1, originLat: 30, originLon: 3);
      expect(c.kind, CoverageKind.uncovered);
      expect((c.syncLat, c.syncLon), (30.0, 3.0));
    });

    test('endpoints in two different regions is split', () {
      final c = tripCoverage([big, far],
          destLat: 50.5, destLon: 10.5, originLat: 51, originLon: 1);
      expect(c.kind, CoverageKind.split);
      expect(c.syncLat, isNull);
    });
  });
}
