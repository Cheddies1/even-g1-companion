import 'dart:async';
import 'dart:typed_data';

import 'package:even_companion/models/companion_notification.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/nav_card_session.dart';
import 'package:even_companion/services/nav_manoeuvre.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';

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

/// Google Maps notification fallback for Navigate (the walking navigator is
/// the main path). Mirrors the ongoing Maps notification onto the firmware
/// `0x0a` card with blank maps and the firmware's built-in arrow.
class NavigateService {
  NavigateService._();

  static const _minTextRenderGap = Duration(milliseconds: 250);
  static const _minNavCardGap = Duration(milliseconds: 500);
  static const _textToBootstrapSettleDelay = Duration(milliseconds: 250);
  // Blank maps put no marker anywhere meaningful; centre it.
  static const _markerX = 244;
  static const _markerY = 68;

  static NavigateService? _instance;
  static NavigateService get get => _instance ??= NavigateService._();

  // -- State ----------------------------------------------------------------

  CompanionNotification? _latestInstruction;
  NavSessionState _sessionState = NavSessionState.idle;
  bool _bootstrapInFlight = false; // async-work guard, not session state
  // Bumped by _endSession; a render that started before it must not boot.
  int _sessionEpoch = 0;
  late final NavCardSession _card =
      NavCardSession(tag: 'Navigate', onLost: _resync);
  bool _isVisible = false;
  bool _renderActive = false;
  bool _renderDirty = false;
  bool _lastRenderUsedNavCard = false;
  DateTime? _lastRenderCompletedAt;

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
    _sessionEpoch++;
    final wasActive = _card.isRunning;
    _transitionTo(NavSessionState.idle, reason: reason);
    _bootstrapInFlight = false;
    if (!_isVisible) {
      _card.drop();
      return;
    }
    _isVisible = false;
    _renderDirty = false;
    await _card.exit();
    if (wasActive) AppLog.info('EXIT sent', tag: 'Navigate');
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
    final epoch = _sessionEpoch;
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
      if (epoch != _sessionEpoch) return; // ended while we waited
      await _sendNavCard(notification);
      _lastRenderUsedNavCard = true;
      return;
    }

    if (_sessionState != NavSessionState.idle) {
      // Leaving the card for text: end it, so the next card boots afresh.
      await _card.exit();
      _transitionTo(NavSessionState.idle, reason: 'text-fallback');
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
    // First card: boot with blank maps, then the status.
    if (_sessionState == NavSessionState.idle) {
      if (_bootstrapInFlight) {
        AppLog.info('bootstrap already in flight; skipping', tag: 'Navigate');
        return;
      }
      _bootstrapInFlight = true;
      _transitionTo(NavSessionState.bootstrapping);
      try {
        final booted = await _card.boot(
          miniMap: NavCardSession.blankMiniMap,
          panoramic: NavCardSession.blankPanoramic,
        );
        if (!booted || _sessionState != NavSessionState.bootstrapping) return;
        await _card.sendTripStatus(_tripStatus(_latestInstruction ?? notification));
        if (_sessionState == NavSessionState.bootstrapping) {
          _transitionTo(NavSessionState.active);
        }
      } catch (e) {
        AppLog.error('bootstrap failed: $e', tag: 'Navigate');
        _transitionTo(NavSessionState.idle, reason: 'bootstrap-failed');
        await _card.exit(); // INIT may already be on the glasses
      } finally {
        _bootstrapInFlight = false;
      }
      return;
    }

    // Subsequent updates: TRIP_STATUS only; the session keeps SYNC alive.
    if (_sessionState == NavSessionState.active) {
      await _card.sendTripStatus(_tripStatus(notification));
      return;
    }

    AppLog.debug(
      'update skipped: session=${_sessionState.name}',
      tag: 'Navigate',
    );
  }

  /// After a BLE reconnect, or when the master says nav stopped: boot again
  /// and resend the latest instruction.
  Future<void> resyncAfterReconnect() => _resync();

  Future<void> _resync() async {
    if (_latestInstruction == null || _bootstrapInFlight) return;
    if (_sessionState != NavSessionState.active) {
      await refreshVisibleView(); // text fallback, or nothing booted yet
      return;
    }
    AppLog.info('resync: re-booting the card', tag: 'Navigate');
    _card.drop();
    _transitionTo(NavSessionState.idle, reason: 'resync');
    await _scheduleRender();
  }

  Uint8List _tripStatus(CompanionNotification notification) {
    final f = _buildLiveNavFields(notification);
    // The built-in arrow is the only turn cue on this path, so classify on
    // the raw notification text: the card fields drop "Turn left" etc.
    final direction = classifyManoeuvre(
      navIconSource: f.navIconSource,
      instructionText: [
        notification.navPrimaryInfo,
        notification.navChipExpandedText,
        notification.navSecondaryInfo,
        notification.title,
        notification.text,
      ].join(' '),
    ).directionTurnByte;
    AppLog.info(
      'TRIP_STATUS: eta="${f.eta}" dist="${f.totalDistance}" '
      'road="${f.roadName}" turn="${f.turnDistance}" '
      'dir=0x${direction.toRadixString(16).padLeft(2, '0')}',
      tag: 'Navigate',
    );
    return _card.wire.tripStatus(
      direction: direction,
      x: _markerX,
      y: _markerY,
      timeRemaining: f.eta,
      distanceRemaining: f.totalDistance,
      road: f.roadName,
      turnDistance: f.turnDistance,
      speed: f.speed,
    );
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
