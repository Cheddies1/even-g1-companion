import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/nav_card_session.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/walknav/maneuver_plan.dart';
import 'package:even_companion/services/walknav/maps_share.dart';
import 'package:even_companion/services/walknav/nav_bundle.dart';
import 'package:even_companion/services/walknav/nav_geo.dart';
import 'package:even_companion/services/walknav/region_model.dart';
import 'package:even_companion/services/walknav/region_service.dart';
import 'package:even_companion/services/walknav/route_tracker.dart';
import 'package:even_companion/services/walknav/tile_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum WalkTripState { idle, locating, routing, booting, running, arrived }

/// Walking navigation v1 (docs/plans/navigate-v1-cartographer.md, phase 5).
///
/// Cartographer on deepthought compiles the route and pre-renders tiles; this
/// service owns everything on the phone: the location source, the bundle
/// cache, map-matching, turn selection, tile swaps, the moving marker and the
/// `0x0a` card. Mode ownership stays in CompanionController, which starts and
/// stops trips and routes gestures here while a trip is live.
class WalkNavigatorService {
  WalkNavigatorService._();
  static final WalkNavigatorService get = WalkNavigatorService._();

  static const String routeUrl =
      'https://deepthought.tail082c0b.ts.net:9446/v1/route';
  static const _tag = 'WalkNav';
  static const _eventNav = EventChannel('eventNav');
  static const _firstFixTimeout = Duration(seconds: 45);
  // The trip origin only needs to land near the right street - routing snaps
  // it to the network - so after a short wait the best fix within
  // [_originMaxAccuracyM] will do. Walking still uses the tracker's 25 m gate.
  static const _goodOriginWait = Duration(seconds: 15);
  static const _goodOriginAccuracyM = 25.0;
  static const _originMaxAccuracyM = 150.0;
  static const _rerouteCooldown = Duration(seconds: 30);

  /// Called by the controller to switch into Navigate when a trip starts from
  /// a share or a debug broadcast, so mode ownership stays with it.
  Future<void> Function(LatLon dest, {LatLon? origin, String? replay, double speed})?
      onTripRequested;

  /// Called when a trip ends, so the controller can refresh its UI state.
  void Function(String reason)? onTripEnded;

  late final NavCardSession _card =
      NavCardSession(tag: _tag, onLost: _resync);
  StreamSubscription<dynamic>? _events;
  WalkTripState _state = WalkTripState.idle;
  LatLon? _destination;

  /// Place name of the last requested destination (share text or debug
  /// `--es name`), used to name a region built from the sync offer.
  String? _destinationName;
  NavFix? _lastFix;
  NavFix? _bestOriginFix;
  DateTime? _locatingSince;
  Completer<NavFix>? _firstFix;

  NavBundle? _bundle;
  ManeuverPlan? _plan;
  RouteTracker? _tracker;
  TileSelector? _tiles;
  bool _transferring = false;
  bool _rerouting = false;
  DateTime? _lastReroute;
  int _fixes = 0;

  WalkTripState get state => _state;
  bool get isActive => _state != WalkTripState.idle;

  void init() {
    _events ??= _eventNav.receiveBroadcastStream().listen(
          _onNavEvent,
          onError: (Object e) =>
              AppLog.error('nav event stream error: $e', tag: _tag),
        );
  }

  // ---- events from Android ----------------------------------------------------

