import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

enum NavSessionState {
  idle,
  bootstrapping,
  active,
  ended,
}

// ---------------------------------------------------------------------------
// NavigateService
// ---------------------------------------------------------------------------

class NavigateService {
  NavigateService._();

  static const _minTextRenderGap = Duration(milliseconds: 250);
  static const _minNavCardGap = Duration(milliseconds: 500);
  static const _textToBootstrapSettleDelay = Duration(milliseconds: 250);
  static const _navSyncPollInterval = Duration(seconds: 1);

  static NavigateService? _instance;
  static NavigateService get get => _instance ??= NavigateService._();

  // -- State ----------------------------------------------------------------

  CompanionNotification? _latestInstruction;
  NavSessionState _sessionState = NavSessionState.idle;
  bool _bootstrapInFlight = false; // async-work guard, not session state
  bool _isVisible = false;
  bool _renderActive = false;
  bool _renderDirty = false;
  bool _lastRenderUsedNavCard = false;
  DateTime? _lastRenderCompletedAt;
  Timer? _navSyncPoller;
  Set<String> _lastKnownAvailableLegs = {};

  // -- Public accessors -----------------------------------------------------

  CompanionNotification? get latestInstruction => _latestInstruction;
  bool get hasInstruction => _latestInstruction != null;
  bool get isVisible => _isVisible;
  bool get isShowingDetail => false;

  // -- Notification ingestion -----------------------------------------------

  bool acceptsNotification(CompanionNotification notification) {
    return _isEligibleNavigationNotification(notification);
  }

  Future<void> ingestNotification(CompanionNotification notification) async {
    if (!_isEligibleNavigationNotification(notification)) {
      return;
    }
    _latestInstruction = notification;
    AppLog.debug(
      'ingested: primary="${notification.navPrimaryInfo}" '
      'secondary="${notification.navSecondaryInfo}" '
      'subText="${notification.subText}"',
      tag: 'Navigate',
    );
  }

  // -- Mode entry / exit (called by CompanionController) --------------------

  Future<void> showLatest() async {
    await _scheduleRender();
  }

  Future<void> showIdlePrompt() async {
    if (_latestInstruction != null) {
      await _scheduleRender();
      return;
    }
    // No text sent — avoids Proto.exit() race with first bootstrap burst.
    AppLog.info('idle: no instruction yet', tag: 'Navigate');
  }

  Future<void> showDetail() async {
    await _scheduleRender();
  }

  Future<void> returnToPrimary() async {
    await _scheduleRender();
  }

  Future<void> refreshVisibleView() async {
    if (!_isVisible) return;
    await _scheduleRender();
  }

  Future<void> leaveMode() async {
    await _endSession(reason: 'leave-mode');
  }

  Future<bool> clearIfMatches({
    required String key,
    required String packageName,
  }) async {
    final latest = _latestInstruction;
    if (latest == null || !latest.isGoogleMaps) return false;
    if (latest.key != key) return false;
    _latestInstruction = null;
    await _endSession(reason: 'notification-removed');
    return true;
  }

  Future<void> close() async {
    await _endSession(reason: 'close');
  }

  // -- Session lifecycle ----------------------------------------------------

  void _transitionTo(NavSessionState newState, {String? reason}) {
    if (_sessionState == newState) return;
    final from = _sessionState.name;
    _sessionState = newState;
    AppLog.info(
      'session: $from → ${newState.name}${reason != null ? ' ($reason)' : ''}',
      tag: 'Navigate',
    );
  }

  Future<void> _endSession({required String reason}) async {
    _stopNavSyncPoller(reason: reason);
    final wasActive =
        _sessionState == NavSessionState.active ||
        _sessionState == NavSessionState.bootstrapping;
    _transitionTo(NavSessionState.idle, reason: reason);
    _bootstrapInFlight = false;
    _lastKnownAvailableLegs = {};
    if (!_isVisible) return;
    _isVisible = false;
    _renderDirty = false;
    if (wasActive) {
      await Proto.sendNavModeExit();
      AppLog.info('EXIT sent', tag: 'Navigate');
    }
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
  }

  // -- Render scheduling ----------------------------------------------------

  Future<void> _scheduleRender() async {
    _renderDirty = true;
    if (_renderActive) return;

    _renderActive = true;
    try {
      while (_renderDirty && (_isVisible || _latestInstruction != null)) {
        _renderDirty = false;
        await _renderCurrentView();
        _lastRenderCompletedAt = DateTime.now();
      }
    } finally {
      _renderActive = false;
    }
  }

  Future<void> _renderCurrentView() async {
    final notification = _latestInstruction;
    _isVisible = true;

    final useNavCard = notification != null && _shouldUseNavCard(notification);
    final minGap = _lastRenderUsedNavCard ? _minNavCardGap : _minTextRenderGap;
    final gap = _lastRenderCompletedAt == null
        ? Duration.zero
        : DateTime.now().difference(_lastRenderCompletedAt!);
    if (_lastRenderCompletedAt != null && gap < minGap) {
      await Future<void>.delayed(minGap - gap);
    }

    if (useNavCard) {
      await _prepareForBootstrapIfNeeded();
      await TextService.get.stopTextSendingByOS();
      await _sendNavCard(notification);
      _lastRenderUsedNavCard = true;
      return;
    }

    final text = _buildTextFallback(notification);
    await TextService.get.startSendText(text);
    _lastRenderUsedNavCard = false;
  }

