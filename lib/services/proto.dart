import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/evenai_proto.dart';
import 'package:even_companion/services/text_service.dart';
import 'package:even_companion/utils/utils.dart';

class Proto {
  static const Duration _streamingKeepAliveInterval = Duration(seconds: 5);
  static int _streamKeepAliveSeq = 0;
  static int _streamTextSeq = 0;

  // ---- Tap-enabled 0x4E text surface ------------------------------------
  //
  // The firmware forwards single taps (`F5 01`) only while the 0x4E surface
  // is in the Even AI family (types 7-11, `src/threads/threads.c:2254`).
  // Device-confirmed recipe (docs/protocol-reference.md, "Recipe:
  // tap-enabled text surface"): open with status 0x3x, pin by re-sending with
  // 0x5x, page with 0x5x updates. 0x5x from idle draws nothing, and mixing a
  // 0x7x surface with 0x5x overlays two layouts, so we track which family is
  // on the lenses.
  static bool _tapSurfaceOpen = false;

  /// True while a pinned (status 0x5x) text surface is on the lenses, so the
  /// next 0x4E render must also be 0x5x to stay in the same layout.
  static bool get isTapSurfaceOpen => _tapSurfaceOpen;

  // Our own `0x18` clears, and opening a tap surface over another surface,
  // can make the right lens emit `F5 00`, which every mode reads as "close".
  // Seen on device 2026-11-06 within ~150 ms of the TX.
  static const Duration selfCloseWindow = Duration(milliseconds: 800);
  static DateTime? _selfCloseRiskUntil;

