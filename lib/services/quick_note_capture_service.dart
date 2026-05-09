import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/app_log.dart';
import 'package:demo_ai_even/services/notes_store.dart';
import 'package:demo_ai_even/services/openai_transcription_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/quick_note_tidy_service.dart';

/// Receives a flushed QuickNote audio payload from the BLE layer, decodes it
/// from LC3 to PCM via the native JNI decoder, and writes a WAV file the user
/// can inspect.
///
/// **GO/NO-GO probe** — this service exists solely to answer the question
/// "is the buffered audio coherent speech?". No notes are stored, no
/// transcription is attempted. The deliverable is a WAV file at a stable,
/// discoverable path.
///
/// ## How to use
///
/// 1. Trigger a long-press-right on the G1 glasses.
/// 2. Run: `adb logcat -s QuickNoteCapture`
/// 3. The log line `WAV saved: <path>` gives the absolute device path.
/// 4. Pull the file: `adb pull <path> probe.wav`
/// 5. Listen. If it sounds like speech → GO. If noise → investigate codec.
///
/// ## Frame-size hypothesis
///
/// Primary: **200 bytes** — matches the live-mic `0xF1` path (`value.copyOfRange(2, 202)`).
/// If the resulting WAV is silent or obviously garbled, fall back to:
///   - 80 bytes (standard LC3 frame at 16 kHz / 64 kbps, 20 ms)
///   - 40 bytes (standard LC3 frame at 16 kHz / 64 kbps, 10 ms)
/// The first candidate that yields non-empty PCM wins; one WAV is written per
/// probe cycle. Only if every frame of a given size errors at the JNI level
/// does the loop advance to the next candidate.
class QuickNoteCaptureService {
  QuickNoteCaptureService._();

  static QuickNoteCaptureService? _instance;
  static QuickNoteCaptureService get get =>
      _instance ??= QuickNoteCaptureService._();

  static const _tag = 'QuickNoteCapture';
  static const _sampleRate = 16000;
  static const _channelCount = 1;
  static const _bitsPerSample = 16;

  /// Frame sizes to probe, in order. Primary first.
  ///
  /// If 200-byte framing returns zero PCM (every frame errored in the JNI
  /// decoder), the loop falls through to 80 then 40. Otherwise the first
  /// non-empty result wins and only one WAV is written. To compare frame
  /// sizes manually, re-trigger and edit this list.
  // The LC3 frame size is 200 bytes — same as the live-mic 0xF1 path.
  // BLE chunk boundaries (190-byte payloads after stripping the 10-byte
  // header) do NOT align with LC3 frame boundaries. The concatenated stream
  // must be sliced at 200-byte intervals, not 190. Slicing at 190 produces
  // audible frame-boundary clicks because each "frame" straddles two real
  // LC3 frames. 80/40 are standard LC3 fallbacks.
  static const _frameSizeCandidates = [200, 80, 40];

  static const _subDir = 'quicknote';

  /// Entry point called by [BleManager._methodCallHandler] when Kotlin fires
  /// `quickNoteAudioReady`. Runs asynchronously — returns immediately.
  Future<void> handleAudioReady(Uint8List noteUid, Uint8List audio) async {
    // Clear the capture-active flag so clearDisplay() resumes working.
    Proto.quickNoteCaptureComplete();

    // Send the firmware ack (04 01) immediately to close the transfer cycle.
    // Must fire unconditionally — even if decode/STT fails, the firmware
    // needs to know we received the audio so the next long-press works.
    unawaited(Proto.quickNoteAck(lr: 'R'));

    final uidHex = noteUid
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');

    AppLog.info(
      '${DateTime.now()} QuickNote audio received: uidHex=$uidHex audioBytes=${audio.length}',
      tag: _tag,
    );

    if (audio.isEmpty) {
      AppLog.info(
        '${DateTime.now()} audio payload is empty — nothing to decode',
        tag: _tag,
      );
      return;
    }

    final outputDir = await _resolveOutputDir();
    if (outputDir == null) {
      AppLog.error(
        '${DateTime.now()} external files dir unavailable — cannot write WAV',
        tag: _tag,
      );
      return;
    }

    String? successWavPath;
    for (final frameSize in _frameSizeCandidates) {
      final pcm = await _decodeLc3(audio, frameSize);
      if (pcm == null) continue;
      if (pcm.isEmpty) {
        AppLog.info(
          '${DateTime.now()} frameSize=$frameSize produced 0 PCM bytes — trying next candidate',
          tag: _tag,
        );
        continue;
      }

      final fileName = 'probe_${timestamp}_${uidHex}_f$frameSize.wav';
      final wavPath = '$outputDir/$fileName';
      try {
        await _writeWav(wavPath, pcm);
        AppLog.info(
          '${DateTime.now()} WAV saved: $wavPath (frameSize=$frameSize pcmBytes=${pcm.length})',
          tag: _tag,
        );
        successWavPath = wavPath;
        break;
      } catch (e) {
        AppLog.error(
          '${DateTime.now()} WAV write failed for frameSize=$frameSize: $e',
          tag: _tag,
        );
      }
    }

    if (successWavPath == null) {
      AppLog.error(
        '${DateTime.now()} all frame-size candidates failed — no WAV written for uidHex=$uidHex',
        tag: _tag,
      );
      return;
    }

    // --- STT → NotesStore → async tidy ---
    await _transcribeAndStore(successWavPath, noteUid);
  }

