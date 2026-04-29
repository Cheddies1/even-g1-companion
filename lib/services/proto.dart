import 'dart:convert';
import 'dart:typed_data';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/evenai_proto.dart';
import 'package:demo_ai_even/services/nav_icon_generator.dart';
import 'package:demo_ai_even/services/nav_replay_data.dart';
import 'package:demo_ai_even/utils/utils.dart';

class _NavReplayLegStats {
  int packetCount = 0;
  DateTime? startedAt;
  DateTime? endedAt;
}

class _NavReplayPairStats {
  int pairCount = 0;
  DateTime? startedAt;
  DateTime? endedAt;
}

class _NavTripStatusPayload {
  const _NavTripStatusPayload({
    required this.eta,
    required this.totalDistance,
    required this.roadName,
    required this.turnDistance,
    required this.speed,
    required this.navIconSource,
    required this.navIconPngBase64,
  });

  final String eta;
  final String totalDistance;
  final String roadName;
  final String turnDistance;
  final String speed;
  final String navIconSource;
  final String navIconPngBase64;
}

class Proto {
  static const String navReplayModeBroadcast = 'broadcast';
  static const String navReplayModeSequentialRightFirst =
      'sequential-right-first';
  static const String navReplayModeSequentialLeftFirst =
      'sequential-left-first';
  static const String navReplayModeInterleaved = 'interleaved';

  // Toggle this between the constants above while testing the 0x0a replay.
  static const String _navReplayMode = navReplayModeInterleaved;
  static const Duration _navReplayInterPacketDelay = Duration(milliseconds: 30);
  static const Duration _navReplayBurstPause = Duration(milliseconds: 50);
  static const int _navReplayBurstSize = 10;
  static const Duration _navReplayInterleavedLegDelay =
      Duration(milliseconds: 10);
  static const Duration _navReplayInterleavedPairDelay =
      Duration(milliseconds: 20);

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

  /// Even AI
  static int _evenaiSeq = 0;
  // AI result transmission (also compatible with AI startup and Q&A status synchronization)
  static Future<bool> sendEvenAIData(String text,
      {int? timeoutMs,
      required int newScreen,
      required int pos,
      required int current_page_num,
      required int max_page_num}) async {
    var data = utf8.encode(text);
    var syncSeq = _evenaiSeq & 0xff;

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
    return true;
  }

