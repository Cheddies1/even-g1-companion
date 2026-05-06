import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/models/notification_package_preference.dart';
import 'package:demo_ai_even/services/app_settings_store.dart';
import 'package:demo_ai_even/services/assistant_backend_config.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
import 'package:demo_ai_even/services/device_status_service.dart';
import 'package:demo_ai_even/services/notification_settings_store.dart';
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

  bool _initialized = false;
  bool _saving = false;
  bool _obscureApiKey = true;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController();
    _baseUrlController = TextEditingController();
    _chatModelController = TextEditingController();
    _transcriptionModelController = TextEditingController();
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
          else
            ...packages.take(20).map(
                  (entry) => _buildPackageRow(entry),
                ),
        ],
      ),
    );
  }

  Widget _buildPackageRow(NotificationPackagePreference entry) {
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: const Color(0xFF7C8C99),
        );
    const labelStyle = TextStyle(fontSize: 11, color: Color(0xFF7C8C99));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: entry.isBuiltInCandidate
          ? const Icon(Icons.tune, size: 18)
          : null,
      title: Text(
        entry.displayName.isNotEmpty ? entry.displayName : entry.packageName,
      ),
      subtitle: Text(entry.packageName, style: subtitleStyle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Now\nPlaying', style: labelStyle, textAlign: TextAlign.center),
              Switch(
                value: entry.mediaOverride == true,
                activeThumbColor: const Color(0xFF4A8D72),
                onChanged: (value) async {
                  await NotificationSettingsStore.get.setPackageMedia(
                    entry.packageName,
                    value ? true : null,
                  );
                  await CompanionController.get.refreshCompanionState();
                },
              ),
            ],
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Mute', style: labelStyle),
              Switch(
                value: entry.suppressed,
                activeThumbColor: const Color(0xFF4A8D72),
                onChanged: (value) async {
                  await NotificationSettingsStore.get.setPackageSuppressed(
                    entry.packageName,
                    value,
                  );
                  await CompanionController.get.refreshCompanionState();
                },
              ),
            ],
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
    super.dispose();
  }
}