  /// Transcribes [wavPath] via OpenAI Whisper, inserts into [NotesStore],
  /// then asynchronously tidies the raw transcript and updates the row.
  Future<void> _transcribeAndStore(String wavPath, Uint8List noteUid) async {
    final createdAt = DateTime.now().millisecondsSinceEpoch;

    // Step 1: Transcribe the WAV.
    String? rawTranscript;
    String? error;
    try {
      final stt = OpenAiTranscriptionService();
      rawTranscript = await stt.transcribe(wavPath);
      AppLog.info(
        '${DateTime.now()} STT result: "${rawTranscript.length > 80 ? '${rawTranscript.substring(0, 80)}...' : rawTranscript}"',
        tag: _tag,
      );
    } on ChatTranscriptionException catch (e) {
      AppLog.error('${DateTime.now()} STT failed: $e', tag: _tag);
      error = e.message;
    } catch (e) {
      AppLog.error('${DateTime.now()} STT unexpected error: $e', tag: _tag);
      error = e.toString();
    }

    // Step 2: Insert into NotesStore immediately (raw transcript visible in UI).
    final noteId = await NotesStore.get.insert(
      createdAt: createdAt,
      transcriptRaw: rawTranscript,
      status: 'active',
      sortOrder: createdAt.toDouble(),
      noteUid: noteUid,
      error: error,
    );
    AppLog.info(
      '${DateTime.now()} note inserted: id=$noteId raw=${rawTranscript != null ? "yes" : "no"} error=${error ?? "none"}',
      tag: _tag,
    );

    // Step 3: If raw transcript exists, tidy it asynchronously.
    if (rawTranscript != null && rawTranscript.isNotEmpty) {
      _tidyAsync(noteId, rawTranscript);
    }
  }

  /// Runs the tidy service in the background. Does not block the caller.
  /// If tidy fails, the raw transcript remains — the note is still usable.
  ///
  /// Known limitation: if the user swipe-deletes this note and taps Undo
  /// while tidy is in-flight, the restored note gets a new autoincrement ID.
  /// The tidy closure still holds the old ID, so the update is a silent no-op.
  /// The restored note keeps its raw transcript. Acceptable for v1.
  void _tidyAsync(int noteId, String rawTranscript) {
    // Import will resolve once the TidyService agent delivers the file.
    // For now, schedule it as a fire-and-forget async block.
    unawaited(() async {
      try {
        // Lazy-import pattern: QuickNoteTidyService will be created by the
        // background agent. If it doesn't exist yet, this will be a compile
        // error that we fix when the agent returns.
        final tidy = await _callTidyService(rawTranscript);
        if (tidy != null && tidy.isNotEmpty && tidy != rawTranscript) {
          await NotesStore.get.updateTranscriptClean(
            id: noteId,
            transcriptClean: tidy,
          );
          AppLog.info(
            '${DateTime.now()} tidy complete for note $noteId: "${tidy.length > 60 ? '${tidy.substring(0, 60)}...' : tidy}"',
            tag: _tag,
          );
        }
      } catch (e) {
        AppLog.error(
          '${DateTime.now()} tidy failed for note $noteId: $e',
          tag: _tag,
        );
        // Don't update error on the note — raw transcript is still valid.
      }
    }());
  }

