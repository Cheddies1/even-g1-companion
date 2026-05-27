import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/models/notification_package_preference.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/assistant_backend_config.dart';
import 'package:even_companion/services/chat_backend_router.dart';
import 'package:even_companion/services/companion_controller.dart';
import 'package:even_companion/services/device_status_service.dart';
import 'package:even_companion/services/notification_settings_store.dart';
import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _chatModelController;
  late final TextEditingController _transcriptionModelController;
  late final TextEditingController _hermesApiKeyController;
  late final TextEditingController _hermesBaseUrlController;
  late final TextEditingController _hermesChatModelController;
  late final TextEditingController _hermesTimeoutController;

  bool _initialized = false;
  bool _saving = false;
  bool _obscureApiKey = true;
  bool _savingHermes = false;
  bool _obscureHermesKey = true;
  bool _testingHermes = false;
  // null = not yet tested this session; true/false = last probe result.
  bool? _hermesReachable;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController();
    _baseUrlController = TextEditingController();
    _chatModelController = TextEditingController();
    _transcriptionModelController = TextEditingController();
    _hermesApiKeyController = TextEditingController();
    _hermesBaseUrlController = TextEditingController();
    _hermesChatModelController = TextEditingController();
    _hermesTimeoutController = TextEditingController();
    AppSettingsStore.get.addListener(_handleStoreChanged);
    NotificationSettingsStore.get.addListener(_handleStoreChanged);
    CompanionController.get.addListener(_handleStoreChanged);
    DeviceStatusService.get.addListener(_handleStoreChanged);
    _loadInitialValues();
  }

  Future<void> _loadInitialValues() async {
    await AppSettingsStore.get.init();
    await NotificationSettingsStore.get.init();
    await CompanionController.get.refreshCompanionState();
    if (!mounted) {
      return;
    }
    _applyStoreValues();
    setState(() {
      _initialized = true;
    });
  }

  void _handleStoreChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _applyStoreValues() {
    final settings = AppSettingsStore.get;
    _apiKeyController.text = settings.apiKey;
    _baseUrlController.text = settings.baseUrl;
    _chatModelController.text = settings.chatModel;
    _transcriptionModelController.text = settings.transcriptionModel;
    _hermesApiKeyController.text = settings.hermesApiKey;
    _hermesBaseUrlController.text = settings.hermesBaseUrl;
    _hermesChatModelController.text = settings.hermesChatModel;
    _hermesTimeoutController.text =
        settings.hermesTimeoutSeconds?.toString() ?? '';
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
    });
    try {
      await AppSettingsStore.get.saveAssistantSettings(
        apiKey: _apiKeyController.text,
        baseUrl: _baseUrlController.text,
        chatModel: _chatModelController.text,
        transcriptionModel: _transcriptionModelController.text,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _saveHermes() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _savingHermes = true;
    });
    try {
      await AppSettingsStore.get.saveHermesSettings(
        apiKey: _hermesApiKeyController.text,
        baseUrl: _hermesBaseUrlController.text,
        chatModel: _hermesChatModelController.text,
        timeoutSeconds: _parseTimeout(_hermesTimeoutController.text),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hermes settings saved')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingHermes = false;
        });
      }
    }
  }

  int? _parseTimeout(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final value = int.tryParse(trimmed);
    if (value == null || value <= 0) {
      return null;
    }
    return value;
  }

  Future<void> _testHermesConnection() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _testingHermes = true;
      _hermesReachable = null;
    });
    // Probe the URL currently typed in the field, not only the saved value,
    // so the user can verify before saving. Reuses the router's probe so the
    // two can never drift.
    final reachable =
        await probeHermesHealth(_hermesBaseUrlController.text.trim());
    if (!mounted) {
      return;
    }
    setState(() {
      _testingHermes = false;
      _hermesReachable = reachable;
    });
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

  Widget _buildApiSection() {
    final config = AssistantBackendConfig.resolve();
    final hasConfiguredKey = config.isConfigured;
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'API / Assistant',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            hasConfiguredKey
                ? 'Runtime settings override any build defaults. Leave optional fields blank to keep the current fallback values.'
                : 'No API key is configured yet. Chat and the Glance assistant will keep failing cleanly until you add one here or via a build-time fallback.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF9AB7C8),
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
            obscureText: _obscureApiKey,
            decoration: InputDecoration(
              labelText: 'OpenAI API key',
              hintText: 'sk-...',
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _obscureApiKey = !_obscureApiKey;
                  });
                },
                icon: Icon(
                  _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
              labelText: 'Base URL override',
              hintText: 'https://api.openai.com/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _chatModelController,
            decoration: const InputDecoration(
              labelText: 'Chat model override',
              hintText: 'gpt-4.1-mini',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _transcriptionModelController,
            decoration: const InputDecoration(
              labelText: 'Transcription model override',
              hintText: 'gpt-4o-mini-transcribe',
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildConfigChip(
                label: config.usingRuntimeApiKey
                    ? 'API key: runtime'
                    : (config.apiKey.isNotEmpty
                        ? 'API key: build fallback'
                        : 'API key: missing'),
              ),
              _buildConfigChip(
                label: config.usingRuntimeBaseUrl
                    ? 'Base URL: runtime'
                    : 'Base URL: fallback',
              ),
              _buildConfigChip(
                label: config.usingRuntimeChatModel
                    ? 'Chat model: runtime'
                    : 'Chat model: fallback',
              ),
              _buildConfigChip(
                label: config.usingRuntimeTranscriptionModel
                    ? 'Transcription: runtime'
                    : 'Transcription: fallback',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving...' : 'Save settings'),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _saving
                    ? null
                    : () {
                        _applyStoreValues();
                        setState(() {});
                      },
                child: const Text('Reset form'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConfigChip({required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF141A20),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF28313A)),
      ),
      child: Text(label),
    );
  }

  Widget _buildHermesSection() {
    final settings = AppSettingsStore.get;
    final backend = settings.assistantBackend;
    final theme = Theme.of(context);
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reasoning Backend',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Quick Ask / Chat can route the reasoning call to a self-hosted '
            'Hermes Agent over Tailscale instead of OpenAI direct. Speech-to-'
            'text always stays on OpenAI, so keep an OpenAI key configured '
            'above.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF9AB7C8),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<AssistantBackendKind>(
            segments: const [
              ButtonSegment(
                value: AssistantBackendKind.openai,
                label: Text('OpenAI'),
                icon: Icon(Icons.cloud_outlined),
              ),
              ButtonSegment(
                value: AssistantBackendKind.hermes,
                label: Text('Hermes'),
                icon: Icon(Icons.dns_outlined),
              ),
            ],
            selected: {backend},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) {
                return;
              }
              AppSettingsStore.get.setAssistantBackend(selection.first);
            },
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Fall back to OpenAI'),
            subtitle: const Text(
              'When Hermes is unreachable, use the OpenAI direct path and show '
              'a one-time notice on the glasses.',
            ),
            value: settings.hermesFallbackEnabled,
            onChanged: (value) {
              AppSettingsStore.get.setHermesFallbackEnabled(value);
            },
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _hermesBaseUrlController,
            decoration: const InputDecoration(
              labelText: 'Hermes base URL',
              hintText: 'http://deepthought:8642/v1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hermesApiKeyController,
            obscureText: _obscureHermesKey,
            decoration: InputDecoration(
              labelText: 'Hermes API key',
              hintText: 'bearer token',
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _obscureHermesKey = !_obscureHermesKey;
                  });
                },
                icon: Icon(
                  _obscureHermesKey ? Icons.visibility : Icons.visibility_off,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hermesChatModelController,
            decoration: const InputDecoration(
              labelText: 'Hermes model',
              hintText: 'hermes-agent',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hermesTimeoutController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Hermes timeout (seconds)',
              hintText: '120',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                onPressed: _savingHermes ? null : _saveHermes,
                child: Text(_savingHermes ? 'Saving...' : 'Save Hermes'),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _testingHermes ? null : _testHermesConnection,
                child: Text(
                  _testingHermes ? 'Testing...' : 'Test connection',
                ),
              ),
              const SizedBox(width: 10),
              if (_hermesReachable != null) _buildReachabilityChip(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReachabilityChip() {
    final reachable = _hermesReachable == true;
    final color = reachable ? const Color(0xFF2E7D32) : const Color(0xFFB3261E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            reachable ? Icons.check_circle : Icons.error_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(reachable ? 'Reachable' : 'Unreachable'),
        ],
      ),
    );
  }

  // Fixed widths so the header labels sit directly above the switches in every row.
  static const double _switchColumnWidth = 56.0;
  static const double _switchColumnGap = 8.0;

  Widget _buildNotificationFiltersSection() {
    final packages = NotificationSettingsStore.get.recentPackages;
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Notification Filters',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Suppress noisy packages or mark media apps for the Now Playing line.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF9AB7C8),
                ),
          ),
          const SizedBox(height: 12),
          if (packages.isEmpty)
            Text(
              'Recently seen apps will appear here.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF9AB7C8),
                  ),
            )
          else ...[
            _buildSwitchColumnHeaders(),
            ...packages.take(20).map(_buildPackageRow),
          ],
        ],
      ),
    );
  }

  Widget _buildSwitchColumnHeaders() {
    const headerStyle = TextStyle(
      fontSize: 11,
      color: Color(0xFF7C8C99),
    );
    return const Row(
      children: [
        Spacer(),
        SizedBox(
          width: _switchColumnWidth,
          child: Text(
            'Playing',
            style: headerStyle,
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(width: _switchColumnGap),
        SizedBox(
          width: _switchColumnWidth,
          child: Text(
            'Mute',
            style: headerStyle,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildPackageRow(NotificationPackagePreference entry) {
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: const Color(0xFF7C8C99),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (entry.isBuiltInCandidate)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.tune, size: 18),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.displayName.isNotEmpty
                      ? entry.displayName
                      : entry.packageName,
                ),
                Text(entry.packageName, style: subtitleStyle),
              ],
            ),
          ),
          SizedBox(
            width: _switchColumnWidth,
            child: Switch(
              value: entry.mediaOverride == true,
              onChanged: (value) async {
                await NotificationSettingsStore.get.setPackageMedia(
                  entry.packageName,
                  value ? true : null,
                );
                await CompanionController.get.refreshCompanionState();
              },
            ),
          ),
          const SizedBox(width: _switchColumnGap),
          SizedBox(
            width: _switchColumnWidth,
            child: Switch(
              value: entry.suppressed,
              onChanged: (value) async {
                await NotificationSettingsStore.get.setPackageSuppressed(
                  entry.packageName,
                  value,
                );
                await CompanionController.get.refreshCompanionState();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFirmwareSettingsSection() {
    final connected = BleManager.get().isConnected;
    final settings = AppSettingsStore.get;
    final theme = Theme.of(context);
    return _buildSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Firmware Settings',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'These choices are stored on the glasses themselves and survive '
            'an app uninstall. The companion app does not re-send them on '
            'reconnect — pick again here if you want to push the same '
            'value back to the firmware.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF9AB7C8),
            ),
          ),
          const SizedBox(height: 16),
          _buildSettingDropdown<HeadUpMode>(
            label: 'Tilt-up behaviour',
            description:
                'What the glasses show when you tilt your head up.',
            value: settings.headUpMode == HeadUpMode.unknown
                ? null
                : settings.headUpMode,
            unsetLabel: HeadUpMode.unknown.displayLabel,
            connected: connected,
            options: const [
              HeadUpMode.companionApp,
              HeadUpMode.evenDashboard,
            ],
            optionLabel: (mode) => mode.displayLabel,
            onChanged: (mode) {
              if (mode == null) {
                return;
              }
              DeviceStatusService.get.setHeadUpMode(mode);
            },
          ),
          const SizedBox(height: 16),
          _buildSettingDropdown<DoubleTapAction>(
            label: 'Double-tap behaviour',
            description:
                'Action when you double-tap either temple. '
                '"Companion app mode switch" cycles app modes via the '
                'firmware\'s host-handled F5 20 event.',
            value: settings.doubleTapAction == DoubleTapAction.unknown
                ? null
                : settings.doubleTapAction,
            unsetLabel: DoubleTapAction.unknown.displayLabel,
            connected: connected,
            options: const [
              DoubleTapAction.companionAppModeSwitch,
              DoubleTapAction.evenDashboard,
              DoubleTapAction.doNothing,
            ],
            optionLabel: (action) => action.displayLabel,
            onChanged: (action) {
              if (action == null) {
                return;
              }
              DeviceStatusService.get.setDoubleTapAction(action);
            },
          ),
          if (!connected) ...[
            const SizedBox(height: 12),
            Text(
              'Connect the glasses to change these.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF7C8C99),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingDropdown<T>({
    required String label,
    required String description,
    required T? value,
    required String unsetLabel,
    required bool connected,
    required List<T> options,
    required String Function(T) optionLabel,
    required ValueChanged<T?> onChanged,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 4),
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: const Color(0xFF9AB7C8),
          ),
        ),
        const SizedBox(height: 8),
        InputDecorator(
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              hint: Text(unsetLabel),
              isExpanded: true,
              onChanged: connected ? onChanged : null,
              items: options
                  .map(
                    (option) => DropdownMenuItem<T>(
                      value: option,
                      child: Text(optionLabel(option)),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionsSection() {
    final controller = CompanionController.get;
    return _buildSectionCard(
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
                ? 'Notification access is enabled.'
                : 'Notification access is required for Glance and Navigate.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF9AB7C8),
                ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: controller.openNotificationAccessSettings,
            child: Text(
              controller.notificationAccessEnabled
                  ? 'Open notification access'
                  : 'Enable notification access',
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: !_initialized
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildApiSection(),
                const SizedBox(height: 16),
                _buildHermesSection(),
                const SizedBox(height: 16),
                _buildNotificationFiltersSection(),
                const SizedBox(height: 16),
                _buildFirmwareSettingsSection(),
                const SizedBox(height: 16),
                _buildPermissionsSection(),
              ],
            ),
    );
  }

  @override
  void dispose() {
    AppSettingsStore.get.removeListener(_handleStoreChanged);
    NotificationSettingsStore.get.removeListener(_handleStoreChanged);
    CompanionController.get.removeListener(_handleStoreChanged);
    DeviceStatusService.get.removeListener(_handleStoreChanged);
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _chatModelController.dispose();
    _transcriptionModelController.dispose();
    _hermesApiKeyController.dispose();
    _hermesBaseUrlController.dispose();
    _hermesChatModelController.dispose();
    _hermesTimeoutController.dispose();
    super.dispose();
  }
}