  /// True if an `F5 00` arriving now is likely our own doing rather than a
  /// user double tap.
  static bool get isInSelfCloseWindow {
    final until = _selfCloseRiskUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  static void _noteSelfCloseRisk() {
    _selfCloseRiskUntil = DateTime.now().add(selfCloseWindow);
  }

  /// Forget the surface state without any BLE IO, e.g. on transport loss.
  static void resetTextSurfaceState() {
    _tapSurfaceOpen = false;
  }

  static void _noteTextSurfaceCleared() {
    _tapSurfaceOpen = false;
    _noteSelfCloseRisk();
  }

  static Timer? _streamingKeepAliveTimer;
  static bool _streamingTextActive = false;
  static bool get isStreamingTextActive => _streamingTextActive;
  static String _lastStreamingText = '';
  static int _lastStreamingLine = 2;

  static String lR() {
    if (BleManager.get().isLegAvailable("R")) return "R";
    return "L";
  }

  /// Returns the time consumed by the command and whether it is successful
  static Future<(int, bool)> micOn({
    String? lr,
  }) async {
    var begin = Utils.getTimestampMs();
    var data = Uint8List.fromList([0x0E, 0x01]);
    var receive = await BleManager.request(data, lr: lr);

    var end = Utils.getTimestampMs();
    var startMic = (begin + ((end - begin) ~/ 2));

    AppLog.debug("Proto---micOn---startMic---$startMic-------");
    return (startMic, (!receive.isTimeout && receive.data[1] == 0xc9));
  }

  /// `0x0E 00`. The firmware closes the mic by itself when a left long-press
  /// ends; a mic the host opened without one (e.g. from the watch) keeps
  /// streaming until this is sent.
  static Future<bool> micOff({String? lr}) async {
    final receive =
        await BleManager.request(Uint8List.fromList([0x0E, 0x00]), lr: lr);
    return !receive.isTimeout && receive.data[1] == 0xc9;
  }

  /// True while the QuickNote audio stream is expected to be in flight —
  /// between sending `02 01` and receiving the flushed buffer in Dart.
  /// [clearDisplay] checks this and suppresses the 0x50+0x18 sequence to
  /// avoid killing the glasses' audio stream mid-capture.
  static bool _quickNoteCaptureActive = false;
  static bool get isQuickNoteCaptureActive => _quickNoteCaptureActive;
  static void quickNoteCaptureComplete() {
    _quickNoteCaptureActive = false;
    AppLog.info(
      '${DateTime.now()} QuickNote capture flag cleared',
      tag: 'QuickNoteCapture',
    );
  }

  /// Host's outgoing 0x1e command-channel sequence counter. Observed in the
  /// 2026-04-28 recon as `0x41`, `0x42`, ... — monotonically increasing per
  /// outbound packet on the QuickNote command channel.
  static int _quickNoteSeq = 0x40;

  /// QuickNote: ask the glasses to stream the audio for the just-released
  /// note. Sends `1e 06 00 <seq> 02 01` to the right leg.
  ///
  /// Observed in the 2026-04-28 recon: the official Even Realities app sends
  /// this 11ms after receiving a 15-byte `0x21` release. The glasses then
  /// stream the audio as `0x1e c8 ...` chunks ~50ms later. Without this TX
  /// the firmware sends no audio at all.
  /// Requests audio for a specific note index. The [noteIndex] corresponds
  /// to the record number in the 42-byte `0x21` notes-list dump — typically
  /// byte 5 of the `0x21` payload gives the total count, and the newest note
  /// is at that index (e.g. `04` when there are 4 stored notes).
  static Future<void> quickNoteRequestAudio({String? lr, int noteIndex = 1}) async {
    _quickNoteCaptureActive = true;
    final seq = _quickNoteSeq & 0xff;
    _quickNoteSeq++;
    final data = Uint8List.fromList([0x1E, 0x06, 0x00, seq, 0x02, noteIndex]);
    AppLog.info(
      '${DateTime.now()} Proto.quickNoteRequestAudio seq=0x${seq.toRadixString(16).padLeft(2, '0')} bytes=${data.hexString}',
      tag: 'QuickNoteCapture',
    );
    await BleManager.sendData(data, lr: lr ?? 'R');
  }

  /// QuickNote: acknowledge that the audio stream was received. Sends
  /// `1e 06 00 <seq> 04 01` to the right leg. The glasses respond with
  /// `1e 06 00 <seq> 04 00` (visible as RX) to close the cycle.
  static Future<void> quickNoteAck({String? lr}) async {
    final seq = _quickNoteSeq & 0xff;
    _quickNoteSeq++;
    final data = Uint8List.fromList([0x1E, 0x06, 0x00, seq, 0x04, 0x01]);
    AppLog.info(
      '${DateTime.now()} Proto.quickNoteAck seq=0x${seq.toRadixString(16).padLeft(2, '0')} bytes=${data.hexString}',
      tag: 'QuickNoteCapture',
    );
    await BleManager.sendData(data, lr: lr ?? 'R');
  }

  /// Even AI
  static int _evenaiSeq = 0;
  static const int _evenaiMaxTextBytes = 480;
  // AI result transmission (also compatible with AI startup and Q&A status synchronization)
  static Future<bool> sendEvenAIData(String text,
      {int? timeoutMs,
      required int newScreen,
      required int pos,
      required int current_page_num,
      required int max_page_num}) async {
    var data = utf8.encode(text);
    // The firmware reassembles 0x4E chunks into a 480-byte buffer with no
    // bounds check (dash_buf->data, glasses_state.h:223; append at
    // ble_proto.c:3844). Anything longer overruns into its length field.
    if (data.length > _evenaiMaxTextBytes) {
      var end = _evenaiMaxTextBytes;
      while (end > 0 && (data[end] & 0xC0) == 0x80) {
        end--; // do not split a UTF-8 sequence
      }
      AppLog.error(
          'sendEvenAIData: text ${data.length} bytes exceeds firmware buffer, truncated to $end',
          tag: 'BLE');
      data = data.sublist(0, end);
    }
    var syncSeq = _evenaiSeq & 0xff;
    final statusFamily = newScreen & 0xF0;
    if (statusFamily == 0x30 && !_tapSurfaceOpen) {
      _noteSelfCloseRisk();
    }

    List<Uint8List> dataList = EvenaiProto.evenaiMultiPackListV2(0x4E,
        data: data,
        syncSeq: syncSeq,
        newScreen: newScreen,
        pos: pos,
        current_page_num: current_page_num,
        max_page_num: max_page_num);
    _evenaiSeq++;

    AppLog.debug(
        '${DateTime.now()} proto--sendEvenAIData---text---$text---_evenaiSeq----$_evenaiSeq---newScreen---$newScreen---pos---$pos---current_page_num--$current_page_num---max_page_num--$max_page_num--dataList----$dataList---');

    final isSuccess = await BleManager.requestList(
      dataList,
      timeoutMs: timeoutMs ?? 2000,
    );

    AppLog.debug(
        '${DateTime.now()} sendEvenAIData-----isSuccess-----$isSuccess-------');
    if (!isSuccess) {
      AppLog.error("${DateTime.now()} sendEvenAIData failed");
      return false;
    }
    if (statusFamily == 0x50) {
      _tapSurfaceOpen = true;
    } else if (statusFamily != 0x30 && statusFamily != 0x40) {
      // 0x3x/0x4x keep the Even AI layout; anything else (0x7x full width,
      // 0x6x) leaves it.
      _tapSurfaceOpen = false;
    }
    return true;
  }

  static int _beatHeartSeq = 0;
  static Uint8List _nextHeartBeatPacket() {
    const length = 6;
    final seq = _beatHeartSeq & 0xff;
    final data = Uint8List.fromList([
      0x25,
      length & 0xff,
      (length >> 8) & 0xff,
      seq,
      0x04,
      seq,
    ]);
    _beatHeartSeq++;
    return data;
  }

  static Future<bool> sendHeartBeatToLeg(String lr) async {
    final data = _nextHeartBeatPacket();
    AppLog.debug('${DateTime.now()} sendHeartBeat[$lr]--------data---$data--');
    final ret = await BleManager.request(data, lr: lr, timeoutMs: 1500);
    if (ret.isTimeout) {
      AppLog.debug('${DateTime.now()} sendHeartBeat[$lr]----time out--');
      return false;
    }
    return ret.data[0].toInt() == 0x25 &&
        ret.data.length > 5 &&
        ret.data[4].toInt() == 0x04;
  }

  /// The `0x01` brightness payload. With [auto] on the level byte is always
  /// 0: the firmware treats it as a floor and never auto-dims below it, so a
  /// non-zero level makes auto look broken (FINDINGS-battery+brightness.md,
  /// "The manual level is a floor under auto"). [level] is clamped to 0..42.
  static Uint8List brightnessPayload(int level, bool auto) {
    final wireLevel = auto ? 0 : level.clamp(0, 42);
    return Uint8List.fromList([0x01, wireLevel, auto ? 0x01 : 0x00]);
  }

  /// Set glasses display brightness on both legs.
  ///
  /// Format: `0x01 <level> <auto>` where `level` is 0..42 and `auto` is 0/1.
  /// Confirmation arrives as the firmware-pushed `F5 12 <level>` event,
  /// ingested by `DeviceStatusService`. The auto flag is not echoed by the
  /// firmware, so callers track it themselves.
  ///
  /// Sent as a broadcast write without waiting for a per-leg ack — the
  /// official Even app uses the same fire-and-forget pattern for this
  /// command and relies on the F5 12 echo for confirmation.
  static Future<void> setBrightness(int level, bool auto) async {
    final data = brightnessPayload(level, auto);
    AppLog.debug(
      '${DateTime.now()} brightness TX: level=${data[1]} auto=$auto',
      tag: 'DeviceStatus',
    );
    await BleManager.sendData(data);
  }

  /// Persist the head-up (tilt-up) behaviour on the glasses.
  ///
  /// Format: `0x08 06 00 00 03 <value>` to both legs. Verified values from
  /// the 2026-04-28 settings capture: `0x00` = the firmware's own dashboard
  /// appears on tilt-up, `0x02` = no firmware overlay (the glasses still
  /// emit `F5 02` / `F5 03`, leaving the companion app to drive any visible
  /// response). Other values in the same family exist but were not isolated.
  ///
  /// Setting persists on the glasses; survives an app uninstall. See
  /// `docs/protocol-reference.md` "Head-up settings" for the full mapping.
  static Future<void> setHeadUpMode(int value) async {
    final data =
        Uint8List.fromList([0x08, 0x06, 0x00, 0x00, 0x03, value & 0xff]);
    AppLog.debug(
      '${DateTime.now()} head-up mode TX: value=0x${(value & 0xff).toRadixString(16).padLeft(2, '0')}',
      tag: 'DeviceStatus',
    );
    await BleManager.sendData(data);
  }

  /// Local transaction counter for `0x26` writes. Starts above the typical
  /// range observed in official-app traffic to avoid early collisions; the
  /// firmware appears not to care about the exact value, but the official
  /// app increments it monotonically per change so we mirror that.
  static int _doubleTapSeq = 0x10;

  /// Persist the double-tap action on the glasses.
  ///
  /// Format: `0x26 06 00 <seq> 05 <value>` to both legs, where the
  /// double-tap-action sub-key is `0x05`. Verified values from the
  /// 2026-04-28 settings capture: `0x00` = none, `0x02` = translate,
  /// `0x03` = teleprompter, `0x04` = open the firmware's own dashboard,
  /// `0x05` = transcribe (the host-handled action that fires `F5 20`,
  /// which the companion app routes to its mode-cycle handler).
  ///
  /// Setting persists on the glasses; survives an app uninstall. See
  /// `docs/protocol-reference.md` "Touch settings" for the full mapping
  /// and the F5 20 matrix.
  static Future<void> setDoubleTapAction(int value) async {
    final seq = _doubleTapSeq & 0xff;
    _doubleTapSeq = (_doubleTapSeq + 1) & 0xff;
    final data =
        Uint8List.fromList([0x26, 0x06, 0x00, seq, 0x05, value & 0xff]);
    AppLog.debug(
      '${DateTime.now()} double-tap action TX: seq=0x${seq.toRadixString(16).padLeft(2, '0')} value=0x${(value & 0xff).toRadixString(16).padLeft(2, '0')}',
      tag: 'DeviceStatus',
    );
    await BleManager.sendData(data);
  }

  static int _timeSeq = 0;

  static Future<void> setTimeAndWeather() async {
    final now = DateTime.now();
    final utcMs = now.millisecondsSinceEpoch;
    final localOffsetMs = now.timeZoneOffset.inMilliseconds;
    final localMs = utcMs + localOffsetMs;
    final localSec = localMs ~/ 1000;

    final epoch32 = (ByteData(4)..setUint32(0, localSec, Endian.little))
        .buffer
        .asUint8List();
    final epoch64 = (ByteData(8)..setInt64(0, localMs, Endian.little))
        .buffer
        .asUint8List();

    // Only the 0x01 time/weather record. The 0x06 PANE_MODE and 0x03
    // schedule packets we used to wrap it in each persist the dashboard
    // layout (ble_proto.c:458-484), so sending them every minute overwrote
    // whatever layout the user had chosen.
    final seq = _timeSeq % 0xff;
    _timeSeq++;

    await BleManager.sendData(Uint8List.fromList([
      0x06, 0x16, 0x00, seq, 0x01,
      ...epoch32,
      ...epoch64,
      0x00, 0x00, 0x00, 0x00, 0x02,
    ]));

    AppLog.info(
      '${DateTime.now()} time sync TX: localEpoch=$localSec offset=${now.timeZoneOffset}',
      tag: 'TimeSync',
    );
  }

  static Future<bool> sendHeartBeat() async {
    final successL = await sendHeartBeatToLeg("L");
    final successR = await sendHeartBeatToLeg("R");
    return successL && successR;
  }

  static Future<String> getLegSn(String lr) async {
    var cmd = Uint8List.fromList([0x34]);
    var resp = await BleManager.request(cmd, lr: lr);
    var sn = String.fromCharCodes(resp.data.sublist(2, 18).toList());
    return sn;
  }

  /// Reads one lens's current firmware screen id.
  ///
  /// The `0x39` response is six bytes with its status at byte 1. `0xff`
  /// signals a malformed declared request length, so it is not a usable state.
  static Future<int?> readScreenState(String lr) async {
    final data = Uint8List.fromList([0x39, 0x04, 0x00, 0x00]);
    final response = await BleManager.request(data, lr: lr);
    if (response.isTimeout) {
      AppLog.info('readScreenState: $lr timed out', tag: 'GlanceClear');
      return null;
    }

    if (response.data.length != 6) {
      AppLog.info(
        'readScreenState: $lr malformed response length=${response.data.length}',
        tag: 'GlanceClear',
      );
      return null;
    }

    // Response layout (firmware `ble_process_get_req.c` case 0x39):
    //   [0..3] echo of the 4-byte request (`39 04 00 00`)
    //   [4]    constant 0x00
    //   [5]    status: 0x00 when `__is_idle()`, else the current screen id,
    //          or 0xff when the declared length did not match
    // Reading [1] returns our own echoed length byte, not the screen id.
    final screenState = response.data[5];
    if (screenState == 0xff) {
      AppLog.info(
        'readScreenState: $lr returned 0xff - check 0x39 header',
        tag: 'GlanceClear',
      );
      return null;
    }

    AppLog.debug(
      'readScreenState: $lr=0x${screenState.toRadixString(16).padLeft(2, '0')}',
      tag: 'GlanceClear',
    );
    return screenState;
  }

  /// Clears the glasses display while recording each lens's pre-clear state.
  static Future<void> clearDisplay() async {
    if (_quickNoteCaptureActive) {
      AppLog.info(
        '${DateTime.now()} clearDisplay SUPPRESSED — QuickNote capture active',
        tag: 'GlanceClear',
      );
      return;
    }

    if (postClearStateProbe) {
      final preStates = await Future.wait([
        readScreenState('L'),
        readScreenState('R'),
      ]);
      AppLog.info(
        'clearDisplay: pre-clear screen state '
        'L=${_fmtState(preStates[0])} R=${_fmtState(preStates[1])}',
        tag: 'GlanceClear',
      );
    }

    // `0x50` is a master-only dashboard lock (see the corrected entry in
    // docs/protocol-reference.md), not display-mode control. It does not clear
    // the display and the left lens rejects it outright. Kept because removing
    // it showed no measured benefit and this path has regressed before.
    if (!skipDashboardLockOnClear) {
      AppLog.info(
        '${DateTime.now()} clearDisplay TX: 0x50 dashboard-lock',
        tag: 'GlanceClear',
      );
      await BleManager.sendData(
        Uint8List.fromList([0x50, 0x06, 0x00, 0x00, 0x01, 0x01]),
        lr: 'R',
      );
    } else {
      AppLog.info(
        'clearDisplay PROBE: 0x50 dashboard-lock SKIPPED',
        tag: 'GlanceClear',
      );
    }

    AppLog.info(
      '${DateTime.now()} clearDisplay TX: 0x18 exit-to-dashboard',
      tag: 'GlanceClear',
    );
    await BleManager.sendData(
      Uint8List.fromList([0x18]),
    );
    _noteTextSurfaceCleared();

    // Diagnostic: the firmware's `0x18` teardown for screen id 0x10 (Even AI)
    // and 0x0b (Translate) is the only path that does not call
    // update_persist_task_status_to_idle, so it should leave the screen id
    // set. Reading after the clear is what distinguishes a real state leak
    // from a correct teardown.
    if (postClearStateProbe) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final postStates = await Future.wait([
        readScreenState('L'),
        readScreenState('R'),
      ]);
      AppLog.info(
        'clearDisplay: POST-clear screen state '
        'L=${_fmtState(postStates[0])} R=${_fmtState(postStates[1])}',
        tag: 'GlanceClear',
      );
    }
  }

