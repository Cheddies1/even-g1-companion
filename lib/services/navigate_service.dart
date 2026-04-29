import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class NavigateService {
  NavigateService._();

  static const _minTextRenderGap = Duration(milliseconds: 250);
  static const _minNavCardGap = Duration(milliseconds: 500);
  static const _textToNavReplaySettleDelay = Duration(milliseconds: 250);
  static const _navSyncPollInterval = Duration(seconds: 1);
  static const String navUpdateModeFullLifecycle = 'fullLifecycleUpdate';
  static const String navUpdateModeTripStatusOnly = 'tripStatusOnlyUpdate';

  static const String _navUpdateMode = navUpdateModeTripStatusOnly;

  static NavigateService? _instance;
  static NavigateService get get => _instance ??= NavigateService._();

  CompanionNotification? _latestInstruction;
  bool _isVisible = false;
  bool _renderActive = false;
  bool _renderDirty = false;
  bool _lastRenderUsedNavCard = false;
  bool _navModeEntered = false;
  bool _navReplayInFlight = false;
  DateTime? _lastRenderCompletedAt;
  Timer? _pendingIdlePromptTimer;
  Timer? _navSyncPoller;

  CompanionNotification? get latestInstruction => _latestInstruction;
  bool get hasInstruction => _latestInstruction != null;
  bool get isVisible => _isVisible;
  bool get isShowingDetail => false;

  bool acceptsNotification(CompanionNotification notification) {
    return _isEligibleNavigationNotification(notification);
  }

  Future<void> ingestNotification(CompanionNotification notification) async {
    if (!_isEligibleNavigationNotification(notification)) {
      AppLog.info(
        '${DateTime.now()} Navigate: ignored notification key=${notification.key} package=${notification.packageName} category=${notification.category} ongoing=${notification.isOngoing} channel=${notification.channelId}',
      );
      return;
    }
    _cancelPendingIdlePrompt(reason: 'notification-arrived');
    _latestInstruction = notification;
    AppLog.debug(
      '${DateTime.now()} Navigate: payload primary="${notification.navPrimaryInfo}" secondary="${notification.navSecondaryInfo}" subText="${notification.subText}" iconSource="${notification.navIconSource}"',
    );
  }

  Future<void> showLatest() async {
    _cancelPendingIdlePrompt(reason: 'show-latest');
    await _scheduleRender();
  }

  Future<void> showIdlePrompt() async {
    if (_latestInstruction != null) {
      await _scheduleRender();
      return;
    }
    // Do NOT send idle text to the glasses. The old "Open Google Maps…" prompt
    // required a Proto.exit() cleanup before the first nav replay, and that
    // exit command raced with the 108-packet burst causing blank lenses.
    // Leaving the glasses on whatever was displayed before is harmless — the
    // first Maps notification will push the full nav card.
    AppLog.info(
      '${DateTime.now()} idle prompt suppressed (no text sent to avoid first-load race)',
      tag: 'Navigate',
    );
  }

  Future<void> showDetail() async {
    await _scheduleRender();
  }

  Future<void> returnToPrimary() async {
    await _scheduleRender();
  }

  Future<void> refreshVisibleView() async {
    if (!_isVisible) {
      return;
    }
    await _scheduleRender();
  }

  Future<bool> clearIfMatches({
    required String key,
    required String packageName,
  }) async {
    final latest = _latestInstruction;
    if (latest == null || !latest.isGoogleMaps) {
      return false;
    }
    final sameKey = latest.key == key;
    if (!sameKey) {
      return false;
    }
    _latestInstruction = null;
    await close();
    AppLog.info(
      '${DateTime.now()} cleared after notification removal',
      tag: 'Navigate',
    );
    return true;
  }

  Future<void> close() async {
    _cancelPendingIdlePrompt(reason: 'close');
    _stopNavSyncPoller(reason: 'close');
    if (!_isVisible) {
      return;
    }
    _isVisible = false;
    _renderDirty = false;
    _navModeEntered = false;
    _navReplayInFlight = false;
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    AppLog.info('${DateTime.now()} closed', tag: 'Navigate');
  }

  Future<void> leaveMode() async {
    await close();
  }

  bool get _isNavSessionActive => _navModeEntered || _navSyncPoller != null;

  Future<void> _scheduleRender() async {
    _cancelPendingIdlePrompt(reason: 'schedule-render');
    _renderDirty = true;
    if (_renderActive) {
      return;
    }

    _renderActive = true;
    try {
      while (_renderDirty && _isVisibleOrShouldBecomeVisible()) {
        _renderDirty = false;
        await _renderCurrentView();
        _lastRenderCompletedAt = DateTime.now();
      }
    } finally {
      _renderActive = false;
    }
  }

  bool _isVisibleOrShouldBecomeVisible() {
    return _isVisible || _latestInstruction != null;
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
      await _prepareForNavCardReplayIfNeeded();
      await TextService.get.stopTextSendingByOS();
      await _sendNavCard(notification);
      _lastRenderUsedNavCard = true;
      AppLog.debug('${DateTime.now()} render -> nav-card', tag: 'Navigate');
      return;
    }

    final text = _buildTextFallback(notification);
    await TextService.get.startSendText(text);
    _lastRenderUsedNavCard = false;
    AppLog.debug('${DateTime.now()} render -> text-fallback', tag: 'Navigate');
  }

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

    if (primary.isEmpty && secondary.isEmpty) {
      return false;
    }

    final combined =
        '$primary $secondary ${notification.subText}'.toLowerCase();
    if (combined.contains('start navigation') ||
        combined.contains('starting navigation') ||
        combined == 'google maps') {
      return false;
    }

    return true;
  }

  /// Map the notification's icon-source label to a Unicode arrow for use
  /// as a text-based direction hint in the nav card's road-name field.
  /// The `0x0a 02` icon bitmap is now dynamically generated from the Maps
  /// notification PNG; this Unicode hint supplements it in the text fields.
  static String _directionHint(String iconSource) {
    final lower = iconSource.toLowerCase();
    if (lower.contains('u-turn') || lower.contains('uturn')) return '↩ ';
    if (lower.contains('sharp') && lower.contains('left')) return '↰ ';
    if (lower.contains('sharp') && lower.contains('right')) return '↱ ';
    if (lower.contains('slight') && lower.contains('left')) return '↖ ';
    if (lower.contains('slight') && lower.contains('right')) return '↗ ';
    if (lower.contains('left')) return '← ';
    if (lower.contains('right')) return '→ ';
    if (lower.contains('straight') || lower.contains('continue')) return '↑ ';
    if (lower.contains('arrive') || lower.contains('destination')) return '◉ ';
    if (lower.contains('merge')) return '↗ ';
    if (lower.contains('roundabout')) return '↻ ';
    return '';
  }

  Future<void> _sendNavCard(CompanionNotification notification) async {
    final fields = _buildLiveNavFields(notification);
    if (!_navModeEntered) {
      if (_navReplayInFlight) {
        AppLog.info(
          '${DateTime.now()} nav replay already in flight; skipping duplicate trigger',
          tag: 'Navigate',
        );
        return;
      }
      _navReplayInFlight = true;
      _navModeEntered = true;
      Proto.setReplayTripStatus(
        eta: fields.eta,
        totalDistance: fields.totalDistance,
        roadName: fields.roadName,
        turnDistance: fields.turnDistance,
        speed: fields.speed,
        navIconSource: fields.navIconSource,
        navIconPngBase64: fields.navIconPngBase64,
      );
      // DEBUG: Use replay test with exact snoop bytes to isolate
      // whether the issue is packet format or something deeper.
      try {
        await Proto.sendNavCardReplayTest();
        _startNavSyncPollerIfActive();
      } finally {
        _navReplayInFlight = false;
      }
      return; // skip normal card — replay test covers it
    }

    AppLog.info('${DateTime.now()} nav update mode=$_navUpdateMode',
        tag: 'Navigate');
    if (_navUpdateMode == navUpdateModeTripStatusOnly) {
      AppLog.info(
        '${DateTime.now()} nav update sent as TRIP_STATUS+SYNC',
        tag: 'Navigate',
      );
      await Proto.sendNavTripStatusAndSync(
        eta: fields.eta,
        distance: fields.totalDistance,
        roadName: fields.roadName,
        turnDistance: fields.turnDistance,
        speed: fields.speed,
        navIconSource: fields.navIconSource,
      );
      _startNavSyncPollerIfActive();
      return;
    }

    if (_navReplayInFlight) {
      AppLog.info(
        '${DateTime.now()} nav replay already in flight; skipping duplicate full lifecycle update',
        tag: 'Navigate',
      );
      return;
    }

    AppLog.info(
      '${DateTime.now()} nav update sent as full lifecycle',
      tag: 'Navigate',
    );
    _navReplayInFlight = true;
    Proto.setReplayTripStatus(
      eta: fields.eta,
      totalDistance: fields.totalDistance,
      roadName: fields.roadName,
      turnDistance: fields.turnDistance,
      speed: fields.speed,
      navIconSource: fields.navIconSource,
    );
    try {
      await Proto.sendNavCardReplayTest();
      _startNavSyncPollerIfActive();
    } finally {
      _navReplayInFlight = false;
    }
  }

  ({
    String eta,
    String totalDistance,
    String roadName,
    String turnDistance,
    String speed,
    String navIconSource,
    String navIconPngBase64,
  }) _buildLiveNavFields(CompanionNotification notification) {
    final turnDistance = _clean(
      notification.navPrimaryInfo.isNotEmpty
          ? notification.navPrimaryInfo
          : notification.navChipExpandedText,
    );
    final dirHint = _directionHint(notification.navIconSource);
    final rawRoad = _clean(
      notification.navSecondaryInfo.isNotEmpty
          ? notification.navSecondaryInfo
          : notification.text.isNotEmpty
              ? notification.text
              : notification.title,
    );
    final roadName = '$dirHint$rawRoad';
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

  Future<void> _prepareForNavCardReplayIfNeeded() async {
    if (_lastRenderUsedNavCard || !_isVisible) {
      return;
    }
    AppLog.info(
      '${DateTime.now()} closing text fallback before nav replay',
      tag: 'Navigate',
    );
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    await Future<void>.delayed(_textToNavReplaySettleDelay);
  }

  void _startNavSyncPollerIfActive() {
    if (!_navModeEntered || !_isVisible || _latestInstruction == null) {
      return;
    }
    if (_navSyncPoller != null) {
      return;
    }
    AppLog.info(
      '${DateTime.now()} nav SYNC poller started',
      tag: 'Navigate',
    );
    _navSyncPoller = Timer.periodic(_navSyncPollInterval, (_) {
      unawaited(_sendNavSyncTick());
    });
  }

  Future<void> _sendNavSyncTick() async {
    if (!_navModeEntered || !_isVisible || _latestInstruction == null) {
      _stopNavSyncPoller(reason: 'session-inactive');
      return;
    }
    if (_navReplayInFlight) {
      return;
    }
    final hasAvailableLeg = BleManager.get().isLegAvailable('L') ||
        BleManager.get().isLegAvailable('R');
    if (!hasAvailableLeg) {
      _stopNavSyncPoller(reason: 'transport-unavailable');
      return;
    }
    await Proto.sendNavSync();
  }

  void _stopNavSyncPoller({required String reason}) {
    final poller = _navSyncPoller;
    if (poller == null) {
      return;
    }
    poller.cancel();
    _navSyncPoller = null;
    AppLog.info(
      '${DateTime.now()} nav SYNC poller stopped reason=$reason',
      tag: 'Navigate',
    );
  }

  bool _isEligibleNavigationNotification(CompanionNotification notification) {
    if (!notification.isGoogleMaps) {
      return false;
    }

    if (!notification.hasNavigationPayload) {
      return false;
    }

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

    if (!hasStrongNavFields) {
      return false;
    }

    if (!hasOngoingSignal) {
      return false;
    }

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

  String _buildTextFallback(CompanionNotification? notification) {
    if (notification == null) {
      return 'Start navigation in Google Maps';
    }

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
    if (primary.isNotEmpty) {
      lines.add(primary);
    }
    if (secondary.isNotEmpty && secondary != primary) {
      lines.add(secondary);
    }
    if (meta.isNotEmpty) {
      lines.add(meta);
    }

    if (lines.isEmpty) {
      return 'Waiting for Google Maps';
    }

    return lines.join('\n');
  }

  String _clean(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void _cancelPendingIdlePrompt({required String reason}) {
    final timer = _pendingIdlePromptTimer;
    if (timer == null) {
      return;
    }
    timer.cancel();
    _pendingIdlePromptTimer = null;
    AppLog.info(
      '${DateTime.now()} idle prompt cancelled: reason=$reason',
      tag: 'Navigate',
    );
  }
}
