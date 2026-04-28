import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/navigate_bitmap_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class NavigateService {
  NavigateService._();

  static const _minTextRenderGap = Duration(milliseconds: 250);
  static const _minBitmapRenderGap = Duration(milliseconds: 2200);

  static NavigateService? _instance;
  static NavigateService get get => _instance ??= NavigateService._();

  CompanionNotification? _latestInstruction;
  bool _isVisible = false;
  bool _renderActive = false;
  bool _renderDirty = false;
  bool _lastRenderUsedBitmap = false;
  DateTime? _lastRenderCompletedAt;

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
    _latestInstruction = notification;
    AppLog.debug(
      '${DateTime.now()} Navigate: payload primary="${notification.navPrimaryInfo}" secondary="${notification.navSecondaryInfo}" subText="${notification.subText}" iconSource="${notification.navIconSource}"',
    );
  }

  Future<void> showLatest() async {
    await _scheduleRender();
  }

  Future<void> showIdlePrompt() async {
    if (_latestInstruction != null) {
      await _scheduleRender();
      return;
    }
    _isVisible = true;
    _renderDirty = false;
    _lastRenderUsedBitmap = false;
    await TextService.get.startSendText('Open Google Maps\nto start navigation');
    AppLog.debug('${DateTime.now()} render -> idle-prompt', tag: 'Navigate');
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
    if (!_isVisible) {
      return;
    }
    _isVisible = false;
    _renderDirty = false;
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    AppLog.info('${DateTime.now()} closed', tag: 'Navigate');
  }

  Future<void> leaveMode() async {
    await close();
  }

  Future<void> _scheduleRender() async {
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

    final useBitmap = notification != null && _shouldUseBitmap(notification);
    final minGap = _lastRenderUsedBitmap ? _minBitmapRenderGap : _minTextRenderGap;
    final gap = _lastRenderCompletedAt == null
        ? Duration.zero
        : DateTime.now().difference(_lastRenderCompletedAt!);
    if (_lastRenderCompletedAt != null && gap < minGap) {
      await Future<void>.delayed(minGap - gap);
    }

    if (useBitmap) {
      await TextService.get.stopTextSendingByOS();
      await NavigateBitmapService.get.renderAndSend(notification);
      _lastRenderUsedBitmap = true;
      AppLog.debug('${DateTime.now()} render -> bitmap-card', tag: 'Navigate');
      return;
    }

    final text = _buildTextFallback(notification);
    await TextService.get.startSendText(text);
    _lastRenderUsedBitmap = false;
    AppLog.debug('${DateTime.now()} render -> text-fallback', tag: 'Navigate');
  }

  bool _shouldUseBitmap(CompanionNotification notification) {
    if (notification.navIconPngBase64.isEmpty) {
      return false;
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
          : notification.text,
    );

    if (primary.isEmpty && secondary.isEmpty) {
      return false;
    }

    final combined = '$primary $secondary ${notification.subText}'.toLowerCase();
    if (combined.contains('start navigation') ||
        combined.contains('starting navigation') ||
        combined == 'google maps') {
      return false;
    }

    return true;
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

    final hasStrongNavFields =
        notification.navPrimaryInfo.isNotEmpty &&
        (notification.navSecondaryInfo.isNotEmpty ||
            notification.navIconPngBase64.isNotEmpty ||
            notification.navChipExpandedText.isNotEmpty);
    final hasOngoingSignal =
        notification.isOngoing ||
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
}