  /// DIAGNOSTIC toggle for the "Even AI is listening" flash investigation.
  /// See docs/FINDINGS-evenai-flash-on-clear.md. Set false to restore the
  /// historical `0x50 + 0x18` clear sequence.
  ///
  /// `0x50` is a master-only dashboard lock, not display-mode control, and it
  /// does not clear anything — so skipping it should be behaviourally inert
  /// apart from the ~110 ms of wire delay it used to add before the `0x18`.
  ///
  /// Left `false` (i.e. `0x50` still sent) deliberately. Removing it showed no
  /// measured benefit over 8 mode switches, and the 2026-05-09 "Glance
  /// auto-clear regression" in `worklist-history.md` shows this path punishes
  /// untested changes. The broader question is tracked as
  /// `nav-0x50-necessity`.
  static const bool skipDashboardLockOnClear = false;

  /// Post-clear `0x39` sampling. Off by default — it costs two BLE round
  /// trips per clear and only catches roughly a third of flash events (see
  /// docs/FINDINGS-evenai-flash-on-clear.md). Retained for future runs.
  static const bool postClearStateProbe = false;

  static String _fmtState(int? v) =>
      v == null ? '??' : '0x${v.toRadixString(16).padLeft(2, '0')}';

  /// Show a brief title card on the glasses, then clear.
  ///
  /// Sends [text] via the standard `0x4E` text path, holds for [duration],
  /// then issues the instrumented `0x50 + 0x18` clear path. Used for Glance/Navigate
  /// mode-entry flashes and the post-reconnect screen-state reset.
  ///
  /// Callers are responsible for gating: this does not check session state.
  static Future<void> showTitleCard(
    String text, {
    Duration duration = const Duration(milliseconds: 500),
  }) async {
    await TextService.get.startSendText(text);
    await Future<void>.delayed(duration);
    await TextService.get.stopTextSendingByOS();
    await clearDisplay();
  }

