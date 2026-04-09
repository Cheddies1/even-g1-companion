// ignore_for_file: library_private_types_in_public_api

import 'package:demo_ai_even/views/features/bmp_page.dart';
import 'package:demo_ai_even/views/features/notification/notification_page.dart';
import 'package:demo_ai_even/views/features/text_page.dart';
import 'package:flutter/material.dart';

class FeaturesPage extends StatefulWidget {
  const FeaturesPage({super.key});

  @override
  _FeaturesPageState createState() => _FeaturesPageState();
}

class _FeaturesPageState extends State<FeaturesPage> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Features'),
        ),
        body: Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 44),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () async {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const BmpPage()),
                  );
                },
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: const Text("BMP", style: TextStyle(fontSize: 16)),
                ),
              ),
              GestureDetector(
                onTap: () async {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const NotificationPage()),
                  );
                },
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(top: 16),
                  child: const Text(
                    "Notification",
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () async {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const TextPage()),
                  );
                },
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(top: 16),
                  child: const Text(
                    "Text",
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
