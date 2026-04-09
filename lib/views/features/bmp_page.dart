// ignore_for_file: library_private_types_in_public_api

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/features_services.dart';
import 'package:flutter/material.dart';

class BmpPage extends StatefulWidget {
  const BmpPage({super.key});

  @override
  _BmpState createState() => _BmpState();
}

class _BmpState extends State<BmpPage> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('BMP'),
        ),
        body: Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 44),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () async {
                  if (BleManager.get().isConnected == false) return;
                  print("${DateTime.now()} to show bmp1-----------");
                  FeaturesServices().sendBmp("assets/images/image_1.bmp");
                },
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: const Text("BMP 1", style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () async {
                  if (BleManager.get().isConnected == false) return;
                  print("${DateTime.now()} to show bmp2-----------");
                  FeaturesServices().sendBmp("assets/images/image_2.bmp");
                },
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: const Text("BMP 2", style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () async {
                  if (BleManager.get().isConnected == false) return;
                  FeaturesServices().exitBmp(); // todo
                },
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: const Text("Exit", style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      );
}