  // tell the glasses to exit function to dashboard
  static Future<bool> exit() async {
    AppLog.debug("send exit all func");
    var data = Uint8List.fromList([0x18]);
    _noteTextSurfaceCleared();

    var retL = await BleManager.request(data, lr: "L", timeoutMs: 1500);
    AppLog.debug('${DateTime.now()} exit----L----ret---${retL.data}--');
    if (retL.isTimeout) {
      return false;
    } else if (retL.data.isNotEmpty && retL.data[1].toInt() == 0xc9) {
      var retR = await BleManager.request(data, lr: "R", timeoutMs: 1500);
      AppLog.debug('${DateTime.now()} exit----R----retR---${retR.data}--');
      if (retR.isTimeout) {
        return false;
      } else if (retR.data.isNotEmpty && retR.data[1].toInt() == 0xc9) {
        return true;
      } else {
        return false;
      }
    } else {
      return false;
    }
  }

  /// Prime the structured text renderer for `0x52` incremental updates.
  ///
  /// Sends `0x50` display mode control first, then the observed `0x52` init
  /// frame `52 06 00 00 01 01`. A 5-second `0x53` keepalive is started and
  /// the current text buffer is cleared.
  static Future<void> startStreamingText() async {
    await stopStreamingText(sendFinalFrame: false);

    // 0x50 is master-only; the left lens rejects it (ble_proto.c:3956).
    await BleManager.sendData(
      Uint8List.fromList([0x50, 0x06, 0x00, 0x00, 0x01, 0x01]),
      lr: 'R',
    );
    await BleManager.sendData(
      Uint8List.fromList([0x52, 0x06, 0x00, 0x00, 0x01, 0x01]),
    );

    _streamTextSeq = 1;
    _streamingTextActive = true;
    _lastStreamingText = '';
    _lastStreamingLine = 2;
    _startStreamingKeepAlive();

    AppLog.info('${DateTime.now()} streaming started', tag: 'Chat');
  }

