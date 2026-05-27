import 'package:dio/dio.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/assistant_backend_config.dart';
import 'package:even_companion/services/chat_backend.dart';
import 'package:even_companion/services/chat_backend_router.dart';
import 'package:even_companion/services/openai_chat_backend.dart';
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

    // The store is a singleton, so force a fresh load against the mocks and
    // reset every field this suite depends on.
    final store = AppSettingsStore.get;
    await store.setAssistantBackend(AssistantBackendKind.openai);
    await store.setHermesFallbackEnabled(true);
    await store.saveHermesSettings(apiKey: '', baseUrl: '', chatModel: '');
  });

  group('ChatBackendRouter.resolveRoute', () {
    late OpenAiChatBackend openAi;
    late OpenAiChatBackend hermes;

    ChatBackendRouter buildRouter({required bool reachable}) {
      openAi = OpenAiChatBackend();
      hermes = OpenAiChatBackend(
        configResolver: AssistantBackendConfig.resolveHermes,
      );
      return ChatBackendRouter(
        openAiBackend: openAi,
        hermesBackend: hermes,
        healthProbe: (_) async => reachable,
      );
    }

    Future<void> configureHermes() => AppSettingsStore.get.saveHermesSettings(
          apiKey: 'bearer-token',
          baseUrl: 'http://deepthought:8642/v1',
          chatModel: 'hermes-agent',
        );

    test('OpenAI selected routes to OpenAI with no notice', () async {
      await AppSettingsStore.get.setAssistantBackend(AssistantBackendKind.openai);
      final router = buildRouter(reachable: false);

      final route = await router.resolveRoute();

      expect(identical(route.backend, openAi), isTrue);
      expect(route.notice, isNull);
    });

    test('Hermes selected and reachable routes to Hermes', () async {
      await AppSettingsStore.get.setAssistantBackend(AssistantBackendKind.hermes);
      await configureHermes();
      final router = buildRouter(reachable: true);

      final route = await router.resolveRoute();

      expect(identical(route.backend, hermes), isTrue);
      expect(route.notice, isNull);
    });

    test('Hermes unreachable with fallback falls back to OpenAI with notice',
        () async {
      await AppSettingsStore.get.setAssistantBackend(AssistantBackendKind.hermes);
      await AppSettingsStore.get.setHermesFallbackEnabled(true);
      await configureHermes();
      final router = buildRouter(reachable: false);

      final route = await router.resolveRoute();

      expect(identical(route.backend, openAi), isTrue);
      expect(route.notice, contains('fallback'));
    });

    test('Hermes unreachable without fallback throws network error', () async {
      await AppSettingsStore.get.setAssistantBackend(AssistantBackendKind.hermes);
      await AppSettingsStore.get.setHermesFallbackEnabled(false);
      await configureHermes();
      final router = buildRouter(reachable: false);

      await expectLater(
        router.resolveRoute(),
        throwsA(
          isA<ChatBackendException>().having(
            (e) => e.kind,
            'kind',
            ChatBackendErrorKind.network,
          ),
        ),
      );
    });

    test('Hermes unconfigured with fallback uses OpenAI with notice', () async {
      await AppSettingsStore.get.setAssistantBackend(AssistantBackendKind.hermes);
      await AppSettingsStore.get.setHermesFallbackEnabled(true);
      // No saveHermesSettings -> base URL + key empty -> not configured.
      final router = buildRouter(reachable: true);

      final route = await router.resolveRoute();

      expect(identical(route.backend, openAi), isTrue);
      expect(route.notice, contains('fallback'));
    });

    test('Hermes unconfigured without fallback throws auth error', () async {
      await AppSettingsStore.get.setAssistantBackend(AssistantBackendKind.hermes);
      await AppSettingsStore.get.setHermesFallbackEnabled(false);
      final router = buildRouter(reachable: true);

      await expectLater(
        router.resolveRoute(),
        throwsA(
          isA<ChatBackendException>().having(
            (e) => e.kind,
            'kind',
            ChatBackendErrorKind.auth,
          ),
        ),
      );
    });
  });

  group('probeHermesHealth', () {
    test('empty base URL is unreachable without any request', () async {
      expect(await probeHermesHealth(''), isFalse);
    });

    test('any HTTP status (even 404) counts as reachable', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://host:8642/v1'))
        ..httpClientAdapter = _FakeAdapter(
          (options) async => ResponseBody.fromString('', 404),
        );

      expect(await probeHermesHealth('http://host:8642/v1', dio: dio), isTrue);
    });

    test('transport failure counts as unreachable', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://host:8642/v1'))
        ..httpClientAdapter = _FakeAdapter(
          (options) async => throw DioException.connectionError(
            requestOptions: options,
            reason: 'connection refused',
          ),
        );

      expect(await probeHermesHealth('http://host:8642/v1', dio: dio), isFalse);
    });
  });
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  final Future<ResponseBody> Function(RequestOptions options) responder;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      responder(options);
}
