/// Pure models for cartographer walking regions (plan region-sync, phase 3).
///
/// Shapes follow `docs/cartographer-contract.md`, "Regions, operations and
/// failures". Region and job ids are opaque strings.
library;

import 'dart:convert';
import 'dart:math' as math;

class RegionFormatException implements Exception {
  RegionFormatException(this.message);
  final String message;
  @override
  String toString() => 'RegionFormatException: $message';
}

class WalkRegion {
  const WalkRegion({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.west,
    required this.south,
    required this.east,
    required this.north,
    required this.pinned,
    this.created,
    this.lastUsed,
    this.sizeBytes,
  });

  final String id;
  final String name;
  final double lat;
  final double lon;
  final double west;
  final double south;
  final double east;
  final double north;
  final bool pinned;
  final DateTime? created;
  final DateTime? lastUsed;
  final int? sizeBytes;

  factory WalkRegion.fromJson(Map<String, dynamic> j) {
    final id = j['region_id'];
    if (id is! String || id.isEmpty) {
      throw RegionFormatException('region without region_id');
    }
    final centre = j['centre'];
    final bbox = j['bbox_wsen'];
    if (centre is! Map || bbox is! List || bbox.length != 4) {
      throw RegionFormatException('region $id: missing centre or bbox_wsen');
    }
    double num_(Object? v, String what) {
      if (v is num) return v.toDouble();
      throw RegionFormatException('region $id: $what is not a number');
    }

    final size = j['size_bytes'];
    final total = size is Map ? size['total'] : size;
    final name = j['name'];
    return WalkRegion(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : id,
      lat: num_(centre['lat'], 'centre.lat'),
      lon: num_(centre['lon'], 'centre.lon'),
      west: num_(bbox[0], 'bbox W'),
      south: num_(bbox[1], 'bbox S'),
      east: num_(bbox[2], 'bbox E'),
      north: num_(bbox[3], 'bbox N'),
      pinned: j['pinned'] == true,
      created: _time(j['created']),
      lastUsed: _time(j['last_used']),
      sizeBytes: total is num ? total.toInt() : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'region_id': id,
        'name': name,
        'centre': {'lat': lat, 'lon': lon},
        'bbox_wsen': [west, south, east, north],
        'pinned': pinned,
        'created': created?.toUtc().toIso8601String(),
        'last_used': lastUsed?.toUtc().toIso8601String(),
        'size_bytes': {'total': sizeBytes},
      };

  bool contains(double lat, double lon) =>
      lat >= south && lat <= north && lon >= west && lon <= east;

  /// Days until the server's expiry sweep removes this region, or null when
  /// pinned. `last_used` falls back to `created` (contract). Negative means
  /// due at the next hourly sweep.
  int? daysUntilExpiry(DateTime now, {int expiryDays = 30}) {
    if (pinned) return null;
    final since = lastUsed ?? created;
    if (since == null) return null;
    return expiryDays - now.toUtc().difference(since.toUtc()).inDays;
  }
}

/// Pinned first, then by name (case-insensitive), then id for stability.
List<WalkRegion> sortRegions(Iterable<WalkRegion> regions) {
  final list = regions.toList();
  list.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  return list;
}

/// Parses `GET /v1/regions`. A malformed entry is skipped rather than
/// failing the whole list; the skip count is returned for logging.
({List<WalkRegion> regions, int skipped}) parseRegionList(String body) {
  final decoded = jsonDecode(body);
  final raw = decoded is Map ? decoded['regions'] : null;
  if (raw is! List) {
    throw RegionFormatException('response has no regions list');
  }
  final out = <WalkRegion>[];
  var skipped = 0;
  for (final r in raw) {
    try {
      if (r is! Map) throw RegionFormatException('entry is not an object');
      out.add(WalkRegion.fromJson(r.cast<String, dynamic>()));
    } on RegionFormatException {
      skipped++;
    }
  }
  return (regions: sortRegions(out), skipped: skipped);
}

String encodeRegionCache(List<WalkRegion> regions, DateTime fetchedAt) =>
    jsonEncode({
      'fetched_at': fetchedAt.toUtc().toIso8601String(),
      'regions': regions.map((r) => r.toJson()).toList(),
    });

({List<WalkRegion> regions, DateTime? fetchedAt})? decodeRegionCache(
    String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    final parsed = parseRegionList(s);
    final fetched = _time((jsonDecode(s) as Map)['fetched_at']);
    return (regions: parsed.regions, fetchedAt: fetched);
  } catch (_) {
    return null;
  }
}

/// A cartographer error body `{"error": code, ...}` with its HTTP status.
class RegionApiError implements Exception {
  const RegionApiError(this.status, this.code, [this.detail]);
  final int status;
  final String code;
  final String? detail;

