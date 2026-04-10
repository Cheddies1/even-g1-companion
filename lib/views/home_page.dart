import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/app_mode.dart';
import 'package:demo_ai_even/services/chat_history_store.dart';
import 'package:demo_ai_even/services/capture_service.dart';
import 'package:demo_ai_even/services/chat_service.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
import 'package:demo_ai_even/services/glance_service.dart';
import 'package:demo_ai_even/services/navigate_service.dart';
import 'package:demo_ai_even/views/chat_transcript_page.dart';
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
    ChatHistoryStore.get.addListener(_refreshPage);
    ChatHistoryStore.get.init();
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
            ? () => CompanionController.get.setMode(
                  mode,
                  source: 'HomePage.modeButton',
                )
            : null,
        style: FilledButton.styleFrom(
          backgroundColor:
              isSelected ? const Color(0xFF2F5B4A) : const Color(0xFF141A20),
          foregroundColor: Colors.white,
          side: BorderSide(
            color: isSelected
                ? const Color(0xFF4A8D72)
                : const Color(0xFF28313A),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: Text(enabled ? mode.label : '${mode.label}\nSoon'),
      ),
    );
  }

  Widget _buildSectionCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFF10161C),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF1D262E)),
      ),
      child: child,
    );
  }

  Widget _buildStatusCard() {
    final capture = CaptureService.get;
    final chat = ChatService.get;
    final controller = CompanionController.get;
    final navigate = NavigateService.get;
    final theme = Theme.of(context);
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Even Companion',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildMetric('Connection', _uiConnectionState()),
                    const SizedBox(height: 10),
                    _buildMetric(
                      'Device',
                      BleManager.get().getConnectionStatus(),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildMetric('Mode', controller.activeMode.label),
                    const SizedBox(height: 10),
                    _buildMetric('Status', controller.statusMessage),
                    const SizedBox(height: 10),
                    _buildMetric(
                      'Notifications',
                      '${GlanceService.get.notificationCount}',
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (navigate.hasInstruction ||
              capture.isRecording ||
              capture.lastSavedFileName != null ||
              (controller.activeMode == AppMode.chat && chat.isListening) ||
              (controller.activeMode == AppMode.chat && chat.isThinking))
            const SizedBox(height: 14),
          if (navigate.hasInstruction)
            Text(
              'Navigate: ${navigate.latestInstruction?.message ?? ''}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF9AB7C8),
              ),
            ),
          if (capture.isRecording)
            const Text(
              'Capture: Recording from glasses mic',
              style: TextStyle(color: Color(0xFFE37D7D)),
            )
          else if (capture.lastSavedFileName != null)
            Text(
              'Last saved: ${capture.lastSavedFileName}',
              style: theme.textTheme.bodyMedium,
            ),
          if (controller.activeMode == AppMode.chat && chat.isListening)
            const Text(
              'Chat: Listening from glasses mic',
              style: TextStyle(color: Color(0xFFE37D7D)),
            ),
          if (controller.activeMode == AppMode.chat && chat.isThinking)
            Text(
              'Chat: Waiting for assistant',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF9AB7C8),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPermissionCard() {
    final controller = CompanionController.get;
    final compact = controller.notificationAccessEnabled;
    return _buildSectionCard(
      padding: EdgeInsets.all(compact ? 14 : 16),
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
          const SizedBox(height: 10),
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
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Glasses',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
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

  Widget _buildMetric(String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: const Color(0xFF7C8C99),
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildChatLogSection() {
    final sessions = ChatHistoryStore.get.recentSessions;
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Chat Log',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (sessions.isEmpty)
            Text(
              'No saved chats yet.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF9AB7C8),
                  ),
            )
          else
            ...sessions.map(
              (session) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            ChatTranscriptPage(session: session),
                      ),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141A20),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF28313A)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.displayTitle,
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        if (session.previewText != null &&
                            session.previewText!.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            session.previewText!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFF9AB7C8),
                                    ),
                          ),
                        ],
                      ],
                    ),
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
          _buildSectionCard(
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
          _buildChatLogSection(),
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
    ChatHistoryStore.get.removeListener(_refreshPage);
    super.dispose();
  }
}
