import 'dart:convert';

import 'package:even_companion/services/walknav/nav_bundle.dart';

/// Which tile is on the glasses, and when to move to the next.
///
/// Contract rules (docs/cartographer-contract.md): choose the next tile
/// before leaving the old interval; keep the old one on screen through the
/// overlap until the new pair of maps has finished transferring; while
/// swapping, hold the marker at the old tile's end rather than extrapolate.
/// A panoramic swap takes ~2.4 s (gate A), about 3 m of walking, well inside
/// the ~50 m overlap.
class TileSelector {
  TileSelector(this.tiles) : assert(tiles.isNotEmpty);

  final List<NavTile> tiles;

  int? _shown;
  int? _pending;

  /// Tile currently on the glasses, or null before the first transfer.
  int? get shownIndex => _shown;
  NavTile? get shown => _shown == null ? null : tiles[_shown!];
  int? get pendingIndex => _pending;

  /// The most-forward tile whose interval contains [progressM]. Moving to it
  /// as soon as it starts puts the swap at the beginning of the overlap.
  int desiredIndex(double progressM) {
    var best = 0;
    for (var i = 0; i < tiles.length; i++) {
      if (tiles[i].startM <= progressM) best = i;
    }
    return best;
  }

  /// A tile to start transferring now, or null if none is needed.
  int? nextTransfer(double progressM) {
    if (_pending != null) return null;
    final want = desiredIndex(progressM);
    return want == _shown ? null : want;
  }

  void beginTransfer(int index) => _pending = index;

  void completeTransfer(int index) {
    if (_pending == index) _pending = null;
    _shown = index;
  }

  void abortTransfer() => _pending = null;

  /// Progress to draw the marker at on the shown tile: held inside its
  /// interval, never extrapolated past it.
  double markerProgress(double progressM) {
    final t = shown;
    if (t == null) return progressM;
    return progressM.clamp(t.startM, t.endM).toDouble();
  }
}

/// TRIP_STATUS string formatting. Byte caps are hard: the firmware aborts the
/// whole packet if a field overflows (24/24/64/24/24 including the NUL).
class TripText {
  static const int shortFieldBytes = 23;
  static const int roadFieldBytes = 63;

  /// Assumed walking pace for the remaining-time estimate.
  static const double walkingMps = 1.3;

  static String distance(double metres) {
    final m = metres < 0 ? 0.0 : metres;
    if (m < 1000) {
      final rounded = m < 100 ? (m / 5).round() * 5 : (m / 10).round() * 10;
      return '$rounded m';
    }
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  static String remainingTime(double metres) {
    final minutes = (metres / walkingMps / 60).ceil();
    return '${minutes < 1 ? 1 : minutes} min';
  }

  static String speed(double? mps) {
    if (mps == null || mps < 0) return '';
    return '${(mps * 3.6).toStringAsFixed(1)} km/h';
  }

  /// Longest prefix of [s] that fits [maxBytes] of UTF-8, cut on a character
  /// boundary.
  static String clampUtf8(String s, int maxBytes) {
    final bytes = utf8.encode(s);
    if (bytes.length <= maxBytes) return s;
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end));
  }
}