  /// Send the full current text buffer to the streaming renderer.
  ///
  /// The firmware replaces the target line content on each `0x52` frame, so
  /// callers must pass the whole current buffer rather than a delta.
  static Future<void> sendStreamingText(
    String text, {
    int line = 2,
    bool isFinal = false,
  }) async {
    if (!_streamingTextActive) {
      await startStreamingText();
    }

    final normalized = text.replaceAll('\r', '');
    _lastStreamingText = normalized;
    _lastStreamingLine = line;

    await BleManager.sendData(_buildStreamingCursorPacket(line: line));
    await BleManager.sendData(
      _buildStreamingTextPacket(
        normalized,
        line: line,
        confirmed: isFinal,
      ),
    );

    AppLog.info(
      '${DateTime.now()} streaming update -> line=$line len=${normalized.length}',
      tag: 'Chat',
    );
  }

  /// Send a non-animated `0x52` line update for committed visible context.
  ///
  /// This uses the same full-line replacement behavior as [sendStreamingText]
  /// but skips the cursor frame so historic lines appear stable.
  static Future<void> sendStreamingLine(
    String text, {
    required int line,
    bool confirmed = false,
  }) async {
    if (!_streamingTextActive) {
      await startStreamingText();
    }

    final normalized = text.replaceAll('\r', '');
    await BleManager.sendData(
      _buildStreamingTextPacket(
        normalized,
        line: line,
        confirmed: confirmed,
      ),
    );

    AppLog.info(
      '${DateTime.now()} streaming line update -> line=$line len=${normalized.length}',
      tag: 'Chat',
    );
  }

