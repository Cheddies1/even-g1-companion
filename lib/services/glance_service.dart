import 'dart:async';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/companion_notification.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/device_status_service.dart';
import 'package:even_companion/services/glance_carousel.dart';
import 'package:even_companion/services/notification_policy.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';

enum CallPhase { ringing, active }

class GlanceService {
  GlanceService._();

  static GlanceService? _instance;
  static GlanceService get get => _instance ??= GlanceService._();

  static const _displayDuration = Duration(seconds: 3);

  /// Tilt-up recall renders on the tap-enabled 0x4E surface so single taps
  /// page the carousel: right = read, next; left = back. Auto-pops and the
  /// call HUD stay on the usual full-width surface. Flip to false to get the
  /// pre-2026-11-06 behaviour back (no taps, no "Even AI Listening" flash on
  /// open).
  static const bool tapPagingEnabled = true;

  /// Line budget in characters for the time line. The tap surface's Even AI
  /// layout is 472 px wide against 576 for the full-width one.
  static const _lineBudgetFullWidth = 43;
  static const _lineBudgetTapLayout = 35;
  static const _maxNotifications = 20;
  static const _mediaTimeout = Duration(seconds: 60);

  final GlanceCarousel<CompanionNotification> _carousel =
      GlanceCarousel<CompanionNotification>(
    keyOf: (n) => n.key,
    isDismissible: NotificationPolicy.canDismissFromGlance,
    maxItems: _maxNotifications,
  );
  Timer? _clearTimer;
  Timer? _mediaTimeoutTimer;
  Timer? _callTimer;
  bool _isVisible = false;
  bool _isIdleSurfaceActive = false;
  Future<void> _renderChain = Future<void>.value();
  CompanionNotification? _currentMedia;
  CompanionNotification? _currentCall;

  CallPhase? _callPhase;
  String? _callDisplayName;
  String? _callNumber;
  DateTime? _callAnsweredAt;
  bool _callIsOutgoing = false;

  bool get _hasActiveCall => _callPhase != null || _currentCall != null;

  bool get isVisible => _isVisible;

  /// True when the carousel is up on the tap-enabled surface, so `F5 01`
  /// should page it.
  bool get isTapPagingActive =>
      tapPagingEnabled &&
      _isVisible &&
      !_isIdleSurfaceActive &&
      Proto.isTapSurfaceOpen;
  int get notificationCount => _carousel.length;
  bool get isInActiveRecall => _isVisible;

  List<CompanionNotification> get notifications =>
      _carousel.items;

  void hydrateNotifications(List<CompanionNotification> notifications) {
    _carousel.hydrate(notifications);
    AppLog.debug(
      '${DateTime.now()} hydrated notifications -> count=${_carousel.length}',
      tag: 'Glance',
    );
  }

  void updateMedia(CompanionNotification notification) {
    _currentMedia = notification;
    _mediaTimeoutTimer?.cancel();
    _mediaTimeoutTimer = Timer(_mediaTimeout, () {
      _currentMedia = null;
      _mediaTimeoutTimer = null;
      if (_isVisible) {
        _enqueueRender(autoHide: false, markInteracted: false);
      }
      AppLog.info(
        '${DateTime.now()} media cleared by timeout',
        tag: 'Glance',
      );
    });
    AppLog.info(
      '${DateTime.now()} media updated -> ${notification.title} / ${notification.text}',
      tag: 'Glance',
    );
    if (_isVisible) {
      _enqueueRender(autoHide: false, markInteracted: false);
    }
  }

  void clearMedia(String key) {
    if (_currentMedia?.key != key) {
      return;
    }
    _currentMedia = null;
    _mediaTimeoutTimer?.cancel();
    _mediaTimeoutTimer = null;
    AppLog.info(
      '${DateTime.now()} media cleared -> $key',
      tag: 'Glance',
    );
    if (_isVisible) {
      _enqueueRender(autoHide: false, markInteracted: false);
    }
  }