  void _onNavEvent(dynamic raw) {
    if (raw is! Map) return;
    final e = Map<String, dynamic>.from(raw);
    switch (e['kind']) {
      case 'fix':
        final fix = NavFix(
          position: LatLon((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble()),
          timeMs: (e['t'] as num).toInt(),
          accuracyM: (e['acc'] as num?)?.toDouble(),
          speedMps: (e['speed'] as num?)?.toDouble(),
        );
        unawaited(_onFix(fix));
      case 'share':
        unawaited(_onShare(e['text'] as String? ?? ''));
      case 'debugTrip':
        unawaited(_onDebugTrip(e));
      case 'stopped':
        AppLog.info('location source stopped: ${e['reason']}', tag: _tag);
        if (isActive) unawaited(stop(reason: '${e['reason']}'));
      case 'replay':
        AppLog.info('replay started: ${e['fixes']} fixes', tag: _tag);
      case 'error':
        AppLog.error('location source error: ${e['reason']}', tag: _tag);
        if (isActive) unawaited(stop(reason: 'location error'));
    }
  }

  Future<void> _onShare(String text) async {
    AppLog.info('share received', tag: _tag);
    final dest = await destinationFromShare(text);
    if (dest == null) {
      AppLog.error('share had no usable location', tag: _tag);
      await Proto.showTitleCard('Walk: no location in share',
          duration: const Duration(seconds: 2));
      return;
    }
    _destinationName = MapsShare.placeName(text);
    if (!await _checkCoverage(dest)) return;
    await onTripRequested?.call(dest, speed: 1.0);
  }

  Future<void> _onDebugTrip(Map<String, dynamic> e) async {
    if (e['cmd'] == 'stop') {
      await stop(reason: 'debug stop');
      return;
    }
    LatLon? parse(Object? v) =>
        v is String ? MapsShare.coordinatesFromText(v) : null;
    final dest = parse(e['dest']);
    if (dest == null) {
      AppLog.error('debug trip needs --es dest "lat,lon"', tag: _tag);
      return;
    }
    _destinationName = e['name'] as String?;
    if (!await _checkCoverage(dest)) return;
    await onTripRequested?.call(
      dest,
      origin: parse(e['origin']),
      replay: e['replay'] as String?,
      speed: (e['speed'] as num?)?.toDouble() ?? 1.0,
    );
  }

  /// Destination from Google Maps share text: resolves short links.
  static Future<LatLon?> destinationFromShare(String text) async {
    final direct = MapsShare.coordinatesFromText(text);
    var url = MapsShare.firstUrl(text);
    if (url == null) return direct;
    try {
      final dio = Dio(BaseOptions(
        followRedirects: false,
        // Google serves different redirects to obvious bots.
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36',
        },
        validateStatus: (s) => s != null && s < 500,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));
      for (var hop = 0; hop < 6 && MapsShare.coordinatesFromUrl(url!) == null; hop++) {
        final r = await dio.get<String>(url,
            options: Options(responseType: ResponseType.plain));
        final loc = r.headers.value('location');
        if (loc == null) break;
        url = Uri.parse(url).resolve(loc).toString();
      }
    } catch (e) {
      AppLog.error('resolving share link failed: $e', tag: _tag);
    }
    final found = url == null ? null : MapsShare.coordinatesFromUrl(url);
    if (url != null) {
      // Shape only, never coordinates: enough to fix the parser if Google
      // changes link formats.
      final u = Uri.tryParse(url);
      AppLog.info(
        'share resolved: host=${u?.host} path=${u?.pathSegments.take(2).join('/')} '
        'stops=${url.contains('!1d')} pin=${url.contains('!3d')} '
        'at=${url.contains('@')} found=${found != null}',
        tag: _tag,
      );
    }
    return found ?? direct;
  }

  // ---- trip lifecycle ---------------------------------------------------------

  /// Start a trip. Called by CompanionController once Navigate mode is active.
  Future<void> start(LatLon destination,
      {LatLon? origin, String? replay, double speed = 1.0}) async {
    if (isActive) await stop(reason: 'new trip');
    _destination = destination;
    _fixes = 0;
    _lastFix = null;
    _setState(WalkTripState.locating);
    _firstFix = Completer<NavFix>();
    _bestOriginFix = null;
    _locatingSince = DateTime.now();
    // Start the location source first; the title card costs BLE time.
    await BleManager.invokeMethod('navLocationStart', {
      'replay': replay,
      'speed': speed,
      'title': 'Walking navigation',
    });
    await Proto.showTitleCard('Walk: finding you...',
        duration: const Duration(milliseconds: 800));

    LatLon? from = origin;
    if (from == null) {
      try {
        from = (await _firstFix!.future.timeout(_firstFixTimeout)).position;
      } on TimeoutException {
        AppLog.error(
            'no usable GPS fix within $_firstFixTimeout '
            '(fixes=$_fixes best=${_bestOriginFix?.accuracyM})',
            tag: _tag);
        await _fail('Walk: no GPS fix');
        return;
      } on StateError {
        return; // stopped while waiting for the first fix
      }
    }
    if (!await _checkCoverage(destination, origin: from)) return;
    if (!isActive) return; // stopped while checking
    _setState(WalkTripState.routing);
    await Proto.showTitleCard('Walk: routing...',
        duration: const Duration(milliseconds: 800));
    final bundle = await _fetchBundle(from, destination);
    if (!isActive) return; // stopped while routing
    if (bundle == null) {
      if (_lastRouteError == 'no_region') {
        // The cached list said covered but the server disagrees: refresh and
        // offer a sync only where the fresh list says one is needed.
        AppLog.error('server says no_region', tag: _tag);
        final c = tripCoverage(await RegionService.get.regionsForTrip(),
            destLat: destination.lat,
            destLon: destination.lon,
            originLat: from.lat,
            originLon: from.lon);
        switch (c.kind) {
          case CoverageKind.uncovered:
            await _offerSync(c.syncLat!, c.syncLon!,
                atDestination: c.syncLat == destination.lat &&
                    c.syncLon == destination.lon);
          case CoverageKind.split:
            await _tell('Walk: spans two areas');
          case CoverageKind.covered:
          case CoverageKind.unknown:
            await _fail('Walk: no route');
        }
      } else {
        await _fail('Walk: no route');
      }
      return;
    }
    _adoptBundle(bundle);
    _setState(WalkTripState.booting);
    await _bootGlasses();
    if (_state != WalkTripState.booting) return; // stopped during boot
    if (!_card.isRunning) {
      await _fail('Walk: glasses not ready');
      return;
    }
    _setState(WalkTripState.running);
    final last = _lastFix;
    if (last != null) await _onFix(last);
  }

