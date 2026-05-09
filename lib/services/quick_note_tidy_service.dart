import 'dart:convert';

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
      'Also classify the note as one of: shopping (items to buy or a shopping '
      'list), todo (tasks, reminders, actions to take), or notes (everything '
      'else including observations, ideas, and general reminders).\n'
      '\n'
      'Return a JSON object: {"text": "cleaned note", "category": "shopping|todo|notes"}';

  // Few-shot anchor pairs inlined from test/fixtures/quicknote/anchor_pairs.json.
  // These ground the model on the expected cleanup behaviour: stripping filler,
  // honouring self-corrections, collapsing thinking-aloud framing, and
  // classifying into the correct category.
  // The assistant turns use JSON format to match the system prompt's instruction.
  static const _anchorPairs = [
    (
      raw:
          'um so I need to remember to to call mom about the plumbing thing er the leak in the kitchen yeah',
      cleaned:
          '{"text": "Call Mum about the leak in the kitchen.", "category": "todo"}',
    ),
    (
      raw:
          'ok so the the meeting is moved to wait no it\'s still tomorrow but the location changed it\'s now in conference room B not A',
      cleaned:
          '{"text": "Meeting is still tomorrow, but moved to conference room B (was A).", "category": "notes"}',
    ),
    (
      raw:
          'thinking about the the LC3 thing for the watch app yeah I should check if the byte five field changes when the note is longer that would be interesting',
      cleaned:
          '{"text": "Check whether the LC3 byte-5 field changes when the note is longer.", "category": "todo"}',
    ),
  ];

  /// Returns a cleaned version of [rawTranscript] together with its category.
  ///
  /// The record fields are:
  /// - [text]: the cleaned note text.
  /// - [category]: one of 'shopping', 'todo', or 'notes'.
  ///
  /// On any API error, or if the response cannot be parsed as JSON, falls back
  /// to `(text: rawTranscript, category: 'notes')` so the caller never loses
  /// the original note.
  Future<({String text, String category})> tidy(String rawTranscript) async {
    final fallback = (text: rawTranscript, category: 'notes');

    if (rawTranscript.trim().isEmpty) {
      return fallback;
    }

    final config = AssistantBackendConfig.resolve();
    if (!config.isConfigured) {
      AppLog.info(
        '${DateTime.now()} QuickNoteTidy skipped — no API key configured',
        tag: _tag,
      );
      return fallback;
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
        return fallback;
      }
      return _parseResponse(content.trim(), rawTranscript);
    } catch (e) {
      AppLog.info(
        '${DateTime.now()} QuickNoteTidy failed — returning raw. Error: $e',
        tag: _tag,
      );
      return fallback;
    }
  }

  /// Parses the JSON response from the model into a text+category record.
  ///
  /// Expected format: {"text": "...", "category": "shopping|todo|notes"}.
  /// On any parse failure, returns the raw transcript with category 'notes'.
  ({String text, String category}) _parseResponse(
    String content,
    String rawTranscript,
  ) {
    try {
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final text = decoded['text'] as String?;
      final category = decoded['category'] as String?;

      final validCategories = {'shopping', 'todo', 'notes'};
      final resolvedCategory =
          (category != null && validCategories.contains(category))
              ? category
              : 'notes';

      if (text == null || text.trim().isEmpty) {
        AppLog.info(
          '${DateTime.now()} QuickNoteTidy: JSON missing text field — returning raw',
          tag: _tag,
        );
        return (text: rawTranscript, category: resolvedCategory);
      }

      AppLog.info(
        '${DateTime.now()} QuickNoteTidy: raw=${rawTranscript.length}chars '
        'tidied=${text.length}chars category=$resolvedCategory',
        tag: _tag,
      );
      return (text: text.trim(), category: resolvedCategory);
    } catch (e) {
      AppLog.info(
        '${DateTime.now()} QuickNoteTidy: JSON parse failed — returning raw. Error: $e',
        tag: _tag,
      );
      return (text: rawTranscript, category: 'notes');
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
