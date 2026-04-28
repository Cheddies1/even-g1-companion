import 'dart:convert';
import 'dart:typed_data';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/evenai_proto.dart';
import 'package:demo_ai_even/utils/utils.dart';

class Proto {
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
    final data = Uint8List.fromList([0x08, 0x06, 0x00, 0x00, 0x03, value & 0xff]);
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
    final data = Uint8List.fromList([0x26, 0x06, 0x00, seq, 0x05, value & 0xff]);
    AppLog.debug(
      '${DateTime.now()} double-tap action TX: seq=0x${seq.toRadixString(16).padLeft(2, '0')} value=0x${(value & 0xff).toRadixString(16).padLeft(2, '0')}',
      tag: 'DeviceStatus',
    );
    await BleManager.sendData(data);
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
    AppLog.debug("proto -> sendNewAppWhiteListJson: whitelist = $whitelistJson");
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
}
