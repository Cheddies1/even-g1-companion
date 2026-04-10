import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/controllers/evenai_model_controller.dart';
import 'package:demo_ai_even/services/chat_history_store.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
import 'package:demo_ai_even/views/home_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BleManager.get();
  Get.put(EvenaiModelController());
  print('${DateTime.now()} App startup: runApp');
  runApp(const EvenCompanionApp());
  Future<void>(() async {
    print('${DateTime.now()} App startup: companion init begin');
    await ChatHistoryStore.get.init();
    await CompanionController.get.init();
    print('${DateTime.now()} App startup: companion init end');
  });
}

class EvenCompanionApp extends StatelessWidget {
  const EvenCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Even Companion',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4A8D72),
          secondary: Color(0xFF7FD6A8),
          surface: Color(0xFF10161C),
          onPrimary: Colors.white,
          onSecondary: Colors.black,
          onSurface: Color(0xFFE7EEF4),
        ),
        scaffoldBackgroundColor: const Color(0xFF090D10),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF090D10),
          foregroundColor: Color(0xFFE7EEF4),
          elevation: 0,
        ),
        cardColor: const Color(0xFF10161C),
        dividerColor: const Color(0xFF1D262E),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: Color(0xFFE7EEF4)),
          titleMedium: TextStyle(color: Color(0xFFE7EEF4)),
          bodyLarge: TextStyle(color: Color(0xFFE7EEF4)),
          bodyMedium: TextStyle(color: Color(0xFFD4DDE5)),
          labelLarge: TextStyle(color: Color(0xFFE7EEF4)),
          labelMedium: TextStyle(color: Color(0xFFA7B5C2)),
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
