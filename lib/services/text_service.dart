import 'dart:async';
import 'dart:math';
import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/proto.dart';

class TextService {
  static TextService? _instance;
  static TextService get get => _instance ??= TextService._();
  static bool isRunning = false;
  static int maxRetry = 5;
  static int _currentLine = 0;
  static Timer? _timer;
  static List<String> list = [];
  static List<String> sendReplys = [];

  TextService._(); 

  Future startSendText(String text) async {
    isRunning = true;

    _currentLine = 0;
    list = EvenAIDataMethod.measureStringList(text);
   
    if (list.length < 4) {
      String startScreenWords =
          list.sublist(0, min(3, list.length)).map((str) => '$str\n').join();
      String headString = '\n\n';
      startScreenWords = headString + startScreenWords;

      await doSendText(startScreenWords, 0x01, 0x70, 0);
      return;
    }

    if (list.length == 4) {
      String startScreenWords =
          list.sublist(0, 4).map((str) => '$str\n').join();
      String headString = '\n';
      startScreenWords = headString + startScreenWords;
      await doSendText(startScreenWords, 0x01, 0x70, 0);
      return;
    }

    if (list.length == 5) {
      String startScreenWords =
          list.sublist(0, 5).map((str) => '$str\n').join();
      await doSendText(startScreenWords, 0x01, 0x70, 0);
      return;
    }

    String startScreenWords = list.sublist(0, 5).map((str) => '$str\n').join();
    bool isSuccess = await doSendText(startScreenWords, 0x01, 0x70, 0);
    if (isSuccess) {
      _currentLine = 0;
      await updateReplyToOSByTimer();
    } else {
      clear(); 
    }
  }

  int retryCount = 0;
  Future<bool> doSendText(String text, int type, int status, int pos) async {
   
    print('${DateTime.now()} doSendText--currentPage---${getCurrentPage()}-----text----$text-----type---$type---status---$status----pos---$pos-');
    if (!isRunning) {
      return false;
    }

    bool isSuccess = await Proto.sendEvenAIData(text,
        newScreen: EvenAIDataMethod.transferToNewScreen(type, status),
        pos: pos,
        current_page_num: getCurrentPage(),
        max_page_num: getTotalPages()); // todo pos
    if (!isSuccess) {
      if (retryCount < maxRetry) {
        retryCount++;
        await doSendText(text, type, status, pos);
      } else {
        retryCount = 0;
        return false;
      }
    }
    retryCount = 0;
    return true;
  }

  Future updateReplyToOSByTimer() async {
    if (!isRunning) return;
    int interval = 8; // The paging interval can be customized
   
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: interval), (timer) async {

      _currentLine = min(_currentLine + 5, list.length - 1);
      sendReplys = list.sublist(_currentLine);

      if (_currentLine > list.length - 1) {
        _timer?.cancel();
        _timer = null;

        clear();
      } else {
        if (sendReplys.length < 4) {
          var mergedStr = sendReplys
              .sublist(0, sendReplys.length)
              .map((str) => '$str\n')
              .join();

          if (_currentLine >= list.length - 5) {
            await doSendText(mergedStr, 0x01, 0x70, 0);
            _timer?.cancel();
            _timer = null;
          } else {
            await doSendText(mergedStr, 0x01, 0x70, 0);
          }
        } else {
          var mergedStr = sendReplys
              .sublist(0, min(5, sendReplys.length))
              .map((str) => '$str\n')
              .join();

          if (_currentLine >= list.length - 5) {
            await doSendText(mergedStr, 0x01, 0x70, 0);
            _timer?.cancel();
            _timer = null;
          } else {
            await doSendText(mergedStr, 0x01, 0x70, 0);
          }
        }
      }
    });
  }

  int getTotalPages() {
    if (list.isEmpty) {
      return 0;
    }
    if (list.length < 6) {
      return 1;
    }
    int pages = 0;
    int div = list.length ~/ 5;
    int rest = list.length % 5;
    pages = div;
    if (rest != 0) {
      pages++;
    }
    return pages;
  }

  int getCurrentPage() {
    if (_currentLine == 0) {
      return 1;
    }
    int currentPage = 1;
    int div = _currentLine ~/ 5;
    int rest = _currentLine % 5;
    currentPage = 1 + div;
    if (rest != 0) {
      currentPage++;
    }
    return currentPage;
  }

  Future stopTextSendingByOS() async {
    print("stopTextSendingByOS---------------");
    isRunning = false;
    clear();
  }

  void clear() {
    isRunning = false;
    _currentLine = 0;
    _timer?.cancel();
    _timer = null;
    list = [];
    sendReplys = [];
    retryCount = 0;
  }
}