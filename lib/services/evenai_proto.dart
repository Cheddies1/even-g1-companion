import 'dart:typed_data';
import 'package:demo_ai_even/utils/utils.dart';

class EvenaiProto {
  static List<Uint8List> evenaiMultiPackListV2(
    int cmd, {
    int len = 191,
    required Uint8List data,
    required int syncSeq,
    required int newScreen,
    required int pos,
    required int current_page_num,
    required int max_page_num,
  }) {
    
    List<Uint8List> send = [];
    int maxSeq = data.length ~/ len;
    if (data.length % len > 0) {
      maxSeq++;
    }
    for (var seq = 0; seq < maxSeq; seq++) {
      var start = seq * len;
      var end = start + len;
      if (end > data.length) {
        end = data.length;
      }
      var itemData = data.sublist(start, end);
      ByteData byteData = ByteData(2);
      // Use the setInt16 method to write an int value. The second parameter is true to indicate little endian.
      byteData.setInt16(0, pos, Endian.big);
      var pack = Utils.addPrefixToUint8List([
        cmd,
        syncSeq,
        maxSeq,
        seq,
        newScreen,
        ...byteData.buffer.asUint8List(),
        current_page_num,
        max_page_num
      ], itemData);
      send.add(pack);
    }
    return send;
  }
}