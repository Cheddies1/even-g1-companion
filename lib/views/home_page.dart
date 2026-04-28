import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/app_mode.dart';
import 'package:demo_ai_even/services/chat_history_store.dart';
import 'package:demo_ai_even/services/capture_service.dart';
import 'package:demo_ai_even/services/chat_service.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
import 'package:demo_ai_even/services/device_status_service.dart';
import 'package:demo_ai_even/services/glance_service.dart';
import 'package:demo_ai_even/views/chat_transcript_page.dart';
import 'package:demo_ai_even/views/features_page.dart';
import 'package:demo_ai_even/views/settings_page.dart';
import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  Timer? scanTimer;
  bool isScanning = false;
  double _brightnessSliderValue = 21;
  bool _autoBrightness = false;

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

  bool get _isHealthyConnected {
    final ble = BleManager.get();
    return ble.legState('L').isHealthy && ble.legState('R').isHealthy;
  }

  bool get _showCompactConnection => _isHealthyConnected && !isScanning;

  String _healthSummary() {
    final ble = BleManager.get();
    final left = ble.legState('L');
    final right = ble.legState('R');
    if (left.isHealthy && right.isHealthy) {
      return 'Healthy';
    }
    if (!left.connected && !right.connected) {
      return 'Disconnected';
    }
    if (left.connected || right.connected) {
      return 'Degraded';
    }
    return 'Connecting';
  }

  String _legSummary(String lr) {
    final state = BleManager.get().legState(lr);
    final name = state.deviceName.isEmpty ? lr : state.deviceName;
    final status = switch (state.status) {
      LegHealthStatus.disconnected => 'disconnected',
      LegHealthStatus.degraded => 'degraded',
      LegHealthStatus.healthy => 'healthy',
    };
    return '$name • $status';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CompanionController.get.addListener(_refreshPage);
    DeviceStatusService.get.addListener(_refreshPage);
    ChatHistoryStore.get.addListener(_refreshPage);
    ChatHistoryStore.get.init();
    final ds = DeviceStatusService.get;
    _brightnessSliderValue = (ds.brightnessLevel ?? 21).toDouble();
    _autoBrightness = ds.autoBrightness;
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

  Future<void> _forceReconnect() async {
    setState(() => isScanning = false);
    await BleManager.get().forceReconnect();
    _refreshPage();
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
            color:
                isSelected ? const Color(0xFF4A8D72) : const Color(0xFF28313A),
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

  Widget _buildStatusPills() {
    final controller = CompanionController.get;
    final capture = CaptureService.get;
    final chat = ChatService.get;
    final deviceStatus = DeviceStatusService.get;
    final glassesBattery = deviceStatus.glassesBatteryLabel;
    final caseBattery = deviceStatus.caseBatteryLabel;
    final pills = <String>[
      'Mode: ${controller.activeMode.label}',
      'Health: ${_healthSummary()}',
      if (glassesBattery != null) 'Glasses: $glassesBattery',
      if (caseBattery != null) 'Case: $caseBattery',
      'State: ${deviceStatus.wearState.displayLabel}',
      'Notifications: ${GlanceService.get.notificationCount}',
    ];
    if (capture.lastSavedFileName != null) {
      pills.add('Last saved: ${capture.lastSavedFileName}');
    }
    if (capture.isRecording) {
      pills.add('Capture recording');
    }
    if (controller.activeMode == AppMode.chat && chat.isListening) {
      pills.add('Chat listening');
    }
    if (controller.activeMode == AppMode.chat && chat.isThinking) {
      pills.add('Chat thinking');
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: pills
          .map(
            (label) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF141A20),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFF28313A)),
              ),
              child: Text(label),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildConnectionCard() {
    final capture = CaptureService.get;
    final chat = ChatService.get;
    final controller = CompanionController.get;
    final paired = BleManager.get().getPairedGlasses();
    final theme = Theme.of(context);

    final showDetailText = !_showCompactConnection ||
        capture.isRecording ||
        capture.lastSavedFileName != null ||
        (controller.activeMode == AppMode.chat && chat.isListening) ||
        (controller.activeMode == AppMode.chat && chat.isThinking);

    return _buildSectionCard(
      padding: EdgeInsets.all(_showCompactConnection ? 14 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Even Companion',
                      style: (_showCompactConnection
                              ? theme.textTheme.titleMedium
                              : theme.textTheme.titleLarge)
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _showCompactConnection
                          ? '${_uiConnectionState()} • ${_healthSummary()}'
                          : _uiConnectionState(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _showCompactConnection
                            ? const Color(0xFF9AB7C8)
                            : const Color(0xFFE7EEF4),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SettingsPage(),
                    ),
                  );
                },
                icon: const Icon(Icons.settings),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_showCompactConnection) ...[
            _buildStatusPills(),
            const SizedBox(height: 12),
            Text(
              '${_legSummary('L')}\n${_legSummary('R')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF9AB7C8),
              ),
            ),
            if (showDetailText) ...[
              const SizedBox(height: 10),
              Text(
                controller.statusMessage,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ] else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMetric('Left', _legSummary('L')),
                      const SizedBox(height: 10),
                      _buildMetric('Right', _legSummary('R')),
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
                      _buildMetric('Health', _healthSummary()),
                      const SizedBox(height: 10),
                      _buildMetric('Status', controller.statusMessage),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildStatusPills(),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton(
                onPressed: isScanning || BleManager.get().isConnected
                    ? null
                    : _startScan,
                child: Text(isScanning ? 'Scanning...' : 'Scan / Reconnect'),
              ),
              FilledButton.tonal(
                onPressed: _forceReconnect,
                child: const Text('Force Reconnect'),
              ),
              if (isScanning)
                TextButton(
                  onPressed: _stopScan,
                  child: const Text('Stop Scan'),
                ),
            ],
          ),
          if (!_showCompactConnection) ...[
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
                      await BleManager.get()
                          .connectToGlasses('Pair_$channelNumber');
                      _refreshPage();
                    },
                    child: Text(
                      'Pair ${glasses['channelNumber']}  ${glasses['leftDeviceName']} / ${glasses['rightDeviceName']}',
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
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
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
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

  Widget _buildDisplaySection() {
    final theme = Theme.of(context);
    final ds = DeviceStatusService.get;
    final confirmed = ds.brightnessLevel;
    final confirmedLabel = confirmed == null ? '—' : '$confirmed';
    const maxLevel = DeviceStatusService.brightnessLevelMax;
    final sliderValue =
        _brightnessSliderValue.clamp(0.0, maxLevel.toDouble());
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Display',
                style: theme.textTheme.titleMedium,
              ),
              const Spacer(),
              Text(
                'Confirmed: $confirmedLabel',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF9AB7C8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 4),
              const Icon(Icons.brightness_low, size: 18, color: Color(0xFF9AB7C8)),
              Expanded(
                child: Slider(
                  value: sliderValue,
                  min: 0,
                  max: maxLevel.toDouble(),
                  divisions: maxLevel,
                  label: sliderValue.round().toString(),
                  onChanged: (v) {
                    setState(() => _brightnessSliderValue = v);
                  },
                  onChangeEnd: (v) {
                    DeviceStatusService.get.setBrightness(
                      level: v.round(),
                      auto: _autoBrightness,
                    );
                  },
                ),
              ),
              const Icon(Icons.brightness_high, size: 18, color: Color(0xFF9AB7C8)),
              const SizedBox(width: 6),
              SizedBox(
                width: 28,
                child: Text(
                  sliderValue.round().toString(),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Auto brightness'),
            value: _autoBrightness,
            onChanged: (next) {
              setState(() => _autoBrightness = next);
              DeviceStatusService.get.setBrightness(
                level: _brightnessSliderValue.round(),
                auto: next,
              );
            },
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
          _buildConnectionCard(),
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
          if (BleManager.get().isConnected) ...[
            const SizedBox(height: 16),
            _buildDisplaySection(),
          ],
          const SizedBox(height: 16),
          _buildChatLogSection(),
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
    DeviceStatusService.get.removeListener(_refreshPage);
    ChatHistoryStore.get.removeListener(_refreshPage);
    super.dispose();
  }
}