  /// Stop the active `0x52` session and its `0x53` keepalive.
  static Future<void> stopStreamingText({
    bool sendFinalFrame = true,
  }) async {
    final wasActive = _streamingTextActive;
    final finalText = _lastStreamingText;

    _streamingKeepAliveTimer?.cancel();
    _streamingKeepAliveTimer = null;
    _streamingTextActive = false;

    if (wasActive && sendFinalFrame && finalText.isNotEmpty) {
      await BleManager.sendData(_buildStreamingCursorPacket(line: _lastStreamingLine));
      await BleManager.sendData(
        _buildStreamingTextPacket(
          finalText,
          line: _lastStreamingLine,
          confirmed: true,
        ),
      );
    }

    _lastStreamingText = '';
    _lastStreamingLine = 2;

    if (wasActive) {
      AppLog.info('${DateTime.now()} streaming stopped', tag: 'Chat');
    }
  }

  static List<Uint8List> _getPackList(int cmd, Uint8List data,
      {int count = 20}) {
    final realCount = count - 3;
    List<Uint8List> send = [];
    int maxSeq = data.length ~/ realCount;
    if (data.length % realCount > 0) {
      maxSeq++;
    }
    for (var seq = 0; seq < maxSeq; seq++) {
      var start = seq * realCount;
      var end = start + realCount;
      if (end > data.length) {
        end = data.length;
      }
      var itemData = data.sublist(start, end);
      var pack = Utils.addPrefixToUint8List([cmd, maxSeq, seq], itemData);
      send.add(pack);
    }
    return send;
  }

