import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/assistant_backend_config.dart';
import 'package:dio/dio.dart';

/// Cleans up raw speech-to-text transcripts into tidy notes.
///
/// Takes the raw STT output from a QuickNote capture — which typically
/// contains filler words, stutters, false starts, and thinking-aloud framing —
/// and returns a concise note that preserves the speaker's intent.
///
/// If the API call fails for any reason the raw transcript is returned
/// unchanged so the user never loses their note.
class QuickNoteTidyService {
  QuickNoteTidyService._();

  static QuickNoteTidyService? _instance;
  static QuickNoteTidyService get get =>
      _instance ??= QuickNoteTidyService._();

  static const _tag = 'QuickNoteTidy';

  // Intentionally independent of AssistantBackendConfig.maxOutputTokens.
  // That constant is tuned for chat-display length on the glasses. Notes
  // have a different budget: brief but not truncated to display width.
  static const _maxTidyTokens = 200;

  static const _systemPrompt =
      'You clean up voice-transcribed notes. The input is raw speech-to-text '
      'output that may contain filler words, stutters, false starts, '
      'mid-sentence corrections, and thinking-aloud framing.\n'
      '\n'
      'Produce a clean, concise note that preserves the speaker\'s intent and '
      'voice. Strip filler (um, er, uh, yeah, so), fix obvious transcription '
      'errors, honour self-corrections (when the speaker says "wait no '
      'actually", use their correction). Do NOT summarise aggressively — keep '
      'specific details, names, numbers, and action items.\n'
      '\n'
      'Return ONLY the cleaned note text. No quotes, no preamble, no '
      'explanation.';

  // Few-shot anchor pairs inlined from test/fixtures/quicknote/anchor_pairs.json.
  // These ground the model on the expected cleanup behaviour: stripping filler,
  // honouring self-corrections, and collapsing thinking-aloud framing into the
  // concrete note.
  static const _anchorPairs = [
    (
      raw:
          'um so I need to remember to to call mom about the plumbing thing er the leak in the kitchen yeah',
      cleaned: 'Call Mum about the leak in the kitchen.',
    ),
    (
      raw:
          'ok so the the meeting is moved to wait no it\'s still tomorrow but the location changed it\'s now in conference room B not A',
      cleaned:
          'Meeting is still tomorrow, but moved to conference room B (was A).',
    ),
    (
      raw:
          'thinking about the the LC3 thing for the watch app yeah I should check if the byte five field changes when the note is longer that would be interesting',
      cleaned:
          'Check whether the LC3 byte-5 field changes when the note is longer.',
    ),
  ];

  /// Returns a cleaned version of [rawTranscript].
  ///
  /// On any API error, logs at info level and returns [rawTranscript] unchanged.
  Future<String> tidy(String rawTranscript) async {
    if (rawTranscript.trim().isEmpty) {
      return rawTranscript;
    }

    final config = AssistantBackendConfig.resolve();
    if (!config.isConfigured) {
      AppLog.info(
        '${DateTime.now()} QuickNoteTidy skipped — no API key configured',
        tag: _tag,
      );
      return rawTranscript;
    }

    final messages = _buildMessages(rawTranscript);
    final payload = {
      'model': config.chatModel,
      'max_completion_tokens': _maxTidyTokens,
      'messages': messages,
    };

    final client = _buildClient(config);
    try {
      final response = await client.post('/chat/completions', data: payload);
      final content =
          response.data['choices']?[0]?['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        AppLog.info(
          '${DateTime.now()} QuickNoteTidy: API returned empty content — returning raw',
          tag: _tag,
        );
        return rawTranscript;
      }
      final tidied = content.trim();
      AppLog.info(
        '${DateTime.now()} QuickNoteTidy: raw=${rawTranscript.length}chars tidied=${tidied.length}chars',
        tag: _tag,
      );
      return tidied;
    } catch (e) {
      AppLog.info(
        '${DateTime.now()} QuickNoteTidy failed — returning raw. Error: $e',
        tag: _tag,
      );
      return rawTranscript;
    }
  }

  List<Map<String, String>> _buildMessages(String rawTranscript) {
    return [
      {'role': 'system', 'content': _systemPrompt},
      // Few-shot examples as alternating user/assistant turns.
      for (final pair in _anchorPairs) ...[
        {'role': 'user', 'content': pair.raw},
        {'role': 'assistant', 'content': pair.cleaned},
      ],
      {'role': 'user', 'content': rawTranscript},
    ];
  }

  Dio _buildClient(AssistantBackendConfig config) {
    return Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 45),
        sendTimeout: const Duration(seconds: 45),
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
      ),
    );
  }
}
