import 'dart:async';
import 'dart:typed_data';
import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/controllers/bmp_update_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/utils/utils.dart';

class FeaturesServices {
  static Future<void> _bmpSendQueue = Future<void>.value();
  static Uint8List? _lastBmpData;
  static final Map<String, _NavigateLegPumpState> _navigateLegStates =
      <String, _NavigateLegPumpState>{
    'L': _NavigateLegPumpState(),
    'R': _NavigateLegPumpState(),
  };
  static int _navigateFrameSeq = 0;
  static _NavigateFrameSnapshot? _latestNavigateFrame;
  static final Map<int, Map<String, _NavigateFrameOutcome>> _navigateFrameOutcomes =
      <int, Map<String, _NavigateFrameOutcome>>{};
  static bool _navigateOutOfSync = false;
  static const Duration _navigateHealthyMinInterval = Duration(milliseconds: 850);
  static const Duration _navigateDegradedMinInterval = Duration(milliseconds: 1450);

  final bmpUpdateManager = BmpUpdateManager();

  Future<void> sendBmp(String imageUrl) async {
    Uint8List bmpData = await Utils.loadBmpImage(imageUrl);
    await sendBmpData(bmpData);
  }

  Future<void> sendBmpData(Uint8List bmpData) async {
    _lastBmpData = Uint8List.fromList(bmpData);
    final send = _bmpSendQueue.then((_) => _sendBmpDataInternal(bmpData));
    _bmpSendQueue = send.catchError((_) {});
    await send;
  }

  Future<void> sendNavigateBmpData(Uint8List bmpData) async {
    _lastBmpData = Uint8List.fromList(bmpData);
    final snapshot = Uint8List.fromList(bmpData);
    final frameId = ++_navigateFrameSeq;
    _latestNavigateFrame = _NavigateFrameSnapshot(
      data: Uint8List.fromList(snapshot),
      frameId: frameId,
    );

    for (final lr in ['L', 'R']) {
      _setNavigatePending(
        lr,
        Uint8List.fromList(snapshot),
        frameId,
        reason: 'new-frame',
      );
    }

    final bothIdle = _navigateLegStates.values.every((state) => !state.inFlight);
    if (bothIdle) {
      AppLog.info(
        '${DateTime.now()} NavigateBmpTrace: frame=$frameId enqueue bytes=${snapshot.length} mode=parallel-idle',
      );
    } else {
      AppLog.info(
        '${DateTime.now()} NavigateBmpTrace: frame=$frameId enqueue bytes=${snapshot.length} mode=overwrite-pending',
      );
    }

    await Proto.sendHeartBeat();
    BleManager.get().startSendBeatHeart();
    for (final lr in ['L', 'R']) {
      _ensureNavigateLegPump(lr);
    }
  }

  Future<bool> resendLastBmpData() async {
    final bmpData = _lastBmpData;
    if (bmpData == null) {
      return false;
    }
    await sendBmpData(Uint8List.fromList(bmpData));
    return true;
  }

  Future<void> _sendBmpDataInternal(Uint8List bmpData) async {
    int initialSeq = 0;
    bool isSuccess = await Proto.sendHeartBeat();
    AppLog.debug(
      '${DateTime.now()} testBMP startSendBeatHeart isSuccess=$isSuccess',
      tag: 'Features',
    );
    BleManager.get().startSendBeatHeart();

    final results = await Future.wait([
      bmpUpdateManager.updateBmp("L", bmpData, seq: initialSeq),
      bmpUpdateManager.updateBmp("R", bmpData, seq: initialSeq)
    ]);

    final successL = results[0].success;
    final successR = results[1].success;

    if (successL) {
      AppLog.debug('${DateTime.now()} left ble success', tag: 'Features');
    } else {
      AppLog.error('${DateTime.now()} left ble fail', tag: 'Features');
    }

    if (successR) {
      AppLog.debug('${DateTime.now()} right ble success', tag: 'Features');
    } else {
      AppLog.error('${DateTime.now()} right ble fail', tag: 'Features');
    }
  }

