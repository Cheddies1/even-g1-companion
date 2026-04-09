import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/navigate_bitmap_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class NavigateService {
  NavigateService._();

  static NavigateService? _instance;
  static NavigateService get get => _instance ??= NavigateService._();

  CompanionNotification? _latestInstruction;
  bool _isVisible = false;

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
    await _renderCurrentView();
  }

  Future<void> showDetail() async {
    await _renderCurrentView();
  }

  Future<void> returnToPrimary() async {
    await _renderCurrentView();
  }

  Future<void> refreshVisibleView() async {
    if (!_isVisible) {
      return;
    }
    await _renderCurrentView();
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
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Navigate: closed');
  }

  Future<void> leaveMode() async {
    await close();
  }

  Future<void> _renderCurrentView() async {
    _isVisible = true;
    await TextService.get.stopTextSendingByOS();
    await NavigateBitmapService.get.renderAndSend(_latestInstruction);
    print('${DateTime.now()} Navigate: render -> bitmap-card');
  }
}
