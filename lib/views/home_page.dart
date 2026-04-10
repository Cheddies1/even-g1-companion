import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/app_mode.dart';
import 'package:demo_ai_even/services/capture_service.dart';
import 'package:demo_ai_even/services/chat_service.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
import 'package:demo_ai_even/services/glance_service.dart';
import 'package:demo_ai_even/services/navigate_service.dart';
import 'package:demo_ai_even/views/features_page.dart';
import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  Timer? scanTimer;
  bool isScanning = false;

  String _uiConnectionState() {
    if (BleManager.get().isConnected) {
      return 'Connected';
    }
    if (BleManager.get().getConnectionStatus() == 'Connecting...') {
      return 'Connecting';
    }
    if (isScanning) {
      return 'Scanning';
    }
    return 'Disconnected';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CompanionController.get.addListener(_refreshPage);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      CompanionController.get.refreshCompanionState();
    }
  }

  void _refreshPage() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startScan() async {
    setState(() => isScanning = true);
    await BleManager.get().startScan();
    scanTimer?.cancel();
    scanTimer = Timer(const Duration(seconds: 15), () {
      _stopScan();
    });
  }

  Future<void> _stopScan() async {
    if (!isScanning) {
      return;
    }
    await BleManager.get().stopScan();
    setState(() => isScanning = false);
  }

  Widget _buildModeButton(AppMode mode, {bool enabled = true}) {
    final isSelected = CompanionController.get.activeMode == mode;
    return Expanded(
      child: FilledButton(
        onPressed: enabled
            ? () => CompanionController.get.setMode(mode)
            : null,
        style: FilledButton.styleFrom(
          backgroundColor: isSelected ? const Color(0xFF2F5B4A) : Colors.white,
          foregroundColor: isSelected ? Colors.white : Colors.black,
          side: const BorderSide(color: Color(0xFF2F5B4A)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Text(enabled ? mode.label : '${mode.label}\nSoon'),
      ),
    );
  }

  Widget _buildStatusCard() {
    final capture = CaptureService.get;
    final chat = ChatService.get;
    final controller = CompanionController.get;
    final navigate = NavigateService.get;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Even Companion',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text('Connection: ${_uiConnectionState()}'),
          Text(BleManager.get().getConnectionStatus()),
          const SizedBox(height: 8),
          Text('Mode: ${controller.activeMode.label}'),
          Text('Status: ${controller.statusMessage}'),
          Text('Recent notifications: ${GlanceService.get.notificationCount}'),
          if (navigate.hasInstruction)
            Text('Navigate: ${navigate.latestInstruction?.message ?? ''}'),
          if (capture.isRecording)
            Text(
              'Capture: Recording from glasses mic',
              style: const TextStyle(color: Color(0xFF9B111E)),
            )
          else if (capture.lastSavedFileName != null)
            Text('Last saved: ${capture.lastSavedFileName}'),
          if (controller.activeMode == AppMode.chat && chat.isListening)
            const Text(
              'Chat: Listening from glasses mic',
              style: TextStyle(color: Color(0xFF9B111E)),
            ),
          if (controller.activeMode == AppMode.chat && chat.isThinking)
            const Text('Chat: Waiting for assistant'),
        ],
      ),
    );
  }

  Widget _buildPermissionCard() {
    final controller = CompanionController.get;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Permissions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            controller.notificationAccessEnabled
                ? 'Notification access enabled'
                : 'Notification access required for Glance and Navigate',
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: controller.openNotificationAccessSettings,
            child: Text(
              controller.notificationAccessEnabled
                  ? 'Open Notification Access'
                  : 'Enable Notification Access',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanSection() {
    final paired = BleManager.get().getPairedGlasses();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton(
            onPressed: BleManager.get().isConnected || isScanning ? null : _startScan,
            child: Text(isScanning ? 'Scanning...' : 'Scan / Reconnect'),
          ),
          const SizedBox(height: 12),
          if (paired.isEmpty)
            const Text('No paired glasses discovered yet.')
          else
            ...paired.map(
              (glasses) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  onPressed: () async {
                    final channelNumber = glasses['channelNumber']!;
                    await BleManager.get().connectToGlasses('Pair_$channelNumber');
                    _refreshPage();
                  },
                  child: Text(
                    'Pair ${glasses['channelNumber']}  ${glasses['leftDeviceName']} / ${glasses['rightDeviceName']}',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLegacySection() {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Legacy / Debug'),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const FeaturesPage()),
              );
            },
            child: const Text('Open legacy demo pages'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Even Companion'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatusCard(),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Modes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _buildModeButton(AppMode.glance),
                    const SizedBox(width: 8),
                    _buildModeButton(AppMode.capture),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildModeButton(AppMode.navigate),
                    const SizedBox(width: 8),
                    _buildModeButton(AppMode.chat),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildPermissionCard(),
          const SizedBox(height: 16),
          _buildScanSection(),
          const SizedBox(height: 16),
          _buildLegacySection(),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanTimer?.cancel();
    CompanionController.get.removeListener(_refreshPage);
    super.dispose();
  }
}