  static Future<void> sendNewAppWhiteListJson(String whitelistJson) async {
    AppLog.debug(
        "proto -> sendNewAppWhiteListJson: whitelist = $whitelistJson");
    final whitelistData = utf8.encode(whitelistJson);
    //  2、转换为接口格式
    final dataList = _getPackList(0x04, whitelistData, count: 180);
    AppLog.debug(
        "proto -> sendNewAppWhiteListJson: length = ${dataList.length}, dataList = $dataList");
    for (var i = 0; i < 3; i++) {
      final isSuccess =
          await BleManager.requestList(dataList, timeoutMs: 300, lr: "L");
      if (isSuccess) {
        return;
      }
    }
  }

  /// 发送通知
  ///
  /// - app [Map] 通知消息数据
  static Future<void> sendNotify(Map appData, int notifyId,
      {int retry = 6}) async {
    final notifyJson = jsonEncode({
      "ncs_notification": appData,
    });
    final dataList =
        _getNotifyPackList(0x4B, notifyId, utf8.encode(notifyJson));
    AppLog.debug(
        "proto -> sendNotify: notifyId = $notifyId, data length = ${dataList.length} , data = $dataList, app = $notifyJson");
    for (var i = 0; i < retry; i++) {
      final isSuccess =
          await BleManager.requestList(dataList, timeoutMs: 1000, lr: "L");
      if (isSuccess) {
        return;
      }
    }
  }

