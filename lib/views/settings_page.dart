import 'package:demo_ai_even/services/app_settings_store.dart';
import 'package:demo_ai_even/services/assistant_backend_config.dart';
import 'package:demo_ai_even/services/companion_controller.dart';
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
            'Suppress noisy packages from Glance. Ongoing notifications remain handled by the built-in policy.',
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
                  (entry) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: entry.suppressed,
                    activeThumbColor: const Color(0xFF4A8D72),
                    title: Text(
                      entry.displayName.isNotEmpty
                          ? entry.displayName
                          : entry.packageName,
                    ),
                    subtitle: Text(
                      entry.packageName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF7C8C99),
                          ),
                    ),
                    secondary: entry.isBuiltInCandidate
                        ? const Icon(Icons.tune, size: 18)
                        : null,
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
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _chatModelController.dispose();
    _transcriptionModelController.dispose();
    super.dispose();
  }
}