  static int _beatHeartSeq = 0;
  static Uint8List _nextHeartBeatPacket() {
    final length = 6;
    final seq = _beatHeartSeq % 0xff;
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
    final clamped = level.clamp(0, 42);
    final autoByte = auto ? 0x01 : 0x00;
    final data = Uint8List.fromList([0x01, clamped, autoByte]);
    AppLog.debug(
      '${DateTime.now()} brightness TX: level=$clamped auto=$auto',
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

  /// Sequence counter for `0x0a` navigation card packets.
  static int _navSeq = 0;

  /// Prime the glasses display for navigation card mode.
  ///
  /// Sends three frames in order:
  /// 1. `0x50 06 00 00 01 01` — display mode control (clear + prepare)
  /// 2. `0x0a 06 00 <seq> 00 01` — enter navigation display mode
  /// 3. `0x0a 06 00 <seq> 04 01` — ready for card data
  ///
  /// Call once before the first [sendNavCard] in a session. See
  /// `docs/protocol-reference.md` "Navigation card" and "Display mode
  /// control".
  static Future<void> sendNavModeEnter() async {
    // INIT (sub-cmd 0x00) — enter navigation display mode.
    // Fire-and-forget: firmware does not ack 0x0a (confirmed by timeout logs).
    final enterSeq = _navSeq & 0xff;
    _navSeq++;
    await BleManager.sendData(
        Uint8List.fromList([0x0a, 0x06, 0x00, enterSeq, 0x00, 0x01]));
    // SYNC (sub-cmd 0x04) — prepare for card data
    final readySeq = _navSeq & 0xff;
    _navSeq++;
    await BleManager.sendData(
        Uint8List.fromList([0x0a, 0x06, 0x00, readySeq, 0x04, 0x01]));
    AppLog.info('${DateTime.now()} nav mode entered', tag: 'Navigate');
  }

  /// Send a structured navigation card to the glasses.
  ///
  /// Format: `0x0a <len> 00 <seq> 01 03 c8 00 12 00 <eta> 00 <dist> 00
  /// <road> 00 <turn> 00`. Null-separated UTF-8 text fields that the
  /// firmware renders into its built-in navigation card template.
  ///
  /// Fire-and-forget broadcast to both legs. See
  /// `docs/protocol-reference.md` "Navigation card" sub-type 1.
  static Future<void> sendNavCard({
    required String eta,
    required String distance,
    required String roadName,
    required String turnDistance,
    String speed = '',
  }) async {
    final etaBytes = utf8.encode(eta);
    final distBytes = utf8.encode(distance);
    final roadBytes = utf8.encode(roadName);
    final turnBytes = utf8.encode(turnDistance);
    final speedBytes = utf8.encode(speed);

    const prefix = <int>[0x01, 0x03, 0xc8, 0x00, 0x12, 0x00];
    final fieldsPayload = <int>[
      ...prefix,
      ...etaBytes,
      0x00,
      ...distBytes,
      0x00,
      ...roadBytes,
      0x00,
      ...turnBytes,
      0x00,
      ...speedBytes,
      0x00,
    ];

    final seq = _navSeq & 0xff;
    _navSeq++;
    final totalLen = 4 + fieldsPayload.length;
    final packet = <int>[
      0x0a,
      totalLen & 0xff,
      0x00,
      seq,
      ...fieldsPayload,
    ];

    final data = Uint8List.fromList(packet);
    AppLog.debug(
      '${DateTime.now()} nav card TX: eta="$eta" dist="$distance" road="$roadName" turn="$turnDistance" speed="$speed" len=${data.length}',
      tag: 'Navigate',
    );
    await BleManager.sendData(data);

    // Trailing SYNC (sub-cmd 0x04) — commit/render signal.
    final syncSeq = _navSeq & 0xff;
    _navSeq++;
    await BleManager.sendData(
        Uint8List.fromList([0x0a, 0x06, 0x00, syncSeq, 0x04, 0x01]));

    AppLog.debug(
      '${DateTime.now()} nav card sent: text + trailing SYNC (no icon/map)',
      tag: 'Navigate',
    );
  }

  static Future<void> sendNavTripStatusAndSync({
    required String eta,
    required String distance,
    required String roadName,
    required String turnDistance,
    String speed = '0.0km/h',
    required String navIconSource,
  }) async {
    final packet = _buildNavTripStatusPacket(
      seq: _navSeq & 0xff,
      payload: _NavTripStatusPayload(
        eta: eta,
        totalDistance: distance,
        roadName: roadName,
        turnDistance: turnDistance,
        speed: speed,
        navIconSource: navIconSource,
        navIconPngBase64: '',
      ),
    );
    _navSeq++;
    await BleManager.sendData(packet);
    await sendNavSync(logSend: false);
    AppLog.info(
      '${DateTime.now().toIso8601String()} nav update sent: TRIP_STATUS+SYNC len=${packet.length}',
      tag: 'Navigate',
    );
  }

  /// Exit navigation card mode using the proper EXIT sub-command (0x05).
  /// DEBUG: Replay ALL snooped `0x0a` lifecycle packets with selectable
  /// transport ordering, without changing the captured payload bytes.
  static Future<void> sendNavCardReplayTest() async {
    final replayPackets =
        navReplayHexPackets.map(_decodeHexPacket).toList();
    final dynamicTripStatus = _pendingReplayTripStatus;
    _pendingReplayTripStatus = null;
    final tripStatusReplaced = dynamicTripStatus == null
        ? false
        : _replaceReplayTripStatusPacket(replayPackets, dynamicTripStatus);
    final mapOverviewReplaced = await _replaceReplayMapOverviewPackets(
      replayPackets,
      dynamicTripStatus,
    );
    final availableLegs = ['L', 'R']
        .where((lr) => BleManager.get().isLegAvailable(lr))
        .toList(growable: false);
    final totalStartedAt = DateTime.now();
    final legStats = <String, _NavReplayLegStats>{
      'L': _NavReplayLegStats(),
      'R': _NavReplayLegStats(),
    };
    final pairStats = _NavReplayPairStats();

    AppLog.info(
      '${totalStartedAt.toIso8601String()} nav replay mode=$_navReplayMode packetCount=${replayPackets.length} availableLegs=${availableLegs.join(",")} tripStatusReplaced=$tripStatusReplaced mapOverviewReplaced=$mapOverviewReplaced',
      tag: 'Navigate',
    );

    if (availableLegs.isEmpty) {
      AppLog.error(
        '${DateTime.now().toIso8601String()} nav replay skipped: no available legs',
        tag: 'Navigate',
      );
      return;
    }

    BleManager.get().suspendHeartbeats(reason: 'nav-replay');
    try {
      switch (_navReplayMode) {
        case navReplayModeBroadcast:
          final broadcastStartedAt = DateTime.now();
          for (final lr in availableLegs) {
            legStats[lr]!.startedAt = broadcastStartedAt;
          }
          await _sendNavReplayBroadcast(replayPackets);
          final broadcastEndedAt = DateTime.now();
          for (final lr in availableLegs) {
            final stats = legStats[lr]!;
            stats.packetCount = replayPackets.length;
            stats.endedAt = broadcastEndedAt;
          }
          break;
        case navReplayModeSequentialLeftFirst:
        case navReplayModeSequentialRightFirst:
          for (final lr in _navReplaySequentialLegOrder(availableLegs)) {
            await _sendNavReplayToLeg(lr, replayPackets, legStats[lr]!);
          }
          break;
        case navReplayModeInterleaved:
          await _sendNavReplayInterleaved(
            replayPackets,
            availableLegs,
            legStats,
            pairStats,
          );
          break;
        default:
          AppLog.error(
            '${DateTime.now().toIso8601String()} nav replay aborted: unsupported mode=$_navReplayMode',
            tag: 'Navigate',
          );
          return;
      }
    } finally {
      BleManager.get().resumeHeartbeats(reason: 'nav-replay');
    }

    for (final lr in ['L', 'R']) {
      final stats = legStats[lr]!;
      AppLog.info(
        '${DateTime.now().toIso8601String()} nav replay leg=$lr packetCount=${stats.packetCount} start=${stats.startedAt?.toIso8601String() ?? "n/a"} end=${stats.endedAt?.toIso8601String() ?? "n/a"}',
        tag: 'Navigate',
      );
    }
    if (_navReplayMode == navReplayModeInterleaved) {
      AppLog.info(
        '${DateTime.now().toIso8601String()} nav replay pairs=${pairStats.pairCount} start=${pairStats.startedAt?.toIso8601String() ?? "n/a"} end=${pairStats.endedAt?.toIso8601String() ?? "n/a"}',
        tag: 'Navigate',
      );
    }

    final totalDurationMs =
        DateTime.now().difference(totalStartedAt).inMilliseconds;
    AppLog.info(
      '${DateTime.now().toIso8601String()} nav replay complete mode=$_navReplayMode totalDurationMs=$totalDurationMs',
      tag: 'Navigate',
    );
  }

  static Future<void> sendNavModeExit() async {
    final seq = _navSeq & 0xff;
    _navSeq++;
    await BleManager.sendData(
        Uint8List.fromList([0x0a, 0x06, 0x00, seq, 0x05, 0x01]));
    AppLog.debug('${DateTime.now()} nav EXIT sent', tag: 'Navigate');
  }

  static Future<void> sendNavSync({bool logSend = true}) async {
    final seq = _navSeq & 0xff;
    _navSeq++;
    await BleManager.sendData(
      Uint8List.fromList([0x0a, 0x06, 0x00, seq, 0x04, 0x01]),
    );
    if (logSend) {
      AppLog.info(
        '${DateTime.now().toIso8601String()} nav SYNC sent seq=0x${seq.toRadixString(16).padLeft(2, '0')}',
        tag: 'Navigate',
      );
    }
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

  // tell the glasses to exit function to dashboard
  static Future<bool> exit() async {
    AppLog.debug("send exit all func");
    var data = Uint8List.fromList([0x18]);

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

  static Uint8List _decodeHexPacket(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  static List<String> _navReplaySequentialLegOrder(List<String> availableLegs) {
    final preferredOrder = _navReplayMode == navReplayModeSequentialLeftFirst
        ? const ['L', 'R']
        : const ['R', 'L'];
    return preferredOrder.where(availableLegs.contains).toList(growable: false);
  }

  static Future<void> _sendNavReplayBroadcast(
    List<Uint8List> replayPackets,
  ) async {
    for (int i = 0; i < replayPackets.length; i++) {
      await BleManager.sendData(replayPackets[i], secondDelay: 0);
      await _applyNavReplayPacing(i, replayPackets.length);
    }
  }

  static Future<void> _sendNavReplayToLeg(
    String lr,
    List<Uint8List> replayPackets,
    _NavReplayLegStats stats,
  ) async {
    stats.startedAt = DateTime.now();
    for (int i = 0; i < replayPackets.length; i++) {
      await BleManager.sendData(replayPackets[i], lr: lr);
      stats.packetCount++;
      await _applyNavReplayPacing(i, replayPackets.length);
    }
    stats.endedAt = DateTime.now();
  }

  static Future<void> _sendNavReplayInterleaved(
    List<Uint8List> replayPackets,
    List<String> availableLegs,
    Map<String, _NavReplayLegStats> legStats,
    _NavReplayPairStats pairStats,
  ) async {
    const rightFirstOrder = ['R', 'L'];
    final pairLegOrder =
        rightFirstOrder.where(availableLegs.contains).toList(growable: false);
    if (pairLegOrder.isEmpty) {
      return;
    }

    pairStats.startedAt = DateTime.now();
    for (final lr in pairLegOrder) {
      legStats[lr]!.startedAt = pairStats.startedAt;
    }

    for (int i = 0; i < replayPackets.length; i++) {
      final packet = replayPackets[i];
      for (int legIndex = 0; legIndex < pairLegOrder.length; legIndex++) {
        final lr = pairLegOrder[legIndex];
        await BleManager.sendData(packet, lr: lr);
        final stats = legStats[lr]!;
        stats.packetCount++;
        if (legIndex < pairLegOrder.length - 1) {
          await Future<void>.delayed(_navReplayInterleavedLegDelay);
        }
      }
      pairStats.pairCount++;
      await _applyNavReplayInterleavedPacing(i, replayPackets.length);
    }

    pairStats.endedAt = DateTime.now();
    for (final lr in pairLegOrder) {
      legStats[lr]!.endedAt = pairStats.endedAt;
    }
  }

  static Future<void> _applyNavReplayPacing(
    int packetIndex,
    int packetCount,
  ) async {
    final isLastPacket = packetIndex >= packetCount - 1;
    if (isLastPacket) {
      return;
    }
    await Future<void>.delayed(_navReplayInterPacketDelay);
    if (packetIndex % _navReplayBurstSize == _navReplayBurstSize - 1) {
      await Future<void>.delayed(_navReplayBurstPause);
    }
  }

  static Future<void> _applyNavReplayInterleavedPacing(
    int packetIndex,
    int packetCount,
  ) async {
    final isLastPacket = packetIndex >= packetCount - 1;
    if (isLastPacket) {
      return;
    }
    await Future<void>.delayed(_navReplayInterleavedPairDelay);
    if (packetIndex % _navReplayBurstSize == _navReplayBurstSize - 1) {
      await Future<void>.delayed(_navReplayBurstPause);
    }
  }

  static _NavTripStatusPayload? _pendingReplayTripStatus;

  static void setReplayTripStatus({
    required String eta,
    required String totalDistance,
    required String roadName,
    required String turnDistance,
    String speed = '0.0km/h',
    required String navIconSource,
    String navIconPngBase64 = '',
  }) {
    _pendingReplayTripStatus = _NavTripStatusPayload(
      eta: eta,
      totalDistance: totalDistance,
      roadName: roadName,
      turnDistance: turnDistance,
      speed: speed,
      navIconSource: navIconSource,
      navIconPngBase64: navIconPngBase64,
    );
  }

  static int _directionTurnForPayload(_NavTripStatusPayload payload) {
    return classifyManoeuvre(
      navIconSource: payload.navIconSource,
      instructionText: '${payload.turnDistance} ${payload.roadName}',
    ).directionTurnByte;
  }

  static Uint8List _buildReplayTripStatusPacket({
    required int seq,
    required _NavTripStatusPayload payload,
  }) {
    return _buildNavTripStatusPacket(seq: seq, payload: payload);
  }

  static Uint8List _buildNavTripStatusPacket({
    required int seq,
    required _NavTripStatusPayload payload,
  }) {
    final directionTurn = _directionTurnForPayload(payload);
    const x0 = 0xc8;
    const x1 = 0x00;
    const y = 0x12;

    final fieldsPayload = <int>[
      0x01,
      directionTurn,
      x0,
      x1,
      y,
      0x00,
      ...utf8.encode(payload.eta),
      0x00,
      ...utf8.encode(payload.totalDistance),
      0x00,
      ...utf8.encode(payload.roadName),
      0x00,
      ...utf8.encode(payload.turnDistance),
      0x00,
      ...utf8.encode(payload.speed),
      0x00,
    ];
    final totalLen = 4 + fieldsPayload.length;
    final packet = Uint8List.fromList([
      0x0a,
      totalLen & 0xff,
      0x00,
      seq & 0xff,
      ...fieldsPayload,
    ]);
    AppLog.info(
      '${DateTime.now().toIso8601String()} dynamic TRIP_STATUS fields: eta="${payload.eta}" dist="${payload.totalDistance}" road="${payload.roadName}" turn="${payload.turnDistance}" speed="${payload.speed}"',
      tag: 'Navigate',
    );
    AppLog.info(
      '${DateTime.now().toIso8601String()} dynamic TRIP_STATUS DirectionTurn=0x${directionTurn.toRadixString(16).padLeft(2, '0')} len=${packet.length}',
      tag: 'Navigate',
    );
    return packet;
  }

  static bool _replaceReplayTripStatusPacket(
    List<Uint8List> replayPackets,
    _NavTripStatusPayload payload,
  ) {
    for (int i = 0; i < replayPackets.length; i++) {
      final packet = replayPackets[i];
      if (packet.length > 5 && packet[0] == 0x0a && packet[4] == 0x01) {
        replayPackets[i] = _buildReplayTripStatusPacket(
          seq: packet[3],
          payload: payload,
        );
        return true;
      }
    }
    return false;
  }

  /// Replace captured MAP_OVERVIEW packets with icon data.
  ///
  /// Primary: convert the scraped Google Maps notification PNG.
  /// Fallback: generate a geometric arrow for the classified manoeuvre.
  /// Last resort: leave captured data untouched.
  static Future<bool> _replaceReplayMapOverviewPackets(
    List<Uint8List> replayPackets,
    _NavTripStatusPayload? payload,
  ) async {
    // Find indices of all MAP_OVERVIEW packets (sub-cmd 0x02).
    final oldIndices = <int>[];
    for (int i = 0; i < replayPackets.length; i++) {
      final p = replayPackets[i];
      if (p.length > 5 && p[0] == 0x0a && p[4] == 0x02) {
        oldIndices.add(i);
      }
    }
    if (oldIndices.isEmpty) return false;

    final startSeq = replayPackets[oldIndices.first][3];
    final navIconPng = payload?.navIconPngBase64 ?? '';
    final navIconSource = payload?.navIconSource ?? '';
    final instructionText =
        '${payload?.turnDistance ?? ''} ${payload?.roadName ?? ''}';

    // Try PNG conversion first (actual Google Maps icon).
    List<Uint8List>? generated =
        await convertPngToMapOverviewPackets(navIconPng, startSeq);
    String iconSource = 'png';

    // Fall back to geometric arrow.
    if (generated == null || generated.isEmpty) {
      final manoeuvre = classifyManoeuvre(
        navIconSource: navIconSource,
        instructionText: instructionText,
      );
      generated = generateMapOverviewPackets(manoeuvre, startSeq);
      iconSource = 'generated($manoeuvre)';
    }

    // Last resort: keep captured data.
    if (generated == null || generated.isEmpty) {
      AppLog.info(
        'MAP_OVERVIEW: using captured fallback '
        'navIconSource="$navIconSource"',
        tag: 'Navigate',
      );
      return false;
    }

    // Replace: remove old, insert new.
    for (int i = oldIndices.length - 1; i >= 0; i--) {
      replayPackets.removeAt(oldIndices[i]);
    }
    replayPackets.insertAll(oldIndices.first, generated);

    // Renumber seq bytes for all 0x0a packets to keep them consecutive.
    int seq = -1;
    for (final p in replayPackets) {
      if (p[0] == 0x0a && p.length >= 4) {
        if (seq < 0) {
          seq = p[3];
        } else {
          p[3] = seq & 0xff;
        }
        seq++;
      }
    }

    AppLog.info(
      'MAP_OVERVIEW replaced: source=$iconSource '
      'navIconSource="$navIconSource" '
      'oldBands=${oldIndices.length} newBands=${generated.length} '
      'totalPackets=${replayPackets.length}',
      tag: 'Navigate',
    );
    return true;
  }
}