  /// Primary call-HUD driver. The telephony [handleTelephonyState] path is
  /// unreliable on some devices (Samsung One UI never delivers
  /// `onCallStateChanged`), so the CallStyle notification — which carries
  /// `callType` and the connect time — drives the HUD directly. The HUD is
  /// forced onto the display immediately on call start, not deferred to the
  /// next idle-surface takeover.
  void updateCall(CompanionNotification notification) {
    final phase = _callPhaseFromNotification(notification);
    final name =
        notification.title.isNotEmpty ? notification.title : notification.source;
    // Only re-render when something the user can see has changed, or when the
    // HUD is not currently asserted — the per-second timer covers active-call
    // duration ticks, so identical refreshes must not flood the transport.
    final changed = _callPhase != phase ||
        _callDisplayName != name ||
        _currentCall == null ||
        !_isIdleSurfaceActive;

    _currentCall = notification;
    _callPhase = phase;
    _callDisplayName = name;
    _callNumber = null;
    _callIsOutgoing = false;

    if (phase == CallPhase.active) {
      // Lock in the answer time on the first transition to active and don't
      // overwrite it on later updates — Samsung's incallui rewrites
      // `notification.when` from ring-start to answer-time when the user picks
      // up, which would otherwise yank the timer back to 0.
      _callAnsweredAt ??= notification.connectedAt ?? DateTime.now();
      _startCallTimerIfNeeded();
    } else {
      _callAnsweredAt = null;
      _callTimer?.cancel();
      _callTimer = null;
    }

    if (changed) {
      // A call takes over the surface — drop any pending auto-dismiss so the
      // HUD is not torn down underneath us.
      _clearTimer?.cancel();
      _clearTimer = null;
      _isIdleSurfaceActive = true;
      _enqueueRender(autoHide: false, markInteracted: false);
    }
    AppLog.info(
      '${DateTime.now()} call updated -> $name phase=${phase.name} '
      'callType=${notification.callType} text="${notification.text}" '
      'connectedAt=${notification.connectedAt}',
      tag: 'Glance',
    );
  }

  void clearCall(String key) {
    if (_currentCall?.key != key) return;
    _currentCall = null;
    _callPhase = null;
    _callDisplayName = null;
    _callNumber = null;
    _callAnsweredAt = null;
    _callIsOutgoing = false;
    _callTimer?.cancel();
    _callTimer = null;
    if (_isIdleSurfaceActive) {
      _isIdleSurfaceActive = false;
      // Was showing the call HUD; close properly now that the call has ended.
      // _hasActiveCall is now false, so close() tears the surface down rather
      // than re-asserting it.
      close();
    }
    AppLog.info(
      '${DateTime.now()} call cleared -> $key',
      tag: 'Glance',
    );
  }

  /// Maps a CallStyle notification to a [CallPhase]. Android call types:
  /// 1 = INCOMING, 2 = ONGOING, 3 = SCREENING. The two signals are combined
  /// because Samsung's incallui has been observed to report `callType=2` even
  /// during the ring — so `callType` alone cannot be trusted to mean ongoing.
  CallPhase _callPhaseFromNotification(CompanionNotification notification) {
    final ringingByType =
        notification.callType == 1 || notification.callType == 3;
    final ringingByText =
        notification.text.toLowerCase().contains('incoming');
    return ringingByType || ringingByText
        ? CallPhase.ringing
        : CallPhase.active;
  }

  void handleTelephonyState(String state, {bool isOutgoing = false, String? number}) {
    switch (state) {
      case 'ringing':
        _callPhase = CallPhase.ringing;
        _callIsOutgoing = false;
        _callDisplayName = null;
        _callNumber = number;
        _callAnsweredAt = null;
        _isIdleSurfaceActive = true;
        _enqueueRender(autoHide: false, markInteracted: false);
        AppLog.info('${DateTime.now()} telephony: ringing', tag: 'Glance');
      case 'offhook':
        if (_callPhase == null && isOutgoing) {
          _callIsOutgoing = true;
          _callDisplayName = null;
          _callNumber = number;
        }
        _callPhase = CallPhase.active;
        _callAnsweredAt ??= DateTime.now();
        _isIdleSurfaceActive = true;
        _startCallTimerIfNeeded();
        _enqueueRender(autoHide: false, markInteracted: false);
        AppLog.info(
          '${DateTime.now()} telephony: offhook outgoing=$isOutgoing',
          tag: 'Glance',
        );
      case 'idle':
        _callPhase = null;
        _callDisplayName = null;
        _callNumber = null;
        _callAnsweredAt = null;
        _callIsOutgoing = false;
        _callTimer?.cancel();
        _callTimer = null;
        if (_isIdleSurfaceActive) {
          _isIdleSurfaceActive = false;
          close();
        }
        AppLog.info('${DateTime.now()} telephony: idle — cleared', tag: 'Glance');
    }
  }

