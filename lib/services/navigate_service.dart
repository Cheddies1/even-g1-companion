import 'package:demo_ai_even/models/companion_notification.dart';
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

  Future<void> ingestNotification(CompanionNotification notification) async {
    if (!notification.isGoogleMaps) {
      return;
    }
    _latestInstruction = notification;
    print(
      '${DateTime.now()} Navigate: payload primary="${notification.navPrimaryInfo}" secondary="${notification.navSecondaryInfo}" subText="${notification.subText}" iconSource="${notification.navIconSource}"',
    );
  }

  Future<void> showLatest() async {
    await _scheduleRender();
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
    final samePackage = packageName.contains('com.google.android.apps.maps');
    final sameKey = latest.key == key;
    if (!samePackage && !sameKey) {
      return false;
    }
    _latestInstruction = null;
    await close();
    print('${DateTime.now()} Navigate: cleared after notification removal');
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
    print('${DateTime.now()} Navigate: closed');
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
      print('${DateTime.now()} Navigate: render -> bitmap-card');
      return;
    }

    final text = _buildTextFallback(notification);
    await TextService.get.startSendText(text);
    _lastRenderUsedBitmap = false;
    print('${DateTime.now()} Navigate: render -> text-fallback');
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
