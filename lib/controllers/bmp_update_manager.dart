import 'dart:io';
import 'dart:typed_data';

import 'package:crclib/catalog.dart';
import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/utils/utils.dart';

class BmpUpdateManager {
  
  static bool isTransfering = false;

  Future<BmpTransferResult> updateBmp(String lr, Uint8List image, {int? seq}) async {
    var writeWarnings = 0;

    // check if has error sending package
    bool isOldSendPackError(int? currentSeq) {
      bool oldSendError = (seq == null && currentSeq != null);
      if (oldSendError) {
        AppLog.error(
          'updateBmp: old pack send error, seq = $currentSeq',
          tag: 'BmpUpdate',
        );
      }
      return oldSendError;
    }

    const int packLen = 194; //198;
    List<Uint8List> multiPacks = [];
    for (int i = 0; i < image.length; i += packLen) { 
      int end = (i + packLen < image.length) ? i + packLen : image.length;
      final singlePack = image.sublist(i, end);
      multiPacks.add(singlePack);
    }

    AppLog.info(
      '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=packets totalPacks=${multiPacks.length} bytes=${image.length}',
    );

    for (int index = 0; index < multiPacks.length; index++) { 
      if (isOldSendPackError(seq)) {
        return const BmpTransferResult(
          success: false,
          failureStage: BmpFailureStage.packetWrite,
        );
      }
      if (seq != null && index < seq) continue;

      
      final pack = multiPacks[index];  
      // address in glasses [0x00, 0x1c, 0x00, 0x00] , taken in the first package
      Uint8List data = index == 0 ? Utils.addPrefixToUint8List([0x15, index & 0xff, 0x00, 0x1c, 0x00, 0x00],  pack) : Utils.addPrefixToUint8List([0x15, index & 0xff], pack);
      final sendOk = await BleManager.sendData(
          data,
          lr: lr);
      if (sendOk != true) {
        AppLog.error(
          '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=writeWarning index=$index cmd=0x15 sendOk=$sendOk',
        );
        writeWarnings++;
      }

      if (Platform.isIOS) {
        await Future.delayed(Duration(milliseconds: 8)); // 4 6 10 14  30
      } else {
        await Future.delayed(Duration(milliseconds: 5));  // 5
      }

      var offset = index * packLen;
      if (offset > image.length - packLen) {
        offset = image.length - pack.length;
      }
      _onProgressCall(lr, offset, index, image.length, multiPacks.length);
    }
    // await Future.delayed(Duration(seconds: 2)); // todo
    if (isOldSendPackError(seq)) {
      return BmpTransferResult(
        success: false,
        failureStage: BmpFailureStage.packetWrite,
        writeWarnings: writeWarnings,
      );
    }

    const maxRetryTime = 10;
    int currentRetryTime = 0;
    Future<bool> finishUpdate() async {
      AppLog.info(
        '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=finishCommand attempt=${currentRetryTime + 1}/$maxRetryTime',
      );
      if (currentRetryTime >= maxRetryTime) {
        return false;
      }
      
      // notice the finish sending
      var ret = await BleManager.request(
        Uint8List.fromList([0x20, 0x0d, 0x0e]),
        lr: lr,
        timeoutMs: 3000,
      );
      AppLog.info(
        '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=finishReply timeout=${ret.isTimeout} data=${ret.data.hexString}',
      );
      if (ret.isTimeout) {
        currentRetryTime++;
        await Future.delayed(Duration(seconds: 1));
        return finishUpdate();
      }
      return ret.data[1].toInt() == 0xc9;
    }

    var isSuccess = await finishUpdate();

    AppLog.info(
      '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=finishResult success=$isSuccess',
    );
    if (!isSuccess) {
      return BmpTransferResult(
        success: false,
        failureStage: BmpFailureStage.finish,
        writeWarnings: writeWarnings,
      );
    }

    // take address in the first package
    Uint8List result = prependAddress(image);
    var crc32 = Crc32Xz().convert(result); 
    var val = crc32.toBigInt().toInt();
    var crc = Uint8List.fromList([
      val >> 8 * 3 & 0xff,
      val >> 8 * 2 & 0xff,
      val >> 8 & 0xff,
      val & 0xff,
    ]);
    
    final ret = await BleManager.request(
        Utils.addPrefixToUint8List([0x16], crc),
        lr: lr);

    AppLog.info(
      '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=crcReply data=${ret.data.hexString} crc=${crc.hexString}',
    );

    if (ret.data.length > 4 && ret.data[5] != 0xc9) {
      AppLog.error('${DateTime.now()} NavigateBmpTrace: leg=$lr stage=crcResult success=false');
      return BmpTransferResult(
        success: false,
        failureStage: BmpFailureStage.crc,
        writeWarnings: writeWarnings,
      );
    }

    AppLog.info('${DateTime.now()} NavigateBmpTrace: leg=$lr stage=crcResult success=true');
    return BmpTransferResult(
      success: true,
      writeWarnings: writeWarnings,
    );
  }

  void _onProgressCall(String lr, int offset, int index, int total, int totalPacks) {
    if (index != 0 && index != totalPacks ~/ 2 && index != totalPacks - 1) {
      return;
    }
    double progress = (offset / total) * 100;
    AppLog.info(
      '${DateTime.now()} NavigateBmpTrace: leg=$lr stage=progress index=$index totalPacks=$totalPacks progress=${progress.toStringAsFixed(2)}',
    );
  }


  Uint8List prependAddress(Uint8List image) {

    List<int> addressBytes = [0x00, 0x1c, 0x00, 0x00];
    Uint8List newImage = Uint8List(addressBytes.length + image.length);
    newImage.setRange(0, addressBytes.length, addressBytes);
    newImage.setRange(addressBytes.length, newImage.length, image);
    return newImage;
  }
}

enum BmpFailureStage {
  packetWrite,
  finish,
  crc,
}

class BmpTransferResult {
  const BmpTransferResult({
    required this.success,
    this.failureStage,
    this.writeWarnings = 0,
  });

  final bool success;
  final BmpFailureStage? failureStage;
  final int writeWarnings;
}