  static List<Uint8List> _getNotifyPackList(
      int cmd, int msgId, Uint8List data) {
    List<Uint8List> send = [];
    int maxSeq = data.length ~/ 176;
    if (data.length % 176 > 0) {
      maxSeq++;
    }
    for (var seq = 0; seq < maxSeq; seq++) {
      var start = seq * 176;
      var end = start + 176;
      if (end > data.length) {
        end = data.length;
      }
      var itemData = data.sublist(start, end);
      var pack =
          Utils.addPrefixToUint8List([cmd, msgId, maxSeq, seq], itemData);
      send.add(pack);
    }
    return send;
  }

  static void _startStreamingKeepAlive() {
    _streamingKeepAliveTimer?.cancel();
    _streamingKeepAliveTimer =
        Timer.periodic(_streamingKeepAliveInterval, (_) async {
      if (!_streamingTextActive) {
        return;
      }
      // A bare 0x53 fails the firmware's length check and never resets the
      // 30 s transcribe timeout (ble_proto.c:4165, ui_transcribe_info.c:111).
      // Op 3 resets it and replies DONE/ERR by whether the session runs.
      final seq = _streamKeepAliveSeq & 0xff;
      _streamKeepAliveSeq = (_streamKeepAliveSeq + 1) & 0xff;
      await BleManager.sendData(
          Uint8List.fromList([0x53, 0x06, 0x00, seq, 0x03, 0x00]));
      AppLog.info('${DateTime.now()} keepalive sent', tag: 'Chat');
    });
  }

  static Uint8List _buildStreamingCursorPacket({
    int line = 1,
  }) {
    final seq = _nextStreamingSeq();
    return Uint8List.fromList([
      0x52,
      0x0e,
      0x00,
      seq,
      0x02,
      0x02,
      0x00,
      line & 0xff,
      0x00,
      0x00,
      0x00,
      0x00,
      0x0a,
      0x0a,
    ]);
  }

  static Uint8List _buildStreamingTextPacket(
    String text, {
    required int line,
    required bool confirmed,
  }) {
    final seq = _nextStreamingSeq();
    final textBytes = utf8.encode(text);
    final payload = <int>[
      0x02,
      0x02,
      0x00,
      line & 0xff,
      0x00,
      confirmed ? 0x01 : 0x00,
      0x00,
      0x00,
      ...textBytes,
      0x0a,
    ];
    return Uint8List.fromList([
      0x52,
      (4 + payload.length) & 0xff,
      0x00,
      seq,
      ...payload,
    ]);
  }

  static int _nextStreamingSeq() {
    final seq = _streamTextSeq & 0xff;
    _streamTextSeq = (_streamTextSeq + 1) & 0xff;
    return seq;
  }
}
