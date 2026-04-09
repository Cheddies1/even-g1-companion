

import 'package:demo_ai_even/services/evenai.dart';

class App {
  static App? _instance;
  static App get get => _instance ??= App._();

  App._();

  // exit features by receiving [oxf5 0]
  void exitAll({bool isNeedBackHome = true}) async {
    if (EvenAI.isEvenAIOpen.value) {
      await EvenAI.get.stopEvenAIByOS();
    }
  }
}