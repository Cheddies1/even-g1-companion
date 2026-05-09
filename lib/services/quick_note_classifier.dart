/// Keyword-based category classifier for QuickNote transcripts.
///
/// Used as a fallback when the LLM tidy service is unavailable or returns an
/// unparseable response. Patterns are checked in priority order:
/// shopping first, then todo, then the default 'notes'.
///
/// Case-insensitive. Returns one of 'shopping', 'todo', or 'notes'.
class QuickNoteClassifier {
  QuickNoteClassifier._();

  // Checked first: shopping intent patterns.
  static final _shoppingPattern = RegExp(
    r'\b(buy|purchase|pick up|shopping list|grocery|groceries|'
    r'get some|get more|need more|add .+ to cart)\b',
    caseSensitive: false,
  );

  // Checked second: to-do / action-item patterns.
  // Note: the apostrophe in "don't" is matched via a character class to avoid
  // embedding an apostrophe literal inside a raw string.
  static final _todoPattern = RegExp(
    r'\b(remember to|need to|don' "'" r't forget|to do list|to-do list|'
    r'should|must|have to|make sure|schedule|book|call|email|'
    r'fix|clean|organise|organize)\b',
    caseSensitive: false,
  );

  /// Classifies [text] into 'shopping', 'todo', or 'notes'.
  ///
  /// Shopping patterns are tested before todo patterns so that a note like
  /// "I need to buy milk" lands in 'shopping' rather than 'todo'.
  static String classify(String text) {
    if (_shoppingPattern.hasMatch(text)) return 'shopping';
    if (_todoPattern.hasMatch(text)) return 'todo';
    return 'notes';
  }
}