  Future<void> _prepareForBootstrapIfNeeded() async {
    if (_lastRenderUsedNavCard || !_isVisible) return;
    AppLog.info('closing text fallback before bootstrap', tag: 'Navigate');
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    await Future<void>.delayed(_textToBootstrapSettleDelay);
  }

  // -- Nav card send --------------------------------------------------------

  Future<void> _sendNavCard(CompanionNotification notification) async {
    final fields = _buildLiveNavFields(notification);

    // First card: full bootstrap.
    if (_sessionState == NavSessionState.idle) {
      if (_bootstrapInFlight) {
        AppLog.info('bootstrap already in flight; skipping', tag: 'Navigate');
        return;
      }
      _bootstrapInFlight = true;
      _transitionTo(NavSessionState.bootstrapping);
      Proto.setBootstrapTripStatus(
        eta: fields.eta,
        totalDistance: fields.totalDistance,
        roadName: fields.roadName,
        turnDistance: fields.turnDistance,
        speed: fields.speed,
        navIconSource: fields.navIconSource,
        navIconPngBase64: fields.navIconPngBase64,
      );
      try {
        await Proto.sendNavBootstrap();
        _transitionTo(NavSessionState.active);
        _startNavSyncPoller();
      } catch (e) {
        AppLog.error('bootstrap failed: $e', tag: 'Navigate');
        _transitionTo(NavSessionState.idle, reason: 'bootstrap-failed');
      } finally {
        _bootstrapInFlight = false;
      }
      return;
    }

    // Subsequent updates: TRIP_STATUS + SYNC.
    if (_sessionState == NavSessionState.active) {
      await Proto.sendNavTripStatusAndSync(
        eta: fields.eta,
        distance: fields.totalDistance,
        roadName: fields.roadName,
        turnDistance: fields.turnDistance,
        speed: fields.speed,
        navIconSource: fields.navIconSource,
      );
      _startNavSyncPoller();
      return;
    }

    // Bootstrapping or ended — ignore update.
    AppLog.debug(
      'update skipped: session=${_sessionState.name}',
      tag: 'Navigate',
    );
  }

  // -- SYNC poller ----------------------------------------------------------

  void _startNavSyncPoller() {
    if (_sessionState != NavSessionState.active) return;
    if (!_isVisible || _latestInstruction == null) return;
    if (_navSyncPoller != null) return;
    _lastKnownAvailableLegs = _currentAvailableLegs();
    _navSyncPoller = Timer.periodic(_navSyncPollInterval, (_) {
      unawaited(_sendNavSyncTick());
    });
    AppLog.info('SYNC poller started', tag: 'Navigate');
  }

  Future<void> _sendNavSyncTick() async {
    if (_sessionState != NavSessionState.active) {
      _stopNavSyncPoller(reason: 'session-not-active');
      return;
    }

    final currentLegs = _currentAvailableLegs();
    if (currentLegs.isEmpty) {
      _stopNavSyncPoller(reason: 'transport-unavailable');
      return;
    }

    // Detect leg recovery — resend current state to the recovered leg.
    final recovered = currentLegs.difference(_lastKnownAvailableLegs);
    _lastKnownAvailableLegs = currentLegs;
    if (recovered.isNotEmpty && _latestInstruction != null) {
      AppLog.info(
        'leg recovered: ${recovered.join(",")} — resending nav state',
        tag: 'Navigate',
      );
      final fields = _buildLiveNavFields(_latestInstruction!);
      await Proto.sendNavTripStatusAndSync(
        eta: fields.eta,
        distance: fields.totalDistance,
        roadName: fields.roadName,
        turnDistance: fields.turnDistance,
        speed: fields.speed,
        navIconSource: fields.navIconSource,
      );
      return; // sent SYNC as part of the update
    }

    if (_bootstrapInFlight) return;
    await Proto.sendNavSync();
  }

  void _stopNavSyncPoller({required String reason}) {
    final poller = _navSyncPoller;
    if (poller == null) return;
    poller.cancel();
    _navSyncPoller = null;
    AppLog.info('SYNC poller stopped: $reason', tag: 'Navigate');
  }

  Set<String> _currentAvailableLegs() {
    return {'L', 'R'}
        .where((lr) => BleManager.get().isLegAvailable(lr))
        .toSet();
  }

  // -- Field extraction -----------------------------------------------------

  /// Matches values that look like a turn distance: "100 yd", "0.4 mi", etc.
  static final _distancePattern = RegExp(
    r'^\d+(\.\d+)?\s*(yd|mi|km|m|ft)s?$',
    caseSensitive: false,
  );

