import 'package:even_companion/services/glance_carousel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test item: key plus whether Glance may dismiss it on the phone.
class _N {
  const _N(this.key, {this.dismissible = true});
  final String key;
  final bool dismissible;
}

GlanceCarousel<_N> _carousel(List<_N> items, {int maxItems = 20}) {
  final c = GlanceCarousel<_N>(
    keyOf: (n) => n.key,
    isDismissible: (n) => n.dismissible,
    maxItems: maxItems,
  );
  c.hydrate(items);
  return c;
}

void main() {
  group('advance and back', () {
    test('right through the list, end card, then back', () {
      final c = _carousel(const [_N('a'), _N('b'), _N('c')]);
      c.markSeen();
      expect(c.current!.key, 'a');

      c.advance();
      c.markSeen();
      expect(c.current!.key, 'b');

      c.advance();
      c.markSeen();
      expect(c.current!.key, 'c');

      c.advance();
      expect(c.atEnd, isTrue);
      expect(c.current, isNull);

      expect(c.back(), isTrue);
      expect(c.atEnd, isFalse);
      expect(c.current!.key, 'c');

      expect(c.back(), isTrue);
      expect(c.current!.key, 'b');
      expect(c.back(), isTrue);
      expect(c.back(), isFalse, reason: 'already at the newest');
      expect(c.current!.key, 'a');
    });

    test('an unread dismissible item is claimed before advancing', () {
      // Auto-pop shows "a" without marking it read; the first tilt-up claims
      // it rather than skipping past something the user has not read.
      final c = _carousel(const [_N('a'), _N('b')]);
      c.advance();
      expect(c.current!.key, 'a');
      c.markSeen();
      c.advance();
      expect(c.current!.key, 'b');
    });

    test('protected items are never marked read and do not block advance', () {
      final c = _carousel(const [_N('p', dismissible: false), _N('b')]);
      c.markSeen();
      expect(c.seenKeys, isEmpty);
      c.advance();
      expect(c.current!.key, 'b');
    });

    test('empty carousel is inert', () {
      final c = _carousel(const []);
      c.advance();
      c.markSeen();
      expect(c.current, isNull);
      expect(c.atEnd, isFalse);
      expect(c.back(), isFalse);
    });

    test('markSeen on the end card records nothing', () {
      final c = _carousel(const [_N('a', dismissible: false)]);
      c.advance();
      expect(c.atEnd, isTrue);
      c.markSeen();
      expect(c.seenKeys, isEmpty);
    });
  });

  group('deferred dismissal', () {
    test('everything read in the session is handed over once, including '
        'items gone back past', () {
      final c = _carousel(const [_N('a'), _N('b'), _N('c')]);
      c.markSeen();
      c.advance();
      c.markSeen();
      c.back();
      c.markSeen();
      expect(c.takeSeenKeys(), unorderedEquals(['a', 'b']));
      expect(c.takeSeenKeys(), isEmpty);
    });

    test('clearSeen forgets read state without handing it over', () {
      final c = _carousel(const [_N('a')]);
      c.markSeen();
      c.clearSeen();
      expect(c.takeSeenKeys(), isEmpty);
    });

    test('removing an item drops it from the read set', () {
      final c = _carousel(const [_N('a'), _N('b')]);
      c.markSeen();
      c.remove('a');
      expect(c.takeSeenKeys(), isEmpty);
    });
  });

  group('ingest', () {
    test('while visible, the user stays on the item being read', () {
      final c = _carousel(const [_N('a'), _N('b')]);
      c.markSeen();
      c.advance();
      expect(c.current!.key, 'b');
      c.ingest(const _N('new'), keepPosition: true);
      expect(c.current!.key, 'b');
      expect(c.items.first.key, 'new');
    });

    test('while visible, an update to an item ahead moves it to the front '
        'without moving the user', () {
      final c = _carousel(const [_N('a'), _N('b'), _N('c')]);
      c.markSeen();
      c.advance(); // on b
      c.ingest(const _N('a'), keepPosition: true);
      expect(c.current!.key, 'b');
      c.ingest(const _N('c'), keepPosition: true);
      expect(c.current!.key, 'b');
    });

    test('while visible, an update to the item being read follows it', () {
      final c = _carousel(const [_N('a'), _N('b'), _N('c')]);
      c.markSeen();
      c.advance(); // on b
      c.ingest(const _N('b'), keepPosition: true);
      expect(c.current!.key, 'b');
      expect(c.currentIndex, 0);
    });

    test('while not visible, resets to the newest', () {
      final c = _carousel(const [_N('a'), _N('b')]);
      c.markSeen();
      c.advance();
      c.ingest(const _N('new'), keepPosition: false);
      expect(c.current!.key, 'new');
      expect(c.atEnd, isFalse);
    });

    test('into an empty visible carousel shows the new item', () {
      final c = _carousel(const []);
      c.ingest(const _N('new'), keepPosition: true);
      expect(c.current!.key, 'new');
    });

    test('caps at maxItems and forgets read state for dropped items', () {
      final c = _carousel(const [_N('a'), _N('b')], maxItems: 2);
      c.advance();
      c.markSeen(); // a
      c.advance();
      c.markSeen(); // b
      c.ingest(const _N('new'), keepPosition: false);
      expect(c.items.map((n) => n.key), ['new', 'a']);
      expect(c.takeSeenKeys(), ['a']);
    });
  });

  group('remove', () {
    test('reports whether the removed item was on screen', () {
      final c = _carousel(const [_N('a'), _N('b'), _N('c')]);
      c.markSeen();
      c.advance(); // on b
      expect(c.remove('c'), isFalse);
      expect(c.remove('b'), isTrue);
    });

    test('removing an item before the current one keeps the user in place',
        () {
      final c = _carousel(const [_N('a'), _N('b'), _N('c')]);
      c.markSeen();
      c.advance();
      c.markSeen();
      c.advance(); // on c
      c.remove('a');
      expect(c.current!.key, 'c');
    });

    test('removing the last item while on it clamps to the new last', () {
      final c = _carousel(const [_N('a'), _N('b')]);
      c.markSeen();
      c.advance(); // on b
      c.remove('b');
      expect(c.current!.key, 'a');
    });

    test('removing everything leaves an empty, reset carousel', () {
      final c = _carousel(const [_N('a')]);
      c.advance();
      c.markSeen();
      c.advance(); // end card
      c.remove('a');
      expect(c.isEmpty, isTrue);
      expect(c.atEnd, isFalse);
      expect(c.current, isNull);
    });
  });
}