  /// Calls the tidy service to clean up the raw transcript.
  Future<String?> _callTidyService(String rawTranscript) async {
    return QuickNoteTidyService.get.tidy(rawTranscript);
  }

  /// Calls the native `decodeLc3Frames` method with the given [audio] bytes and
  /// [frameSize]. Returns the decoded PCM as a [Uint8List], or `null` on error.
  Future<Uint8List?> _decodeLc3(Uint8List audio, int frameSize) async {
    try {
      final result = await BleManager.invokeMethod<Uint8List>(
        'decodeLc3Frames',
        {'audio': audio, 'frameSize': frameSize},
      );
      if (result == null) {
        AppLog.error(
          '${DateTime.now()} decodeLc3Frames returned null for frameSize=$frameSize',
          tag: _tag,
        );
        return null;
      }
      AppLog.info(
        '${DateTime.now()} decodeLc3Frames: frameSize=$frameSize pcmBytes=${result.length}',
        tag: _tag,
      );
      return result;
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} decodeLc3Frames error frameSize=$frameSize: $e',
        tag: _tag,
      );
      return null;
    }
  }

  /// Writes a 44-byte RIFF/WAV header followed by [pcm] bytes to [filePath].
  ///
  /// Parameters match [GlassesCaptureRecorder]: 16000 Hz, mono, 16-bit LE PCM.
  Future<void> _writeWav(String filePath, Uint8List pcm) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);

    final header = _buildWavHeader(pcm.length);
    final sink = file.openWrite();
    sink.add(header);
    sink.add(pcm);
    await sink.flush();
    await sink.close();
  }

  /// Builds the 44-byte RIFF/WAV header for [pcmByteCount] bytes of audio.
  ///
  /// Format: PCM (1), mono (1 channel), 16000 Hz, 16-bit samples, little-endian.
  Uint8List _buildWavHeader(int pcmByteCount) {
    const int headerSize = 44;
    const int fmtChunkSize = 16;
    const int audioFormat = 1; // PCM
    const int byteRate = _sampleRate * _channelCount * _bitsPerSample ~/ 8;
    const int blockAlign = _channelCount * _bitsPerSample ~/ 8;

    final data = ByteData(headerSize);
    int offset = 0;

    // RIFF chunk descriptor
    _writeAscii(data, offset, 'RIFF');
    offset += 4;
    data.setUint32(offset, pcmByteCount + 36, Endian.little);
    offset += 4;
    _writeAscii(data, offset, 'WAVE');
    offset += 4;

    // fmt sub-chunk
    _writeAscii(data, offset, 'fmt ');
    offset += 4;
    data.setUint32(offset, fmtChunkSize, Endian.little);
    offset += 4;
    data.setUint16(offset, audioFormat, Endian.little);
    offset += 2;
    data.setUint16(offset, _channelCount, Endian.little);
    offset += 2;
    data.setUint32(offset, _sampleRate, Endian.little);
    offset += 4;
    data.setUint32(offset, byteRate, Endian.little);
    offset += 4;
    data.setUint16(offset, blockAlign, Endian.little);
    offset += 2;
    data.setUint16(offset, _bitsPerSample, Endian.little);
    offset += 2;

    // data sub-chunk
    _writeAscii(data, offset, 'data');
    offset += 4;
    data.setUint32(offset, pcmByteCount, Endian.little);

    return data.buffer.asUint8List();
  }

  void _writeAscii(ByteData data, int offset, String text) {
    for (int i = 0; i < text.length; i++) {
      data.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  /// Returns the absolute path to the `quicknote` subdirectory inside the
  /// app's primary external files dir, or `null` if unavailable.
  Future<String?> _resolveOutputDir() async {
    try {
      final base = await BleManager.invokeMethod<String>('getExternalFilesDir');
      if (base == null || base.isEmpty) {
        return null;
      }
      return '$base/$_subDir';
    } catch (e) {
      AppLog.error(
        '${DateTime.now()} getExternalFilesDir failed: $e',
        tag: _tag,
      );
      return null;
    }
  }
}