  Future<void> exitBmp() async {
    bool isSuccess = await Proto.exit();
    AppLog.debug('exitBmp isSuccess=$isSuccess', tag: 'Features');
  }

  void _ensureNavigateLegPump(String lr) {
    final state = _navigateLegStates[lr]!;
    if (state.inFlight) {
      return;
    }
    state.startDelayTimer?.cancel();
    state.startDelayTimer = null;
    final pending = state.pending;
    final pendingFrameId = state.pendingFrameId;
    if (pending == null) {
      return;
    }
    final now = DateTime.now();
    if (state.nextEligibleAt != null && now.isBefore(state.nextEligibleAt!)) {
      final delay = state.nextEligibleAt!.difference(now);
      state.startDelayTimer = Timer(delay, () {
        state.startDelayTimer = null;
        _ensureNavigateLegPump(lr);
      });
      AppLog.info(
        '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=coalesce waitMs=${delay.inMilliseconds} degraded=${state.transportDegraded}',
      );
      return;
    }
    state.pending = null;
    state.pendingFrameId = null;
    state.inFlight = true;
    unawaited(_runNavigateLegPump(lr, pending, pendingFrameId ?? -1));
  }

  Future<void> _runNavigateLegPump(
    String lr,
    Uint8List initialBmp,
    int frameId,
  ) async {
    var currentBmp = Uint8List.fromList(initialBmp);
    var currentFrameId = frameId;
    try {
      while (true) {
        AppLog.info(
          '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=start frame=$currentFrameId bytes=${currentBmp.length}',
        );
        final result = await bmpUpdateManager.updateBmp(lr, currentBmp, seq: 0);
        _recordNavigateFrameOutcome(
          lr: lr,
          frameId: currentFrameId,
          result: result,
        );
        AppLog.info(
          '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=complete frame=$currentFrameId success=${result.success} bytes=${currentBmp.length} writeWarnings=${result.writeWarnings} failureStage=${result.failureStage?.name ?? 'none'}',
        );

        final state = _navigateLegStates[lr]!;
        state.lastAttemptedFrameId = currentFrameId;
        state.lastWriteWarnings = result.writeWarnings;
        state.nextEligibleAt = DateTime.now().add(
          state.transportDegraded || _navigateOutOfSync
              ? _navigateDegradedMinInterval
              : _navigateHealthyMinInterval,
        );
        final nextPending = state.pending;
        final nextPendingFrameId = state.pendingFrameId;
        if (nextPending == null) {
          state.inFlight = false;
          _ensureNavigateLegPump(lr);
          return;
        }

        state.pending = null;
        state.pendingFrameId = null;
        currentBmp = Uint8List.fromList(nextPending);
        currentFrameId = nextPendingFrameId ?? currentFrameId;
        AppLog.info(
          '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=advance nextFrame=$currentFrameId',
        );
      }
    } catch (e) {
      _navigateLegStates[lr]!.inFlight = false;
      AppLog.error('${DateTime.now()} NavigateBmpTrace: leg=$lr stage=exception frame=$currentFrameId error=$e');
      rethrow;
    }
  }

  void _setNavigatePending(
    String lr,
    Uint8List bmpData,
    int frameId, {
    required String reason,
  }) {
    final state = _navigateLegStates[lr]!;
    state.pending = Uint8List.fromList(bmpData);
    state.pendingFrameId = frameId;
    AppLog.info(
      '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=pending frame=$frameId reason=$reason',
    );
  }