  Future<void> stop({required String reason}) async {
    if (!isActive) return;
    AppLog.info('trip ended: $reason (fixes=$_fixes)', tag: _tag);
    _setState(WalkTripState.idle);
    final ff = _firstFix;
    if (ff != null && !ff.isCompleted) ff.completeError(StateError('stopped'));
    _firstFix = null;
    await BleManager.invokeMethod('navLocationStop');
    await _card.exit();
    _bundle = null;
    _plan = null;
    _tracker = null;
    _tiles = null;
    _transferring = false;
    _rerouting = false;
    onTripEnded?.call(reason);
  }

  Future<void> _fail(String message) async {
    await stop(reason: message);
    await Proto.showTitleCard(message, duration: const Duration(seconds: 2));
  }

  void _setState(WalkTripState s) {
    if (_state == s) return;
    AppLog.info('state ${_state.name} -> ${s.name}', tag: _tag);
    _state = s;
  }

  void _adoptBundle(NavBundle bundle) {
    _bundle = bundle;
    _plan = ManeuverPlan.fromBundle(bundle);
    _tracker = RouteTracker(bundle.route);
    _tiles = TileSelector(bundle.tiles);
    AppLog.info(
      'bundle ${bundle.bundleId.substring(0, 12)}: '
      '${bundle.totalM.toStringAsFixed(0)} m, ${bundle.tiles.length} tiles, '
      '${bundle.maneuvers.length} manoeuvres -> ${_plan!.turns.length} turns',
      tag: _tag,
    );
  }

  // ---- location -----------------------------------------------------------------

  Future<void> _onFix(NavFix fix) async {
    _fixes++;
    _lastFix = fix;
    final ff = _firstFix;
    if (ff != null && !ff.isCompleted) {
      final acc = fix.accuracyM ?? 0;
      final best = _bestOriginFix;
      if (best == null || acc < (best.accuracyM ?? 0)) _bestOriginFix = fix;
      final waited = _locatingSince == null
          ? Duration.zero
          : DateTime.now().difference(_locatingSince!);
      if (_fixes <= 3 || _fixes % 10 == 0) {
        AppLog.info('locating: fix $_fixes acc ${acc.toStringAsFixed(0)} m',
            tag: _tag);
      }
      if (acc <= _goodOriginAccuracyM) {
        ff.complete(fix);
      } else if (waited >= _goodOriginWait &&
          (_bestOriginFix!.accuracyM ?? 0) <= _originMaxAccuracyM) {
        ff.complete(_bestOriginFix!);
      }
    }
    if (_state != WalkTripState.running) return;
    final tracker = _tracker!;
    final u = tracker.update(fix);
    if (u.arrived) {
      await _arrive();
      return;
    }
    if (u.offRoute) {
      unawaited(_reroute(fix.position));
    }
    final progress = u.progressM;
    final tiles = _tiles!;
    if (progress != null && !_transferring) {
      final next = tiles.nextTransfer(progress);
      if (next != null) {
        unawaited(_transferTile(next));
        return; // TRIP_STATUS pauses while maps transfer (~2.4 s)
      }
    }
    if (_transferring || tiles.shown == null) return;
    await _sendTripStatus(fix, u);
  }

