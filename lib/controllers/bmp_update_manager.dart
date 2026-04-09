import 'dart:io';
import 'dart:typed_data';

import 'package:crclib/catalog.dart';
import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/utils/utils.dart';

class BmpUpdateManager {
  
  static bool isTransfering = false;

  Future<bool> updateBmp(String lr, Uint8List image, {int? seq}) async {

    // check if has error sending package
    bool isOldSendPackError(int? currentSeq) {
      bool oldSendError = (seq == null && currentSeq != null);
      if (oldSendError) {
        print("BmpUpdate -> updateBmp: old pack send error, seq = $currentSeq");
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

    print("BmpUpdate -> updateBmp: start sending ${multiPacks.length} packs");

    for (int index = 0; index < multiPacks.length; index++) { 
      if (isOldSendPackError(seq)) return false;
      if (seq != null && index < seq) continue;

      
      final pack = multiPacks[index];  
      // address in glasses [0x00, 0x1c, 0x00, 0x00] , taken in the first package
      Uint8List data = index == 0 ? Utils.addPrefixToUint8List([0x15, index & 0xff, 0x00, 0x1c, 0x00, 0x00],  pack) : Utils.addPrefixToUint8List([0x15, index & 0xff], pack);
      print("${DateTime.now()} updateBmp----data---*${data.length}---*$data----------");

      await BleManager.sendData(
          data,
          lr: lr);

      if (Platform.isIOS) {
        await Future.delayed(Duration(milliseconds: 8)); // 4 6 10 14  30
      } else {
        await Future.delayed(Duration(milliseconds: 5));  // 5
      }

      var offset = index * packLen;
      if (offset > image.length - packLen) {
        offset = image.length - pack.length;
      }
      _onProgressCall(lr, offset, index, image.length);
    }
    // await Future.delayed(Duration(seconds: 2)); // todo
    if (isOldSendPackError(seq)) return false;

    const maxRetryTime = 10;
    int currentRetryTime = 0;
    Future<bool> finishUpdate() async {
      print("${DateTime.now()} finishUpdate----currentRetryTime-----$currentRetryTime-----maxRetryTime-----$maxRetryTime--");
      if (currentRetryTime >= maxRetryTime) {
        return false;
      }
      
      // notice the finish sending
      var ret = await BleManager.request(
        Uint8List.fromList([0x20, 0x0d, 0x0e]),
        lr: lr,
        timeoutMs: 3000,
      );
      print("${DateTime.now()} finishUpdate---lr---$lr--ret----${ret.data}-----");
      if (ret.isTimeout) {
        currentRetryTime++;
        await Future.delayed(Duration(seconds: 1));
        return finishUpdate();
      }
      return ret.data[1].toInt() == 0xc9;
    }

    print("${DateTime.now()} updateBmp-------------over------");
    
    var isSuccess = await finishUpdate();

    print("${DateTime.now()} finishUpdate--isSuccess----*$isSuccess-");
    if (!isSuccess) {
      print("finishUpdate result error lr: $lr");
      
      return false;
    } else {
      print("finishUpdate result success lr: $lr");
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

    print("${DateTime.now()} Crc32Xz---lr---$lr---ret--------${ret.data}------crc----$crc--");

    if (ret.data.length > 4 && ret.data[5] != 0xc9) {
      print("CRC checks failed...");
      return false;
    }

    return true;
  }

  void _onProgressCall(String lr, int offset, int index, int total) {
    double progress = (offset / total) * 100;
    print("${DateTime.now()} BmpUpdate -> Progress: $lr ${progress.toStringAsFixed(2)}%, index: $index");
  }


  Uint8List prependAddress(Uint8List image) {

    List<int> addressBytes = [0x00, 0x1c, 0x00, 0x00];
    Uint8List newImage = Uint8List(addressBytes.length + image.length);
    newImage.setRange(0, addressBytes.length, addressBytes);
    newImage.setRange(addressBytes.length, newImage.length, image);
    return newImage;
  }
}