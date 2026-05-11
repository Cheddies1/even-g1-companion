import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/controllers/evenai_model_controller.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/chat_history_store.dart';
import 'package:even_companion/services/companion_controller.dart';
import 'package:even_companion/services/notes_store.dart';
import 'package:even_companion/views/home_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BleManager.get();
  Get.put(EvenaiModelController());
  AppLog.info('${DateTime.now()} runApp', tag: 'AppStartup');
  runApp(const EvenCompanionApp());
  Future<void>(() async {
    AppLog.info('${DateTime.now()} companion init begin', tag: 'AppStartup');
    await AppSettingsStore.get.init();
    await ChatHistoryStore.get.init();
    await NotesStore.get.init();
    await CompanionController.get.init();
    AppLog.info('${DateTime.now()} companion init end', tag: 'AppStartup');
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
          primary: Color(0xFF1F5E54),
          onPrimary: Colors.white,
          secondary: Color(0xFF1F5E54),
          onSecondary: Colors.white,
          secondaryContainer: Color(0xFF1F5E54),
          onSecondaryContainer: Colors.white,
          surface: Color(0xFF10161C),
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