  factory RegionApiError.fromResponse(int status, String? body) {
    String code = 'http_$status';
    String? detail;
    try {
      final j = jsonDecode(body ?? '');
      if (j is Map) {
        if (j['error'] is String) code = j['error'] as String;
        final d = j['detail'] ?? j['message'] ?? j['reason'];
        if (d is String) detail = d;
      }
    } catch (_) {}
    return RegionApiError(status, code, detail);
  }

  /// One line for a snackbar.
  String get userMessage => switch (code) {
        'region_exists' => 'This spot is already inside a synced region.',
        'build_busy' => 'Another region is building. Try again shortly.',
        'pinned' => 'Unpin the region before deleting it.',
        'unknown_region' => 'That region no longer exists.',
        'build_unavailable' || 'no_port' =>
          'The server cannot start a build right now.',
        _ => detail == null ? 'Server error ($code).' : '$code: $detail',
      };

  @override
  String toString() => 'RegionApiError($status $code${detail == null ? '' : ': $detail'})';
}

/// The 202 body of `POST /v1/regions`.
({String jobId, String regionId}) parseBuildAccepted(String body) {
  final j = jsonDecode(body);
  if (j is Map && j['job_id'] is String && j['region_id'] is String) {
    return (jobId: j['job_id'] as String, regionId: j['region_id'] as String);
  }
  throw RegionFormatException('build response lacks job_id/region_id');
}

/// A build tracked by the Android poller until it finishes.
class PendingRegionJob {
  const PendingRegionJob({
    required this.jobId,
    required this.regionId,
    required this.name,
    this.state,
    this.stage,
  });
  final String jobId;
  final String regionId;
  final String name;
  final String? state;
  final String? stage;

  factory PendingRegionJob.fromMap(Map<dynamic, dynamic> m) => PendingRegionJob(
        jobId: '${m['jobId']}',
        regionId: '${m['regionId']}',
        name: '${m['name'] ?? m['regionId']}',
        state: m['state'] as String?,
        stage: m['stage'] as String?,
      );

  String get statusLabel {
    final s = stage ?? state;
    return switch (s) {
      null || 'queued' => 'queued',
      'source_download' => 'downloading map data',
      'geometry' => 'building map geometry',
      'routing_extract' => 'extracting paths',
      'graph_and_engine' => 'building route graph',
      _ => s,
    };
  }
}

String formatBytes(int? bytes) {
  if (bytes == null) return '-';
  const mib = 1024 * 1024;
  if (bytes >= 1024 * mib) return '${(bytes / (1024 * mib)).toStringAsFixed(1)} GiB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
  return '${(bytes / 1024).ceil()} KiB';
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// What the cached region list says about a walk (plan region-sync, phase 4).
enum CoverageKind {
  /// One region holds every endpoint checked.
  covered,

  /// No cached list to judge by: let the server pick and handle `no_region`.
  unknown,

  /// An endpoint lies outside every region; [TripCoverage.syncAt] says where
  /// a sync would help.
  uncovered,

  /// Both endpoints are covered, but by different regions (cross-region walks
  /// are out of scope).
  split,
}

class TripCoverage {
  const TripCoverage(this.kind, {this.region, this.syncLat, this.syncLon});
  final CoverageKind kind;

  /// For [CoverageKind.covered]: the region the server would auto-select.
  final WalkRegion? region;
  final double? syncLat;
  final double? syncLon;
}

/// Mirrors the server's auto-selection: the smallest bbox holding both
/// endpoints. Without an origin (the check at share time, before any GPS
/// fix) only the destination is judged. When uncovered, the sync goes to the
/// destination if it is outside, else to the origin.
TripCoverage tripCoverage(
  List<WalkRegion> regions, {
  required double destLat,
  required double destLon,
  double? originLat,
  double? originLon,
}) {
  if (regions.isEmpty) return const TripCoverage(CoverageKind.unknown);
  final hasOrigin = originLat != null && originLon != null;
  final holding = regions
      .where((r) =>
          r.contains(destLat, destLon) &&
          (!hasOrigin || r.contains(originLat, originLon)))
      .toList()
    ..sort((a, b) {
      final byArea = _bboxArea(a).compareTo(_bboxArea(b));
      return byArea != 0 ? byArea : a.id.compareTo(b.id);
    });
  if (holding.isNotEmpty) {
    return TripCoverage(CoverageKind.covered, region: holding.first);
  }
  if (!regions.any((r) => r.contains(destLat, destLon))) {
    return TripCoverage(CoverageKind.uncovered,
        syncLat: destLat, syncLon: destLon);
  }
  if (!regions.any((r) => r.contains(originLat!, originLon!))) {
    return TripCoverage(CoverageKind.uncovered,
        syncLat: originLat, syncLon: originLon);
  }
  return const TripCoverage(CoverageKind.split);
}

/// Spherical-ish area in deg^2 scaled by cos(lat); enough to rank bboxes.
double _bboxArea(WalkRegion r) {
  final midLat = (r.north + r.south) / 2 * math.pi / 180;
  return (r.east - r.west) * (r.north - r.south) * math.cos(midLat);
}
