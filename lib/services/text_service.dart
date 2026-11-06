import 'dart:async';
import 'dart:math';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/evenai.dart';
import 'package:even_companion/services/g1_text_layout.dart';
import 'package:even_companion/services/proto.dart';

class TextService {
  static TextService? _instance;
  static TextService get get => _instance ??= TextService._();
  static bool isRunning = false;
  static int maxRetry = 5;
  static int _currentLine = 0;
  static Timer? _timer;
  static List<String> list = [];
  static List<String> sendReplys = [];
  static String? _lastSentText;
  static bool _tapLayout = false;
  static const Duration _tapOpenSettle = Duration(milliseconds: 1000);

  TextService._(); 

  /// Render [text] as a 0x4E page.
  ///
  /// With [tapSurface], or whenever a tap-enabled surface is already on the
  /// lenses, the page goes out on the Even AI layout so single taps reach the
  /// phone: open with 0x30 then pin with 0x50, or a plain 0x50 update if the
  /// surface is already pinned. Otherwise it is the usual full-width 0x70.
  /// See [Proto.isTapSurfaceOpen].
  Future startSendText(String text, {bool tapSurface = false}) async {
    isRunning = true;
    _lastSentText = text;
    _tapLayout = tapSurface || Proto.isTapSurfaceOpen;

    _currentLine = 0;
    list = EvenAIDataMethod.measureStringList(
      text,
      _tapLayout ? G1TextLayout.evenAiLayoutWidth.toDouble() : null,
    );
   
    if (list.length < 4) {
      String startScreenWords =
          list.sublist(0, min(3, list.length)).map((str) => '$str\n').join();
      String headString = '\n\n';
      startScreenWords = headString + startScreenWords;

      await _sendFirstScreen(startScreenWords);
      return;
    }

    if (list.length == 4) {
      String startScreenWords =
          list.sublist(0, 4).map((str) => '$str\n').join();
      String headString = '\n';
      startScreenWords = headString + startScreenWords;
      await _sendFirstScreen(startScreenWords);
      return;
    }

    if (list.length == 5) {
      String startScreenWords =
          list.sublist(0, 5).map((str) => '$str\n').join();
      await _sendFirstScreen(startScreenWords);
      return;
    }

    String startScreenWords = list.sublist(0, 5).map((str) => '$str\n').join();
    bool isSuccess = await _sendFirstScreen(startScreenWords);
    if (isSuccess) {
      _currentLine = 0;
      await updateReplyToOSByTimer();
    } else {
      clear(); 
    }
  }

  Future<bool> _sendFirstScreen(String words) async {
    if (!_tapLayout) {
      return doSendText(words, 0x01, 0x70, 0);
    }
    if (!Proto.isTapSurfaceOpen) {
      final opened = await doSendText(words, 0x01, 0x30, 0);
      if (!opened) {
        return false;
      }
      // The left (slave) lens acks 0x4E on receipt, before it has drawn the
      // Even AI entry screen. A pin sent ~300 ms after the open was lost on
      // the left lens on device (stuck on "Even AI Listening"), while ~1 s
      // apart worked on both. Let the entry transition finish first.
      await Future<void>.delayed(_tapOpenSettle);
      if (!isRunning) {
        return false;
      }
    }
    return doSendText(words, 0x01, 0x50, 0);
  }

  /// Status for timer-driven follow-on pages of the current text.
  int get _pageStatus => _tapLayout ? 0x50 : 0x70;

  int retryCount = 0;
  Future<bool> doSendText(String text, int type, int status, int pos) async {
   
    AppLog.debug('${DateTime.now()} doSendText--currentPage---${getCurrentPage()}-----text----$text-----type---$type---status---$status----pos---$pos-');
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
            await doSendText(mergedStr, 0x01, _pageStatus, 0);
            _timer?.cancel();
            _timer = null;
          } else {
            await doSendText(mergedStr, 0x01, _pageStatus, 0);
          }
        } else {
          var mergedStr = sendReplys
              .sublist(0, min(5, sendReplys.length))
              .map((str) => '$str\n')
              .join();

          if (_currentLine >= list.length - 5) {
            await doSendText(mergedStr, 0x01, _pageStatus, 0);
            _timer?.cancel();
            _timer = null;
          } else {
            await doSendText(mergedStr, 0x01, _pageStatus, 0);
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
    AppLog.debug('stopTextSendingByOS', tag: 'Text');
    isRunning = false;
    clear();
  }

  Future<bool> resendLastText() async {
    final text = _lastSentText;
    if (text == null || text.isEmpty || !isRunning) {
      return false;
    }
    await startSendText(text);
    return true;
  }

  void clear() {
    isRunning = false;
    _currentLine = 0;
    _timer?.cancel();
    _timer = null;
    list = [];
    sendReplys = [];
    retryCount = 0;
    _lastSentText = null;
  }
}
