import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/glance_service.dart';
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

  Future<void> ingestNotification(CompanionNotification notification) async {
    if (!notification.isGoogleMaps) {
      return;
    }
    _latestInstruction = notification;
    print(
      '${DateTime.now()} Navigate: instruction updated -> ${notification.message}',
    );
  }

  Future<void> showLatest() async {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final body = _latestInstruction?.message ?? 'Start navigation in Google Maps';
    final title = _latestInstruction?.source ?? 'Navigate';
    _isVisible = true;
    await TextService.get.startSendText('$hour:$minute\n--\n$title\n$body');
    print('${DateTime.now()} Navigate: render');
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
}
