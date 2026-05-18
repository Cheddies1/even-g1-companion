/// One on-disk recording surfaced from MediaStore under
/// `Recordings/Even Companion/`. This model is a thin reflection of the
/// platform-channel payload — there is no local database; the source of
/// truth is the filesystem.
class Recording {
  Recording({
    required this.id,
    required this.uri,
    required this.fileName,
    required this.dateAddedMs,
    required this.durationMs,
    required this.sizeBytes,
  });

  final int id;
  final String uri;
  final String fileName;
  final int dateAddedMs;
  final int durationMs;
  final int sizeBytes;

  /// New filename pattern (current): `Capture-2026-05-18-14-32.wav`
  ///   prefix = `Capture`, suffix = `2026-05-18-14-32`, sep = `-`.
  static final RegExp _newFormat =
      RegExp(r'^(.+)-(\d{4}-\d{2}-\d{2}-\d{2}-\d{2})\.wav$');

  /// Legacy filename pattern: `capture_20260518_153000.wav`
  ///   prefix = `capture`, suffix = `20260518_153000`, sep = `_`.
  static final RegExp _legacyFormat =
      RegExp(r'^(.+)_(\d{8}_\d{6})\.wav$');

  /// The user-editable prefix of the filename (the part before the
  /// timestamp). For an unrecognised filename pattern the entire stem is
  /// returned and [timestampSuffix] is `null`.
  String get prefix {
    final match = _newFormat.firstMatch(fileName);
    if (match != null) return match.group(1)!;
    final legacy = _legacyFormat.firstMatch(fileName);
    if (legacy != null) return legacy.group(1)!;
    return _stripExtension(fileName);
  }

  /// The timestamp part of the filename — never user-editable. `null` for
  /// unrecognised filename patterns.
  String? get timestampSuffix {
    final match = _newFormat.firstMatch(fileName);
    if (match != null) return match.group(2);
    final legacy = _legacyFormat.firstMatch(fileName);
    if (legacy != null) return legacy.group(2);
    return null;
  }

  /// Separator between prefix and timestamp — `-` for new files, `_` for
  /// legacy ones. Used when building the new filename in [renamedTo].
  String get _separator =>
      _newFormat.hasMatch(fileName) ? '-' : '_';

  /// The wall-clock time this recording was captured. Prefers parsing the
  /// timestamp from the filename (preserves the original recording time even
  /// if the file has been touched or copied); falls back to MediaStore's
  /// `dateAdded` if the filename has no parseable timestamp.
  DateTime get recordedAt {
    final newMatch = _newFormat.firstMatch(fileName);
    if (newMatch != null) {
      final parts = newMatch.group(2)!.split('-');
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
        int.parse(parts[3]),
        int.parse(parts[4]),
      );
    }
    final legacyMatch = _legacyFormat.firstMatch(fileName);
    if (legacyMatch != null) {
      final stamp = legacyMatch.group(2)!; // 20260518_153000
      final date = stamp.substring(0, 8);
      final time = stamp.substring(9);
      return DateTime(
        int.parse(date.substring(0, 4)),
        int.parse(date.substring(4, 6)),
        int.parse(date.substring(6, 8)),
        int.parse(time.substring(0, 2)),
        int.parse(time.substring(2, 4)),
        int.parse(time.substring(4, 6)),
      );
    }
    return DateTime.fromMillisecondsSinceEpoch(dateAddedMs);
  }

  /// Audio duration of the recording. Prefers the MediaStore-reported
  /// duration; falls back to computing from WAV body size if MediaStore has
  /// not indexed the file yet (16 kHz mono 16-bit → 32 000 bytes/second).
  Duration get duration {
    if (durationMs > 0) {
      return Duration(milliseconds: durationMs);
    }
    const headerBytes = 44;
    const bytesPerSecond = 16000 * 1 * 16 ~/ 8;
    final pcmBytes = (sizeBytes - headerBytes).clamp(0, 1 << 53);
    final seconds = pcmBytes ~/ bytesPerSecond;
    return Duration(seconds: seconds);
  }

  /// Produces the new filename that would result from changing the prefix
  /// to [newPrefix] while preserving the timestamp suffix. The `.wav`
  /// extension and separator are preserved automatically.
  String renamedTo(String newPrefix) {
    final trimmed = newPrefix.trim();
    final safe = trimmed.isEmpty ? prefix : trimmed;
    final suffix = timestampSuffix;
    if (suffix == null) {
      // Unrecognised pattern — the user gets the whole filename to rename.
      return '$safe.wav';
    }
    return '$safe$_separator$suffix.wav';
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  factory Recording.fromMap(Map<dynamic, dynamic> map) => Recording(
        id: (map['id'] as num).toInt(),
        uri: map['uri'] as String,
        fileName: map['fileName'] as String,
        dateAddedMs: (map['dateAddedMs'] as num).toInt(),
        durationMs: (map['durationMs'] as num).toInt(),
        sizeBytes: (map['sizeBytes'] as num).toInt(),
      );
}
