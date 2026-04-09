import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/controllers/evenai_model_controller.dart';
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F5B4A)),
        scaffoldBackgroundColor: const Color(0xFFF4F3EE),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
