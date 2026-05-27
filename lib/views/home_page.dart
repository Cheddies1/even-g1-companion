import 'dart:async';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/app_mode.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/models/chat_session_record.dart';
import 'package:even_companion/services/chat_history_store.dart';
import 'package:even_companion/services/capture_service.dart';
import 'package:even_companion/services/chat_service.dart';
import 'package:even_companion/services/companion_controller.dart';
import 'package:even_companion/services/device_status_service.dart';
import 'package:even_companion/services/glance_service.dart';
import 'package:even_companion/services/notes_store.dart';
import 'package:even_companion/views/chat_transcript_page.dart';
import 'package:even_companion/views/features_page.dart';
import 'package:even_companion/views/notes_page.dart';
import 'package:even_companion/views/recordings_page.dart';
import 'package:even_companion/views/settings_page.dart';
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
    if (BleManager.get().getConnectionStatus() == 'Reconnecting...') {
      return 'Reconnecting';
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
    NotesStore.get.addListener(_refreshPage);
    ChatHistoryStore.get.init();
    _initBrightnessFromStore();
  }

  /// Reads the persisted brightness state from [AppSettingsStore], falling
  /// back to the firmware echo then the default when neither is available.
  ///
  /// Called asynchronously because [AppSettingsStore.init] may not yet have
  /// completed when the page first builds (the app launches `runApp` before
  /// awaiting the store init in `main.dart`).
  Future<void> _initBrightnessFromStore() async {
    final store = AppSettingsStore.get;
    await store.init();
    if (!mounted) {
      return;
    }
    final persistedLevel = store.brightnessLevel;
    final firmwareLevel = DeviceStatusService.get.brightnessLevel;
    setState(() {
      _brightnessSliderValue =
          (persistedLevel ?? firmwareLevel ?? 21).toDouble();
      _autoBrightness = store.autoBrightness;
    });
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
              isSelected ? const Color(0xFF1F5E54) : const Color(0xFF141A20),
          foregroundColor: Colors.white,
          side: BorderSide(
            color:
                isSelected ? const Color(0xFF2E8A7A) : const Color(0xFF28313A),
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
    // When there are exactly 4 pills they would flow 3+1 on a typical phone
    // width, leaving one orphaned chip on a row by itself. Force 2x2 for that
    // case only; all other counts flow naturally via Wrap.
    final forceTwoColumns = pills.length == 4;
    Widget buildChip(String label) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF141A20),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFF28313A)),
          ),
          child: Text(label),
        );

    if (forceTwoColumns) {
      return LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 8.0;
          final chipWidth = (constraints.maxWidth - spacing) / 2;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: pills
                .map(
                  (label) => SizedBox(width: chipWidth, child: buildChip(label)),
                )
                .toList(growable: false),
          );
        },
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: pills.map(buildChip).toList(growable: false),
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
            ],
          ),
          if (!_showCompactConnection) ...[
            const SizedBox(height: 12),
            if (paired.isEmpty)
              Text(
                'No paired glasses discovered yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF9AB7C8),
                ),
              )
            else
              ...paired.map(
                (glasses) => InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () async {
                    final channelNumber = glasses['channelNumber']!;
                    await BleManager.get()
                        .connectToGlasses('Pair_$channelNumber');
                    _refreshPage();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${glasses['leftDeviceName']} / ${glasses['rightDeviceName']}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF9AB7C8),
                            ),
                          ),
                        ),
                        Text(
                          'Pair ${glasses['channelNumber']}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
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
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                session.displayTitle,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildSessionKindBadge(session.kind),
                          ],
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

  Widget _buildSessionKindBadge(ChatSessionKind kind) {
    final isQuickAsk = kind == ChatSessionKind.quickAsk;
    final color =
        isQuickAsk ? const Color(0xFF6FC4B4) : const Color(0xFF9AB7C8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        kind.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
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

  Widget _buildNotesCard() {
    final allNotes = NotesStore.get.notes;
    final shopping = allNotes
        .where((n) => n.category == 'shopping' && n.status != 'done')
        .length;
    final todo = allNotes
        .where((n) => n.category == 'todo' && n.status != 'done')
        .length;
    final notes = allNotes
        .where((n) => n.category == 'notes' && n.status != 'done')
        .length;

    final parts = <String>[
      if (shopping > 0) '$shopping shopping',
      if (todo > 0) '$todo to do',
      if (notes > 0) '$notes notes',
    ];
    final subtitle = parts.isEmpty ? 'No active notes' : parts.join(', ');

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const NotesPage()),
        );
      },
      child: _buildSectionCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notes',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF9AB7C8),
                        ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: Color(0xFF7C8C99),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingsCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const RecordingsPage()),
        );
      },
      child: _buildSectionCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recordings',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Captured audio from glasses mic',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF9AB7C8),
                        ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: Color(0xFF7C8C99),
            ),
          ],
        ),
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
        actions: [
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
          _buildNotesCard(),
          const SizedBox(height: 16),
          _buildRecordingsCard(),
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
    NotesStore.get.removeListener(_refreshPage);
    super.dispose();
  }
}
