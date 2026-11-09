import 'dart:async';
import 'dart:convert';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/capture_service.dart';
import 'package:even_companion/services/chat_service.dart';
import 'package:even_companion/services/companion_controller.dart';
import 'package:even_companion/services/device_status_service.dart';
import 'package:even_companion/services/glance_assistant_service.dart';
import 'package:even_companion/services/glance_service.dart';
import 'package:even_companion/services/walknav/walk_navigator_service.dart';
import 'package:even_companion/services/watch/watch_protocol.dart';
import 'package:flutter/services.dart';

/// Dart end of the Galaxy Watch remote. Native `WatchBridge.kt` owns the Data
/// Layer; this decodes commands, runs them one at a time through
/// [CompanionController] (which keeps mode ownership), and mirrors state back.
class WatchRemoteService {
  WatchRemoteService._();
  static final WatchRemoteService get = WatchRemoteService._();

  static const _channel = MethodChannel('method.watch');
  static const _debounce = Duration(milliseconds: 200);

  /// Forced re-publish so the watch can tell live state from stale, and so
  /// battery changes (which do not notify the controller) reach it.
  static const _heartbeat = Duration(seconds: 60);

  bool _initialized = false;
  Future<void> _commandChain = Future<void>.value();
  Timer? _debounceTimer;

  void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_onCall);
    CompanionController.get.addListener(_schedulePublish);
    Timer.periodic(_heartbeat, (_) => _publish(force: true));
    unawaited(_publish(force: true));
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'command':
        return (await _enqueue(call.arguments as String?)).toJson();
      case 'stateRequest':
      case 'watchConnection':
        await _publish(force: true);
        return null;
    }
    throw MissingPluginException('watch: ${call.method}');
  }

  /// Watch commands and glasses gestures both land in the controller; running
  /// watch commands strictly in order keeps a double-pressed Stop idempotent.
  Future<RemoteResult> _enqueue(String? raw) {
    final completer = Completer<RemoteResult>();
    _commandChain = _commandChain.then((_) async {
      completer.complete(await _run(raw));
    });
    return completer.future;
  }

  Future<RemoteResult> _run(String? raw) async {
    final WatchCommand command;
    try {
      command = WatchCommand.parse(jsonDecode(raw ?? '{}'));
    } on FormatException catch (e) {
      AppLog.info('${DateTime.now()} bad command $raw -> ${e.message}',
          tag: 'Watch');
      return RemoteResult.fail(e.message);
    }
    try {
      return await CompanionController.get.remoteCommand(command);
    } catch (e, st) {
      AppLog.error('${DateTime.now()} ${command.kind.wire} failed -> $e\n$st',
          tag: 'Watch');
      return const RemoteResult.fail('Failed on the phone');
    }
  }

  void _schedulePublish() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => _publish());
  }

  Future<void> _publish({bool force = false}) async {
    final json = jsonEncode(_snapshot().toJson());
    try {
      await _channel.invokeMethod('publishState', {'json': json, 'force': force});
    } catch (e) {
      AppLog.error('${DateTime.now()} publish failed -> $e', tag: 'Watch');
    }
  }

  WatchState _snapshot() {
    final controller = CompanionController.get;
    final glance = GlanceService.get;
    final current = glance.currentNotification;
    final chat = ChatService.get;
    final assistant = GlanceAssistantService.get;
    final status = DeviceStatusService.get;
    return WatchState(
      connected: BleManager.get().isConnected,
      mode: controller.activeMode,
      status: controller.statusMessage,
      displayOwner: controller.activeDisplayOwnerLabel,
      recording: CaptureService.get.isRecording,
      recordingStartedAt: CaptureService.get.recordingStartedAt,
      glanceVisible: glance.isVisible,
      glanceIndex: glance.carouselIndex,
      glanceCount: glance.notificationCount,
      glanceTitle: current?.title ?? '',
      glanceApp: current?.source ?? '',
      assistantListening: assistant.isListening || chat.isListening,
      assistantThinking: assistant.isThinking || chat.isThinking,
      walkActive: WalkNavigatorService.get.isActive,
      glassesBattery: status.glassesBatteryPct,
      caseBattery: status.caseBatteryPct,
    );
  }
}