  Future<void> _sendTripStatus(NavFix fix, TrackerUpdate u) async {
    final bundle = _bundle!;
    final tile = _tiles!.shown!;
    final progress = u.progressM ?? 0.0;
    final onRoute = !u.offRoute && u.progressM != null;
    final markerPoint = onRoute
        ? bundle.route.pointAt(_tiles!.markerProgress(progress))
        : fix.position;
    final (x, y) = tile.transform.project(markerPoint);
    final turn = _plan!.nextTurn(progress);
    final remaining = bundle.totalM - progress;
    final road = _rerouting
        ? 'Rerouting...'
        : u.offRoute
            ? 'Off route'
            : (turn?.text ?? 'Continue');
    final packet = _card.wire.tripStatus(
      direction: turn?.direction ?? ManeuverPlan.arrowStraight,
      x: x,
      y: y,
      timeRemaining: TripText.remainingTime(remaining),
      distanceRemaining: TripText.distance(remaining),
      road: road,
      turnDistance:
          turn == null ? '' : TripText.distance(turn.progressM - progress),
      speed: TripText.speed(fix.speedMps),
    );
    await _card.sendTripStatus(packet);
  }

  // ---- glasses ------------------------------------------------------------------

  /// Boot the card with the tile for the current progress. The session owns
  /// the lifecycle (clear, INIT, maps master-last, SYNC keepalive).
  Future<void> _bootGlasses() async {
    final tiles = _tiles!;
    final index = tiles.desiredIndex(_tracker!.progressM ?? 0);
    final tile = tiles.tiles[index];
    _transferring = true;
    tiles.beginTransfer(index);
    try {
      final booted = await _card.boot(
          miniMap: tile.miniMap.wire, panoramic: tile.panoramic.wire);
      if (booted && _tiles == tiles) {
        tiles.completeTransfer(index);
      } else {
        tiles.abortTransfer();
      }
    } catch (e) {
      tiles.abortTransfer();
      AppLog.error('boot with tile ${tile.id} failed: $e', tag: _tag);
    } finally {
      _transferring = false;
    }
  }

  Future<void> _transferTile(int index) async {
    final tiles = _tiles;
    if (tiles == null || _transferring) return;
    _transferring = true;
    tiles.beginTransfer(index);
    final tile = tiles.tiles[index];
    final sw = Stopwatch()..start();
    try {
      final acked = await _card.swapMaps(
          miniMap: tile.miniMap.wire, panoramic: tile.panoramic.wire);
      if (_tiles != tiles) return; // trip changed under us
      tiles.completeTransfer(index);
      AppLog.info(
        'tile ${tile.id} on glasses in ${sw.elapsedMilliseconds} ms '
        '(L acks $acked)',
        tag: _tag,
      );
    } catch (e) {
      tiles.abortTransfer();
      AppLog.error('tile ${tile.id} transfer failed: $e', tag: _tag);
    } finally {
      _transferring = false;
    }
  }

  Future<void> _arrive() async {
    if (_state == WalkTripState.arrived) return;
    _setState(WalkTripState.arrived);
    await _card.arrived('You have arrived');
    // The firmware shows "arrived complete" for 5 s, then we end the session.
    await Future<void>.delayed(const Duration(seconds: 6));
    if (_state == WalkTripState.arrived) await stop(reason: 'arrived');
  }

  // ---- routing ------------------------------------------------------------------

