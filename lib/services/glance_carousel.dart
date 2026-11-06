/// Position and read-state of the Glance notification carousel.
///
/// Pure state, no IO, so the paging rules can be unit-tested. GlanceService
/// owns rendering, timers and the phone-side dismissals.
///
/// Paging model (2026-11-06, `single-tap-0x5x-adoption`):
/// - newest first; [advance] moves towards older items, [back] towards newer
/// - a dismissible item counts as read once it has been shown as an
///   interaction ([markSeen]); read items are dismissed on the phone only when
///   the carousel closes ([takeSeenKeys]), so [back] can return to them
/// - past the last item sits an end card ([atEnd])
class GlanceCarousel<T> {
  GlanceCarousel({
    required this.keyOf,
    required this.isDismissible,
    this.maxItems = 20,
  });

  final String Function(T item) keyOf;
  final bool Function(T item) isDismissible;
  final int maxItems;

  final List<T> _items = <T>[];
  final Set<String> _seenKeys = <String>{};
  int _index = 0;
  bool _atEnd = false;

  List<T> get items => List<T>.unmodifiable(_items);
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  int get currentIndex => _index;
  bool get atEnd => _atEnd;
  Set<String> get seenKeys => Set<String>.unmodifiable(_seenKeys);

  /// The item on screen, or null when empty or on the end card.
  T? get current => _items.isEmpty || _atEnd ? null : _items[_index];

  void hydrate(Iterable<T> items) {
    _items
      ..clear()
      ..addAll(items.take(maxItems));
    _seenKeys.removeWhere((key) => !_items.any((item) => keyOf(item) == key));
    _clampIndex();
  }

  /// Add or refresh [item] at the front. With [keepPosition] (carousel on
  /// screen) the user stays on the item they were reading; otherwise the
  /// carousel resets to the newest.
  void ingest(T item, {required bool keepPosition}) {
    final hadItems = _items.isNotEmpty;
    final key = keyOf(item);
    final existing = _items.indexWhere((i) => keyOf(i) == key);
    if (existing >= 0) {
      _items.removeAt(existing);
    }
    _items.insert(0, item);
    if (_items.length > maxItems) {
      final dropped = _items.sublist(maxItems).map(keyOf).toSet();
      _items.removeRange(maxItems, _items.length);
      _seenKeys.removeAll(dropped);
    }
    if (keepPosition && hadItems) {
      if (!_atEnd && existing == _index) {
        // The item being read was updated and moved to the front: follow it.
        _index = 0;
      } else if (existing < 0 || existing > _index) {
        _index++;
      }
      _clampIndex();
    } else {
      resetToStart();
    }
  }

  /// Remove [key]. Returns true if it was the item on screen.
  bool remove(String key) {
    _seenKeys.remove(key);
    final at = _items.indexWhere((i) => keyOf(i) == key);
    if (at < 0) {
      return false;
    }
    final wasCurrent = !_atEnd && at == _index;
    _items.removeAt(at);
    if (at < _index) {
      _index--;
    }
    _clampIndex();
    return wasCurrent;
  }

  void resetToStart() {
    _index = 0;
    _atEnd = false;
  }

  /// Record the item on screen as read, if it can be dismissed.
  void markSeen() {
    final item = current;
    if (item != null && isDismissible(item)) {
      _seenKeys.add(keyOf(item));
    }
  }

  /// Right tap / tilt-up advance. A dismissible item not yet read (an
  /// auto-pop the user then tilted up to) is claimed rather than skipped.
  /// Past the last item, moves onto the end card.
  void advance() {
    final item = current;
    if (item == null) {
      return;
    }
    if (isDismissible(item) && !_seenKeys.contains(keyOf(item))) {
      return;
    }
    if (_index < _items.length - 1) {
      _index++;
    } else {
      _atEnd = true;
    }
  }

  /// Left tap. Returns false if already at the newest item.
  bool back() {
    if (_atEnd) {
      _atEnd = false;
      _clampIndex();
      return _items.isNotEmpty;
    }
    if (_index > 0) {
      _index--;
      return true;
    }
    return false;
  }

  /// Hand over the read keys for dismissal and forget them.
  List<String> takeSeenKeys() {
    final keys = _seenKeys.toList();
    _seenKeys.clear();
    return keys;
  }

  /// Forget read state without dismissing anything.
  void clearSeen() => _seenKeys.clear();

  void _clampIndex() {
    if (_items.isEmpty) {
      _index = 0;
      _atEnd = false;
    } else if (_index >= _items.length) {
      _index = _items.length - 1;
    } else if (_index < 0) {
      _index = 0;
    }
  }
}
