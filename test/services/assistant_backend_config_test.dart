import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/assistant_backend_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory stand-in for flutter_secure_storage's platform channel.
  final secureValues = <String, String>{};

  setUp(() async {
    secureValues.clear();
    SharedPreferences.setMockInitialValues({});
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      switch (call.method) {
        case 'read':
          return secureValues[args['key'] as String];
        case 'write':
          secureValues[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          secureValues.remove(args['key'] as String);
          return null;
        case 'readAll':
          return Map<String, String>.from(secureValues);
        case 'containsKey':
          return secureValues.containsKey(args['key'] as String);
        default:
          return null;
      }
    });
    // The store is a singleton that loads once, so rather than adding a
    // test-only reset to lib/ this writes every field this suite touches
    // back to empty - the same approach the former router suite used.
    await AppSettingsStore.get.saveAssistantSettings(
      apiKey: '',
      baseUrl: '',
      chatModel: '',
      transcriptionModel: '',
      transcriptionBaseUrl: '',
    );
  });

  group('resolveTranscription', () {
    test('needs no API key to be usable', () async {
      final config = AssistantBackendConfig.resolveTranscription();
      expect(config.apiKey, isEmpty);
      expect(config.requiresApiKey, isFalse);
      // The whole point: an unauthenticated self-hosted endpoint must not
      // read as unconfigured, or transcription refuses before it tries.
      expect(config.isConfigured, isTrue);
    });

    test('defaults to the local whisper-server, not OpenAI', () {
      final config = AssistantBackendConfig.resolveTranscription();
      expect(config.baseUrl, 'http://deepthought:56478/v1');
      expect(config.transcriptionModel, contains('faster-whisper'));
      expect(config.profileLabel, 'Whisper');
    });

    test('a saved base URL overrides the build default', () async {
      await AppSettingsStore.get.saveAssistantSettings(
        apiKey: '',
        baseUrl: '',
        chatModel: '',
        transcriptionModel: 'tiny.en',
        transcriptionBaseUrl: 'http://elsewhere:9000/v1',
      );
      final config = AssistantBackendConfig.resolveTranscription();
      expect(config.baseUrl, 'http://elsewhere:9000/v1');
      expect(config.transcriptionModel, 'tiny.en');
      expect(config.usingRuntimeBaseUrl, isTrue);
    });
  });

  group('shouldSendApiKey', () {
    test('withholds the bearer from a cleartext endpoint', () async {
      await AppSettingsStore.get.saveAssistantSettings(
        apiKey: 'sk-test-not-a-real-key',
        baseUrl: '',
        chatModel: '',
        transcriptionModel: '',
        transcriptionBaseUrl: 'http://deepthought:56478/v1',
      );
      final config = AssistantBackendConfig.resolveTranscription();
      expect(config.apiKey, isNotEmpty);
      // Present but deliberately not sent: the local endpoint ignores it, and
      // a token does not belong on a plaintext request.
      expect(config.shouldSendApiKey, isFalse);
    });

    test('sends the bearer over TLS', () async {
      await AppSettingsStore.get.saveAssistantSettings(
        apiKey: 'sk-test-not-a-real-key',
        baseUrl: '',
        chatModel: '',
        transcriptionModel: '',
        transcriptionBaseUrl: 'https://api.openai.com/v1',
      );
      final config = AssistantBackendConfig.resolveTranscription();
      expect(config.shouldSendApiKey, isTrue);
    });

    test('sends nothing when no key is configured', () {
      final config = AssistantBackendConfig.resolveTranscription();
      expect(config.shouldSendApiKey, isFalse);
    });
  });

  group('resolve (chat profile)', () {
    test('still demands an API key', () {
      final config = AssistantBackendConfig.resolve();
      expect(config.requiresApiKey, isTrue);
      expect(config.isConfigured, isFalse);
      expect(config.profileLabel, 'OpenAI');
    });

    test('keeps chat on OpenAI, independent of the STT endpoint', () async {
      await AppSettingsStore.get.saveAssistantSettings(
        apiKey: 'sk-test-not-a-real-key',
        baseUrl: '',
        chatModel: '',
        transcriptionModel: '',
        transcriptionBaseUrl: 'http://deepthought:56478/v1',
      );
      final config = AssistantBackendConfig.resolve();
      expect(config.baseUrl, 'https://api.openai.com/v1');
      expect(config.isConfigured, isTrue);
    });
  });
}
