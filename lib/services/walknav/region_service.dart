import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/walknav/region_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Walking regions on cartographer (plan region-sync, phase 3): list (cached
/// for offline display), pin, rename, delete and "sync here".
///
/// A build is a server background job. After the POST, the job id goes to the
/// Android side (`RegionJobWorker`, WorkManager), which persists it, polls with
/// the screen off or the app closed, and posts the ready/failed notification.
/// Dart only hears about it to refresh the list.
class RegionService extends ChangeNotifier {
  RegionService._();
  static final RegionService get = RegionService._();

  static const String baseUrl = 'https://deepthought.tail082c0b.ts.net:9446';
  static const _tag = 'Regions';
  static const _cacheKey = 'walknav.regions.cache';
  static const _method = MethodChannel('method.bluetooth');
  static const _events = EventChannel('eventRegions');

  final Dio _dio = Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (_) => true,
    responseType: ResponseType.plain,
  ));

  StreamSubscription<dynamic>? _sub;
  List<WalkRegion> _regions = const [];
  List<PendingRegionJob> _pending = const [];
  DateTime? _fetchedAt;
  bool _loading = false;
  bool _syncing = false;
  String? _lastError;

  List<WalkRegion> get regions => _regions;
  List<PendingRegionJob> get pendingJobs => _pending;
  DateTime? get fetchedAt => _fetchedAt;
  bool get loading => _loading;
  bool get syncing => _syncing;

  /// Set when the last refresh failed; the list is then the cached copy.
  String? get lastError => _lastError;

  Future<void> init() async {
    if (_sub != null) return;
    _sub = _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: (Object e) =>
              AppLog.error('region event stream error: $e', tag: _tag),
        );
    final prefs = await SharedPreferences.getInstance();
    final cached = decodeRegionCache(prefs.getString(_cacheKey));
    if (cached != null && _fetchedAt == null) {
      _regions = cached.regions;
      _fetchedAt = cached.fetchedAt;
      notifyListeners();
    }
    await _loadPending();
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['kind']) {
      case 'jobUpdate':
        unawaited(_loadPending());
      case 'jobFinished':
        AppLog.info(
            'job ${raw['jobId']} ${raw['state']} (${raw['regionId']})',
            tag: _tag);
        unawaited(_loadPending());
        unawaited(refresh());
      case 'debugSync':
        final lat = (raw['lat'] as num?)?.toDouble();
        final lon = (raw['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) {
          AppLog.error('debug sync without a valid "at"', tag: _tag);
          return;
        }
        unawaited(syncAt(lat, lon,
                name: raw['name'] as String?, pinned: raw['pinned'] == true)
            .then((msg) => AppLog.info('debug sync: $msg', tag: _tag)));
    }
  }

  Future<void> _loadPending() async {
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('regionJobsPending');
      _pending = (raw ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(PendingRegionJob.fromMap)
          .toList();
      notifyListeners();
    } catch (e) {
      AppLog.error('reading pending jobs failed: $e', tag: _tag);
    }
  }

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      final r = await _dio.get<String>('/v1/regions');
      if (r.statusCode != 200 || r.data == null) {
        throw RegionApiError.fromResponse(r.statusCode ?? 0, r.data);
      }
      final parsed = parseRegionList(r.data!);
      if (parsed.skipped > 0) {
        AppLog.error('skipped ${parsed.skipped} malformed region(s)', tag: _tag);
      }
      _regions = parsed.regions;
      _fetchedAt = DateTime.now().toUtc();
      _lastError = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, encodeRegionCache(_regions, _fetchedAt!));
    } catch (e) {
      _lastError = e is RegionApiError ? e.userMessage : 'Server unreachable.';
      AppLog.error('region list failed: $e', tag: _tag);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Returns null on success, else a user-facing message.
  Future<String?> setPinned(WalkRegion region, bool pinned) =>
      _patch(region, {'pinned': pinned});

  Future<String?> rename(WalkRegion region, String name) =>
      _patch(region, {'name': name.trim()});

  Future<String?> _patch(WalkRegion region, Map<String, dynamic> body) async {
    try {
      final r = await _dio.patch<String>(
        '/v1/regions/${Uri.encodeComponent(region.id)}',
        data: jsonEncode(body),
        options: Options(contentType: 'application/json'),
      );
      if (r.statusCode != 200) {
        throw RegionApiError.fromResponse(r.statusCode ?? 0, r.data);
      }
      AppLog.info('patched ${region.id}: $body', tag: _tag);
      await refresh();
      return null;
    } on RegionApiError catch (e) {
      AppLog.error('patch ${region.id} failed: $e', tag: _tag);
      return e.userMessage;
    } catch (e) {
      AppLog.error('patch ${region.id} failed: $e', tag: _tag);
      return 'Server unreachable.';
    }
  }

  Future<String?> delete(WalkRegion region) async {
    try {
      final r = await _dio
          .delete<String>('/v1/regions/${Uri.encodeComponent(region.id)}');
      if (r.statusCode != 200) {
        throw RegionApiError.fromResponse(r.statusCode ?? 0, r.data);
      }
      AppLog.info('deleted ${region.id}', tag: _tag);
      await refresh();
      return null;
    } on RegionApiError catch (e) {
      AppLog.error('delete ${region.id} failed: $e', tag: _tag);
      return e.userMessage;
    } catch (e) {
      AppLog.error('delete ${region.id} failed: $e', tag: _tag);
      return 'Server unreachable.';
    }
  }

  /// Refresh the list for a trip-start check, but never hold the trip up
  /// for long: on timeout or failure the cached list stands.
  Future<List<WalkRegion>> regionsForTrip(
      {Duration timeout = const Duration(seconds: 6)}) async {
    try {
      await Future.wait([refresh(), _loadPending()]).timeout(timeout);
    } on TimeoutException {
      AppLog.error('region refresh slow; using the cached list', tag: _tag);
    }
    return _regions;
  }

  /// Phone notification offering a build at [lat],[lon]; its action starts
  /// the build on the Android side, so the app need not be open.
  /// [name], when known (the shared place), names the region the offer
  /// builds; without it the server's coordinate-derived id stands in.
  Future<void> offerSync(
      double lat, double lon, String? name, String text) async {
    try {
      await _method.invokeMethod<void>('regionOfferSync', {
        'baseUrl': baseUrl,
        'lat': lat,
        'lon': lon,
        'name': name,
        'text': text,
      });
    } catch (e) {
      AppLog.error('sync offer failed: $e', tag: _tag);
    }
  }

  /// One fresh fix from the phone, for "Sync current location".
  Future<({double lat, double lon, double? acc})?> currentFix() async {
    try {
      final m = await _method.invokeMapMethod<String, dynamic>('regionCurrentFix');
      if (m == null) return null;
      return (
        lat: (m['lat'] as num).toDouble(),
        lon: (m['lon'] as num).toDouble(),
        acc: (m['acc'] as num?)?.toDouble(),
      );
    } catch (e) {
      AppLog.error('current fix failed: $e', tag: _tag);
      return null;
    }
  }

  /// Starts a build centred on [lat],[lon]. Returns a user-facing message.
  ///
  /// The POST is not idempotent (contract): on a lost response this does not
  /// retry; it refreshes the list so a build that did start shows up there.
  Future<String> syncAt(double lat, double lon,
      {String? name, bool pinned = false}) async {
    if (_syncing) return 'A sync request is already in progress.';
    _syncing = true;
    notifyListeners();
    try {
      final body = <String, dynamic>{'lat': lat, 'lon': lon, 'pinned': pinned};
      final trimmed = name?.trim();
      if (trimmed != null && trimmed.isNotEmpty) body['name'] = trimmed;
      final Response<String> r;
      try {
        r = await _dio.post<String>(
          '/v1/regions',
          data: jsonEncode(body),
          options: Options(contentType: 'application/json'),
        );
      } catch (e) {
        AppLog.error('build request failed: $e', tag: _tag);
        unawaited(refresh());
        return 'No reply from the server. Check the list before retrying.';
      }
      if (r.statusCode != 202) {
        final err = RegionApiError.fromResponse(r.statusCode ?? 0, r.data);
        AppLog.error('build rejected: $err', tag: _tag);
        return err.userMessage;
      }
      final accepted = parseBuildAccepted(r.data ?? '');
      final label = trimmed?.isNotEmpty == true ? trimmed! : accepted.regionId;
      AppLog.info('build ${accepted.jobId} for ${accepted.regionId} accepted',
          tag: _tag);
      await _method.invokeMethod<void>('regionJobWatch', {
        'baseUrl': baseUrl,
        'jobId': accepted.jobId,
        'regionId': accepted.regionId,
        'name': label,
      });
      await _loadPending();
      return 'Building "$label". You will get a notification when it is ready.';
    } catch (e) {
      AppLog.error('sync failed: $e', tag: _tag);
      return 'Sync failed: $e';
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }
}