  ({
    String eta,
    String totalDistance,
    String roadName,
    String turnDistance,
    String speed,
    String navIconSource,
    String navIconPngBase64,
  }) _buildLiveNavFields(CompanionNotification notification) {
    // turnDistance: only accept values that look like distances.
    // Google Maps sometimes puts road names or destination labels in
    // navPrimaryInfo (e.g. "towards Milton Rd", "Home (36 Campbell Rd)").
    final rawTurn = _clean(
      notification.navPrimaryInfo.isNotEmpty
          ? notification.navPrimaryInfo
          : notification.navChipExpandedText,
    );
    final turnDistance = _distancePattern.hasMatch(rawTurn) ? rawTurn : '';

    // roadName: clean text, no Unicode direction prefix (real icons replace it).
    final roadName = _clean(
      notification.navSecondaryInfo.isNotEmpty
          ? notification.navSecondaryInfo
          : notification.text.isNotEmpty
              ? notification.text
              : notification.title,
    );

    // ETA + total distance from subText: "30 min · 1.4 mi · 22:16 ETA"
    final meta = _clean(notification.subText);
    String eta = meta;
    String totalDistance = '';
    final separator =
        meta.contains('·') ? '·' : (meta.contains('•') ? '•' : '');
    if (separator.isNotEmpty) {
      final parts = meta.split(separator).map((s) => s.trim()).toList();
      eta = parts.isNotEmpty ? parts[0] : meta;
      totalDistance = parts.length > 1 ? parts[1] : '';
    }

    return (
      eta: eta,
      totalDistance: totalDistance,
      roadName: roadName,
      turnDistance: turnDistance,
      speed: '0.0km/h',
      navIconSource: notification.navIconSource,
      navIconPngBase64: notification.navIconPngBase64,
    );
  }

  // -- Notification eligibility ---------------------------------------------

  bool _shouldUseNavCard(CompanionNotification notification) {
    final primary = _clean(
      notification.navPrimaryInfo.isNotEmpty
          ? notification.navPrimaryInfo
          : notification.navChipExpandedText.isNotEmpty
              ? notification.navChipExpandedText
              : notification.title,
    );
    final secondary = _clean(
      notification.navSecondaryInfo.isNotEmpty
          ? notification.navSecondaryInfo
          : notification.text,
    );

    if (primary.isEmpty && secondary.isEmpty) return false;

    final combined =
        '$primary $secondary ${notification.subText}'.toLowerCase();
    if (combined.contains('start navigation') ||
        combined.contains('starting navigation') ||
        combined == 'google maps') {
      return false;
    }

    return true;
  }

  bool _isEligibleNavigationNotification(CompanionNotification notification) {
    if (!notification.isGoogleMaps) return false;
    if (!notification.hasNavigationPayload) return false;

    final category = notification.category.toLowerCase();
    final channelId = notification.channelId.toLowerCase();
    final tag = notification.tag.toLowerCase();
    final combined = _clean(
      [
        notification.title,
        notification.text,
        notification.bigText,
        notification.subText,
        notification.message,
        notification.navPrimaryInfo,
        notification.navSecondaryInfo,
        notification.navChipExpandedText,
      ].join(' '),
    ).toLowerCase();

    final hasStrongNavFields = notification.navPrimaryInfo.isNotEmpty &&
        (notification.navSecondaryInfo.isNotEmpty ||
            notification.navIconPngBase64.isNotEmpty ||
            notification.navChipExpandedText.isNotEmpty);
    final hasOngoingSignal = notification.isOngoing ||
        category == 'navigation' ||
        category == 'transport' ||
        channelId.contains('navigation') ||
        tag.contains('navigation');

    if (!hasStrongNavFields) return false;
    if (!hasOngoingSignal) return false;

    if (combined.contains('review') ||
        combined.contains('rate this place') ||
        combined.contains('open your phone for details') ||
        combined.contains('saved place') ||
        combined.contains('want to review') ||
        combined.contains('add a photo')) {
      return false;
    }

    return true;
  }

  // -- Text fallback --------------------------------------------------------

  String _buildTextFallback(CompanionNotification? notification) {
    if (notification == null) return 'Start navigation in Google Maps';

    final primary = _clean(
      notification.navPrimaryInfo.isNotEmpty
          ? notification.navPrimaryInfo
          : notification.navChipExpandedText.isNotEmpty
              ? notification.navChipExpandedText
              : notification.title,
    );
    final secondary = _clean(
      notification.navSecondaryInfo.isNotEmpty
          ? notification.navSecondaryInfo
          : notification.text.isNotEmpty
              ? notification.text
              : notification.message,
    );
    final meta = _clean(notification.subText);

    final lines = <String>[];
    if (primary.isNotEmpty) lines.add(primary);
    if (secondary.isNotEmpty && secondary != primary) lines.add(secondary);
    if (meta.isNotEmpty) lines.add(meta);

    return lines.isEmpty ? 'Waiting for Google Maps' : lines.join('\n');
  }

  // -- Utilities ------------------------------------------------------------

  String _clean(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