  void _recordNavigateFrameOutcome({
    required String lr,
    required int frameId,
    required BmpTransferResult result,
  }) {
    final state = _navigateLegStates[lr]!;
    state.lastCrcSuccess = result.success;
    if (result.success) {
      state.lastSuccessfulFrameId = frameId;
    }

    final shouldDegrade = !result.success || result.writeWarnings >= 2;
    final wasDegraded = state.transportDegraded;
    state.transportDegraded = shouldDegrade;

    if (result.writeWarnings > 0) {
      AppLog.info(
        '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=writeWarnings frame=$frameId count=${result.writeWarnings}',
      );
    }

    if (state.transportDegraded != wasDegraded) {
      AppLog.info(
        '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=transportState degraded=${state.transportDegraded} frame=$frameId',
      );
    }

    final outcomes = _navigateFrameOutcomes.putIfAbsent(
      frameId,
      () => <String, _NavigateFrameOutcome>{},
    );
    outcomes[lr] = _NavigateFrameOutcome(
      success: result.success,
      writeWarnings: result.writeWarnings,
      failureStage: result.failureStage,
    );

    final otherLr = lr == 'L' ? 'R' : 'L';
    final otherOutcome = outcomes[otherLr];
    if (otherOutcome == null) {
      return;
    }

    final bothSuccess = result.success && otherOutcome.success;
    if (bothSuccess) {
      final wasOutOfSync = _navigateOutOfSync;
      _navigateOutOfSync = false;
      if (wasOutOfSync) {
        AppLog.info(
          '${DateTime.now()} NavigateBmpTrace: stage=syncRecovered frame=$frameId',
        );
      }
      _pruneNavigateOutcomes(frameId);
      return;
    }

    if (result.success != otherOutcome.success) {
      final failedLeg = result.success ? otherLr : lr;
      final successLeg = result.success ? lr : otherLr;
      final failedState = _navigateLegStates[failedLeg]!;
      failedState.transportDegraded = true;
      _navigateOutOfSync = true;
      AppLog.error(
        '${DateTime.now()} NavigateBmpTrace: stage=outOfSync frame=$frameId successLeg=$successLeg failedLeg=$failedLeg latestIntended=${_latestNavigateFrame?.frameId ?? frameId}',
      );
      _scheduleNavigateResync(
        failedLeg,
        currentFrameId: frameId,
        reason: 'frame-mismatch',
      );
    }

    _pruneNavigateOutcomes(frameId);
  }

  void _scheduleNavigateResync(
    String failedLeg, {
    required int currentFrameId,
    required String reason,
  }) {
    final latestFrame = _latestNavigateFrame;
    if (latestFrame == null) {
      return;
    }
    final state = _navigateLegStates[failedLeg]!;
    if (state.lastSuccessfulFrameId == latestFrame.frameId &&
        state.pendingFrameId == null &&
        !state.inFlight) {
      return;
    }

    _setNavigatePending(
      failedLeg,
      latestFrame.data,
      latestFrame.frameId,
      reason: 'resync-$reason',
    );
    AppLog.info(
      '${DateTime.now()} NavigateBmpTrace: leg=$failedLeg stage=resync targetFrame=${latestFrame.frameId} fromFrame=$currentFrameId reason=$reason',
    );
    _ensureNavigateLegPump(failedLeg);
  }

  void _pruneNavigateOutcomes(int frameId) {
    final minFrameToKeep = frameId - 4;
    _navigateFrameOutcomes.removeWhere((key, _) => key < minFrameToKeep);
  }
}

class _NavigateLegPumpState {
  bool inFlight = false;
  Uint8List? pending;
  int? pendingFrameId;
  Timer? startDelayTimer;
  DateTime? nextEligibleAt;
  bool transportDegraded = false;
  int? lastSuccessfulFrameId;
  int? lastAttemptedFrameId;
  bool? lastCrcSuccess;
  int lastWriteWarnings = 0;
}

class _NavigateFrameSnapshot {
  const _NavigateFrameSnapshot({
    required this.data,
    required this.frameId,
  });

  final Uint8List data;
  final int frameId;
}

class _NavigateFrameOutcome {
  const _NavigateFrameOutcome({
    required this.success,
    required this.writeWarnings,
    this.failureStage,
  });

  final bool success;
  final int writeWarnings;
  final BmpFailureStage? failureStage;
}