  Future<void> _reroute(LatLon from) async {
    final dest = _destination;
    if (dest == null || _rerouting) return;
    final last = _lastReroute;
    if (last != null && DateTime.now().difference(last) < _rerouteCooldown) {
      return;
    }
    _rerouting = true;
    _lastReroute = DateTime.now();
    AppLog.info('off route: rerouting', tag: _tag);
    try {
      final bundle = await _fetchBundle(from, dest);
      if (bundle == null && _lastRouteError == 'no_region') {
        // Walked out of the region: keep the old route, which leads back in.
        AppLog.error('reroute: no_region; keeping the current route', tag: _tag);
      }
      if (bundle == null || !isActive) return;
      // Wait for any in-flight tile transfer to finish before swapping trips.
      while (_transferring || _state == WalkTripState.booting) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_state != WalkTripState.running) return; // stopped or arrived
      _adoptBundle(bundle);
      await _transferTile(_tiles!.desiredIndex(0));
    } finally {
      _rerouting = false;
    }
  }

  // ---- regions (plan region-sync, phase 4) -------------------------------------

  /// False, with the user told why, when the region list says this walk
  /// cannot route. Without [origin] (at share time, before any GPS) only the
  /// destination is judged. No cached list lets the server decide.
  ///
  /// The route request still omits `region_id`: the server auto-selects with
  /// the same smallest-bbox rule, so a stale phone list cannot pin a trip to
  /// the wrong region, and its `no_region` is handled after the request.
  Future<bool> _checkCoverage(LatLon dest, {LatLon? origin}) async {
    final c = tripCoverage(await RegionService.get.regionsForTrip(),
        destLat: dest.lat,
        destLon: dest.lon,
        originLat: origin?.lat,
        originLon: origin?.lon);
    switch (c.kind) {
      case CoverageKind.covered:
        AppLog.info('walk inside region ${c.region!.id}', tag: _tag);
        return true;
      case CoverageKind.unknown:
        AppLog.info('no region list; the server picks', tag: _tag);
        return true;
      case CoverageKind.split:
        AppLog.error('walk spans two regions', tag: _tag);
        await _tell('Walk: spans two areas');
        return false;
      case CoverageKind.uncovered:
        await _offerSync(c.syncLat!, c.syncLon!,
            atDestination: c.syncLat == dest.lat && c.syncLon == dest.lon);
        return false;
    }
  }

  /// Phone notification "Sync this area?" plus a glasses card. While a build
  /// is still running, says so instead of offering a second one.
  Future<void> _offerSync(double lat, double lon,
      {required bool atDestination}) async {
    final regions = RegionService.get;
    if (regions.pendingJobs.isNotEmpty) {
      AppLog.info('outside regions; a build is already running', tag: _tag);
      await _tell('Walk: area still syncing');
      return;
    }
    AppLog.info(
        'outside regions; offering a sync at the '
        '${atDestination ? 'destination' : 'origin'}',
        tag: _tag);
    await regions.offerSync(
        lat,
        lon,
        atDestination ? _destinationName : null,
        atDestination
            ? 'This walk ends outside your synced areas. Sync about 5 km '
                'around the destination, then share the walk again.'
            : 'You are outside your synced areas. Sync about 5 km around '
                'where you are, then share the walk again.');
    await _tell('Walk: outside synced areas');
  }

  /// Glasses card; ends the trip first if one is starting.
  Future<void> _tell(String message) async {
    if (isActive) {
      await _fail(message);
    } else {
      await Proto.showTitleCard(message, duration: const Duration(seconds: 2));
    }
  }

  /// Cartographer error code of the last failed route request, if any.
  String? _lastRouteError;

  Future<NavBundle?> _fetchBundle(LatLon from, LatLon to) async {
    _lastRouteError = null;
    final body = jsonEncode({
      'origin': {'lat': from.lat, 'lon': from.lon},
      'destination': {'lat': to.lat, 'lon': to.lon},
    });
    final sw = Stopwatch()..start();
    try {
      final r = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 60),
        validateStatus: (_) => true,
      )).post<String>(
        routeUrl,
        data: body,
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.plain,
        ),
      );
      if (r.statusCode != 200 || r.data == null) {
        _lastRouteError =
            RegionApiError.fromResponse(r.statusCode ?? 0, r.data).code;
        AppLog.error('route request ${r.statusCode}: ${r.data}', tag: _tag);
        return null;
      }
      final bundle = NavBundle.parse(r.data!);
      unawaited(_cache(bundle.bundleId, r.data!));
      AppLog.info('route fetched in ${sw.elapsedMilliseconds} ms', tag: _tag);
      return bundle;
    } on NavBundleException catch (e) {
      AppLog.error('bundle rejected: $e', tag: _tag);
    } catch (e) {
      AppLog.error('route request failed: $e', tag: _tag);
    }
    return null;
  }

  /// Bundles are immutable and keyed by bundle_id (contract, "caching").
  Future<void> _cache(String bundleId, String json) async {
    try {
      final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/walknav');
      await dir.create(recursive: true);
      await File('${dir.path}/$bundleId.json').writeAsString(json);
    } catch (e) {
      AppLog.error('caching bundle failed: $e', tag: _tag);
    }
  }

  /// After a BLE reconnect, put the current tile back on the glasses.
  Future<void> resyncAfterReconnect() => _resync();

  /// Re-boot the card on the tile for the current progress: after a BLE
  /// reconnect, or when the master says nav is no longer running.
  Future<void> _resync() async {
    if (_state != WalkTripState.running || _tiles == null) return;
    // Claim the resync before waiting, so a second trigger returns above.
    _setState(WalkTripState.booting);
    while (_transferring) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_state != WalkTripState.booting) return;
    AppLog.info('resync: re-booting the card', tag: _tag);
    _tiles = TileSelector(_bundle!.tiles);
    await _bootGlasses();
    if (_state != WalkTripState.booting) return; // stopped meanwhile
    _setState(WalkTripState.running);
    final last = _lastFix;
    if (last != null) await _onFix(last);
  }
}