  void updateCallIdentity({required String name, String? number}) {
    _callDisplayName = name.isNotEmpty ? name : null;
    if (number != null && number.isNotEmpty) {
      _callNumber = number;
    }
    if (_isIdleSurfaceActive) {
      _enqueueRender(autoHide: false, markInteracted: false);
    }
    AppLog.info('${DateTime.now()} call identity: $name', tag: 'Glance');
  }

  Future<void> ingestNotification(
    CompanionNotification notification, {
    bool autoPop = true,
  }) async {
    _carousel.ingest(notification, keepPosition: _isVisible);
    AppLog.debug(
      '${DateTime.now()} notification received -> ${notification.source}',
      tag: 'Glance',
    );
    if (autoPop) {
      if (_isVisible) {
        AppLog.debug(
          '${DateTime.now()} notification queued while visible -> ${notification.source}',
          tag: 'Glance',
        );
      } else {
        await _enqueueRender(autoHide: true, markInteracted: false);
      }
    }
  }

  Future<void> removeNotificationByKey(String key) async {
    final wasCurrent = _carousel.remove(key);
    final shouldRefresh = wasCurrent && _isVisible;
    if (shouldRefresh) {
      if (_carousel.isEmpty) {
        if (_hasActiveCall) {
          _isIdleSurfaceActive = true;
          await _enqueueRender(autoHide: false, markInteracted: false);
          _startCallTimerIfNeeded();
          AppLog.info(
            '${DateTime.now()} last notification dismissed — call HUD takeover',
            tag: 'Glance',
          );
        } else {
          _isVisible = false;
          await TextService.get.stopTextSendingByOS();
          await Proto.clearDisplay();
          AppLog.info(
            '${DateTime.now()} cleared after notification removal',
            tag: 'Glance',
          );
        }
      } else {
        await _enqueueRender(autoHide: false, markInteracted: false);
      }
    }
  }

