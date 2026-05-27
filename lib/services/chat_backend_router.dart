import 'package:dio/dio.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/app_settings_store.dart';
import 'package:even_companion/services/assistant_backend_config.dart';
import 'package:even_companion/services/chat_backend.dart';
import 'package:even_companion/services/openai_chat_backend.dart';

/// Short timeout for the Hermes reachability probe. Independent of the chat
/// receive timeout (which is 90–120 s for the agent's tool loop) so an
/// unreachable Hermes falls back fast instead of stalling the user.
const _healthProbeTimeout = Duration(seconds: 3);

/// Probe whether the Hermes endpoint is reachable, with a short timeout.
///
/// [baseUrl] is the OpenAI-compatible base (e.g. `http://deepthought:8642/v1`);
/// the probe hits `<baseUrl>/health`. Returns true if the host answered with
/// *any* HTTP status (even 4xx/5xx) — that means Hermes is up and any error
/// will surface through the chat call itself. Returns false only on
/// transport-level failure (connection refused, DNS, timeout), which is the
/// sole condition the router treats as "unreachable → fall back to OpenAI".
Future<bool> probeHermesHealth(
  String baseUrl, {
  Dio? dio,
}) async {
  if (baseUrl.isEmpty) {
    return false;
  }
  final client = dio ??
      Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: _healthProbeTimeout,
          receiveTimeout: _healthProbeTimeout,
          sendTimeout: _healthProbeTimeout,
        ),
      );
  try {
    await client.get<void>(
      '/health',
      // Accept any status so a non-200 still counts as "reachable".
      options: Options(validateStatus: (_) => true),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// The backend chosen for a single chat turn, plus an optional user-visible
/// notice the caller should surface once before streaming.
class ChatRoute {
  const ChatRoute({required this.backend, this.notice});

  final ChatBackend backend;

  /// One-line message to show on the glasses before the answer streams, e.g.
  /// "Hermes unreachable. Using fallback." Null when no notice is needed.
  final String? notice;
}

/// Decides, per turn, whether the reasoning call goes to Hermes or OpenAI.
///
/// Routing is a pre-flight decision made *before* streaming starts (mid-stream
/// fallback is unsalvageable — partial text would already be on the glasses).
/// Only Hermes transport failures fall back; an auth/5xx from a reachable
/// Hermes is a misconfiguration and is surfaced, not masked, by letting the
/// Hermes backend run and throw.
class ChatBackendRouter {
  ChatBackendRouter({
    OpenAiChatBackend? openAiBackend,
    OpenAiChatBackend? hermesBackend,
    Future<bool> Function(String baseUrl)? healthProbe,
  })  : _openAi = openAiBackend ?? OpenAiChatBackend(),
        _hermes = hermesBackend ??
            OpenAiChatBackend(
              configResolver: AssistantBackendConfig.resolveHermes,
            ),
        _healthProbe = healthProbe ?? probeHermesHealth;

  final OpenAiChatBackend _openAi;
  final OpenAiChatBackend _hermes;
  final Future<bool> Function(String baseUrl) _healthProbe;

  /// Resolve which backend handles this turn. Reads settings fresh each call
  /// so a runtime backend switch takes effect on the next turn.
  ///
  /// Throws [ChatBackendException] when Hermes is the only option but cannot
  /// serve the request (unconfigured, or unreachable with fallback disabled),
  /// so the caller surfaces a clean error instead of waiting out the full
  /// chat timeout.
  Future<ChatRoute> resolveRoute() async {
    final settings = AppSettingsStore.get;
    if (settings.assistantBackend == AssistantBackendKind.openai) {
      return ChatRoute(backend: _openAi);
    }

    final fallbackAllowed = settings.hermesFallbackEnabled;
    final hermesConfig = AssistantBackendConfig.resolveHermes();

    if (!hermesConfig.isConfigured) {
      if (fallbackAllowed) {
        AppLog.info(
          '${DateTime.now()} Hermes not configured — using OpenAI fallback',
          tag: 'ChatRouter',
        );
        return ChatRoute(
          backend: _openAi,
          notice: 'Hermes not set up. Using fallback.',
        );
      }
      throw const ChatBackendException(
        'Hermes backend is not configured (missing key or URL)',
        kind: ChatBackendErrorKind.auth,
      );
    }

    final reachable = await _healthProbe(hermesConfig.baseUrl);
    if (reachable) {
      AppLog.info(
        '${DateTime.now()} Hermes reachable — routing to Hermes',
        tag: 'ChatRouter',
      );
      return ChatRoute(backend: _hermes);
    }

    if (fallbackAllowed) {
      AppLog.info(
        '${DateTime.now()} Hermes unreachable — using OpenAI fallback',
        tag: 'ChatRouter',
      );
      return ChatRoute(
        backend: _openAi,
        notice: 'Hermes unreachable. Using fallback.',
      );
    }

    throw const ChatBackendException(
      'Hermes unreachable and fallback is disabled',
      kind: ChatBackendErrorKind.network,
    );
  }
}