  Future<void> showLatestOrAdvance() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    // Tilt-up from idle surface: exit HUD mode and return to the carousel.
    if (_isIdleSurfaceActive) {
      _isIdleSurfaceActive = false;
      _callTimer?.cancel();
      _callTimer = null;
    }
    if (!_isVisible) {
      _carousel.resetToStart();
    } else if (_carousel.atEnd) {
      // Tilt-up on the end card: everything has been read, close and commit.
      await close();
      return;
    } else {
      _carousel.advance();
    }
    await _enqueueRender(autoHide: false, markInteracted: true);
  }

  /// Right tap: this one is read, show the next. Past the last notification
  /// shows an end card; a further right tap closes and commits dismissals.
  Future<void> showNext() async {
    if (!_isVisible) {
      return;
    }
    if (_carousel.atEnd) {
      await close();
      return;
    }
    _carousel.advance();
    _restartClearTimerIfRunning();
    await _enqueueRender(autoHide: false, markInteracted: true);
  }

  /// Left tap: go back one. Nothing is dismissed until the carousel closes,
  /// so anything paged past in this session is still there.
  Future<void> showPrevious() async {
    if (!_isVisible) {
      return;
    }
    if (!_carousel.back()) {
      return;
    }
    _restartClearTimerIfRunning();
    await _enqueueRender(autoHide: false, markInteracted: true);
  }

  void startLookDownTimeout() {
    if (!_isVisible) {
      return;
    }
    _restartClearTimer();
    AppLog.debug(
      '${DateTime.now()} tilt-down timeout started',
      tag: 'Glance',
    );
  }

  Future<void> close() async {
    AppLog.info(
      '${DateTime.now()} close() ENTERED — isVisible=$_isVisible call=$_hasActiveCall',
      tag: 'GlanceClear',
    );
    _clearTimer?.cancel();
    _clearTimer = null;
    _mediaTimeoutTimer?.cancel();
    _mediaTimeoutTimer = null;
    await _commitSeenDismissals();
    if (_hasActiveCall) {
      _isIdleSurfaceActive = true;
      await _enqueueRender(autoHide: false, markInteracted: false);
      _startCallTimerIfNeeded();
      return;
    }
    _isIdleSurfaceActive = false;
    _callTimer?.cancel();
    _callTimer = null;
    _isVisible = false;
    await TextService.get.stopTextSendingByOS();
    await Proto.clearDisplay();
    AppLog.info('${DateTime.now()} closed', tag: 'Glance');
  }

  /// Reset display-state flags when the BLE transport is lost.
  ///
  /// Without this, `_isVisible` / `_isIdleSurfaceActive` survive a drop and
  /// block the next notification from auto-popping (the `if (_isVisible)`
  /// queue-silently branch in `ingestNotification`). The post-reconnect
  /// force-clear leaves the lenses blank; this method makes the service agree.
  ///
  /// Must not perform any BLE IO — transport is gone. Notification queue and
  /// call/media context are preserved so the next interaction can re-render
  /// what we already know about.
  void handleTransportLost() {
    _clearTimer?.cancel();
    _clearTimer = null;
    _callTimer?.cancel();
    _callTimer = null;
    _isVisible = false;
    _isIdleSurfaceActive = false;
    // Never dismiss on the phone without the user closing the carousel.
    _carousel
      ..clearSeen()
      ..resetToStart();
    Proto.resetTextSurfaceState();
    AppLog.info(
      '${DateTime.now()} transport lost — display flags cleared',
      tag: 'Glance',
    );
  }

  Future<bool> showIdleSurfaceIfAvailable() async {
    if (!_hasActiveCall) return false;
    _isIdleSurfaceActive = true;
    await _enqueueRender(autoHide: false, markInteracted: false);
    _startCallTimerIfNeeded();
    return true;
  }

  void _startCallTimerIfNeeded() {
    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isIdleSurfaceActive && _hasActiveCall) {
        _enqueueRender(autoHide: false, markInteracted: false);
      } else {
        _callTimer?.cancel();
        _callTimer = null;
      }
    });
  }

  Future<void> _enqueueRender({
    required bool autoHide,
    required bool markInteracted,
  }) {
    _renderChain = _renderChain.then((_) {
      return _renderCurrent(autoHide: autoHide, markInteracted: markInteracted);
    });
    return _renderChain;
  }

  Future<void> _renderCurrent({
    required bool autoHide,
    required bool markInteracted,
  }) async {
    final now = DateTime.now();
    final tapSurface = tapPagingEnabled && markInteracted;
    final text = _buildDisplayText(
      now,
      tapLayout: tapSurface || Proto.isTapSurfaceOpen,
    );
    _isVisible = true;
    await TextService.get.startSendText(text, tapSurface: tapSurface);
    if (markInteracted) {
      _carousel.markSeen();
    }
    if (autoHide) {
      _restartClearTimer();
    }
    // When autoHide is false, leave the existing timer untouched — callers
    // that need it cancelled (showLatestOrAdvance, close) do so before
    // enqueuing. Content-refresh renders (media, call) must not kill a
    // running auto-dismiss timer.
    AppLog.debug(
      '${DateTime.now()} render -> index=${_carousel.currentIndex} end=${_carousel.atEnd} count=${_carousel.length}',
      tag: 'Glance',
    );
  }

  String _buildDisplayText(DateTime now, {bool tapLayout = false}) {
    if (_isIdleSurfaceActive && _callPhase != null) {
      return _buildTelephonyCallText(now);
    }
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final batteryLabel = DeviceStatusService.get.glassesBatteryLabel;
    final timeLine = batteryLabel == null
        ? '$hour:$minute'
        : '$hour:$minute  |  $batteryLabel';
    final mediaSuffix = _buildMediaSuffix(
      timeLine,
      tapLayout ? _lineBudgetTapLayout : _lineBudgetFullWidth,
    );
    final line1 = mediaSuffix != null ? '$timeLine  |  $mediaSuffix' : timeLine;
    if (_carousel.atEnd) {
      return '$line1\n--\nEnd of notifications';
    }
    final current = _carousel.current;
    if (current == null) {
      return '$line1\n--\nNo notifications';
    }
    final postedHour = current.postedAt.hour.toString().padLeft(2, '0');
    final postedMinute = current.postedAt.minute.toString().padLeft(2, '0');
    return '$line1\n${current.source}  ·  $postedHour:$postedMinute\n${current.message}';
  }

  String _buildTelephonyCallText(DateTime now) {
    final identity = _callDisplayName ?? _callNumber ?? 'Unknown Caller';
    switch (_callPhase!) {
      case CallPhase.ringing:
        return _callIsOutgoing
            ? 'Calling\n$identity'
            : 'Incoming Call\n$identity';
      case CallPhase.active:
        final answered = _callAnsweredAt;
        final durationLine = (answered == null || answered.isAfter(now))
            ? 'Call time: --:--'
            : 'Call time: ${_formatCallDuration(now.difference(answered))}';
        return 'Ongoing call: $identity\n$durationLine';
    }
  }

  String _formatCallDuration(Duration d) {
    if (d.isNegative) return '--:--';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  /// Builds the `> Artist - Track` suffix for the time line, or returns
  /// `null` if there is no current media or the available width is too narrow.
  ///
  /// Line-1 budget is [lineBudget] characters (43 full width, 35 on the tap
  /// layout). The separator `  |  ` costs 5 characters and the `> ` prefix
  /// costs 2, leaving:
  ///   available = lineBudget - timeLine.length - 5 - 2
  String? _buildMediaSuffix(String timeLine, int lineBudget) {
    final media = _currentMedia;
    if (media == null) {
      return null;
    }
    final available = lineBudget - timeLine.length - 5 - 2;
    if (available < 5) {
      return null;
    }
    final title = media.title.trim();
    final text = media.text.trim();
    final raw = title.isNotEmpty && text.isNotEmpty
        ? '$text - $title'
        : (title.isNotEmpty ? title : text);
    if (raw.isEmpty) {
      return null;
    }
    final truncated = raw.length > available
        ? '${raw.substring(0, available - 3)}...'
        : raw;
    return '> $truncated';
  }

  /// Dismiss on the phone every notification read in this session, then
  /// drop them from the carousel. Protected and ongoing notifications are
  /// never marked read, so are never dismissed here.
  Future<void> _commitSeenDismissals() async {
    final keys = _carousel.takeSeenKeys();
    for (final key in keys) {
      try {
        await BleManager.invokeMethod(
          'dismissNotification',
          {'key': key},
        );
        _carousel.remove(key);
        AppLog.info(
          '${DateTime.now()} dismissed notification on phone -> $key',
          tag: 'Glance',
        );
      } catch (e) {
        AppLog.error(
          '${DateTime.now()} dismiss notification failed -> $e',
          tag: 'Glance',
        );
      }
    }
    _carousel.resetToStart();
  }

  void _restartClearTimerIfRunning() {
    if (_clearTimer?.isActive ?? false) {
      _restartClearTimer();
    }
  }

  void _restartClearTimer() {
    _clearTimer?.cancel();
    AppLog.info(
      '${DateTime.now()} clear timer STARTED (${_displayDuration.inSeconds}s)',
      tag: 'GlanceClear',
    );
    _clearTimer = Timer(_displayDuration, () {
      AppLog.info(
        '${DateTime.now()} clear timer FIRED — calling close()',
        tag: 'GlanceClear',
      );
      close();
    });
  }
}
