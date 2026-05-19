import 'package:even_companion/models/note.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/notes_store.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Category metadata
// ---------------------------------------------------------------------------

class _CategoryMeta {
  const _CategoryMeta({
    required this.key,
    required this.label,
    required this.icon,
    required this.emptyTitle,
    required this.emptyHint,
  });

  final String key;
  final String label;
  final IconData icon;
  final String emptyTitle;
  final String emptyHint;
}

const _categories = <_CategoryMeta>[
  _CategoryMeta(
    key: 'shopping',
    label: 'Shopping',
    icon: Icons.shopping_cart_outlined,
    emptyTitle: 'No shopping items',
    emptyHint: "Tap + or say 'buy' to add an item",
  ),
  _CategoryMeta(
    key: 'todo',
    label: 'To Do',
    icon: Icons.check_circle_outline,
    emptyTitle: 'No tasks',
    emptyHint: "Tap + or say 'remember to' to add a task",
  ),
  _CategoryMeta(
    key: 'notes',
    label: 'Notes',
    icon: Icons.note_outlined,
    emptyTitle: 'No notes yet',
    emptyHint: 'Tap + or long-press the right temple to add a note',
  ),
];

// ---------------------------------------------------------------------------
// NotesPage
// ---------------------------------------------------------------------------

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> with TickerProviderStateMixin {
  late final TabController _tabController;
  final Set<int> _expandedNoteIds = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _categories.length, vsync: this);
    NotesStore.get.addListener(_refresh);
  }

  @override
  void dispose() {
    NotesStore.get.removeListener(_refresh);
    _tabController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Relative timestamp helper
  // ---------------------------------------------------------------------------

  String _formatTimestamp(Note note) {
    final now = DateTime.now().toUtc();
    final created = note.createdAtUtc;
    final diff = now.difference(created);

    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';

    final local = created.toLocal();
    return '${local.day}/${local.month}/${local.year}';
  }

  // ---------------------------------------------------------------------------
  // Reorder logic (category-scoped)
  // ---------------------------------------------------------------------------

  /// Computes the new [sortOrder] for the item moved to [newIndex] within
  /// [notes] (already in DESC sort-order, largest = top).
  ///
  /// [notes] is the list *after* the item has been removed from its old
  /// position and *before* it is inserted at [newIndex].
  double _computeSortOrder(List<Note> notes, int newIndex) {
    if (newIndex == 0) {
      return notes.isEmpty ? 1000.0 : notes[0].sortOrder + 1.0;
    }
    if (newIndex >= notes.length) {
      return notes.last.sortOrder - 1.0;
    }
    return (notes[newIndex - 1].sortOrder + notes[newIndex].sortOrder) / 2.0;
  }

  bool _needsRebalance(List<Note> notes) {
    for (int i = 0; i < notes.length - 1; i++) {
      if ((notes[i].sortOrder - notes[i + 1].sortOrder).abs() < 0.001) {
        return true;
      }
    }
    return false;
  }

  Future<void> _rebalanceAll(List<Note> notes) async {
    final count = notes.length;
    for (int i = 0; i < count; i++) {
      final newOrder = (count - i) * 1000.0;
      if (notes[i].sortOrder != newOrder) {
        await NotesStore.get.reorder(id: notes[i].id, sortOrder: newOrder);
      }
    }
  }

  /// Handles reorder within a single category tab. Indices are relative to
  /// the filtered list, not the full [NotesStore.get.notes] list.
  Future<void> _onReorder(
    String category,
    int oldIndex,
    int newIndex,
  ) async {
    final filtered = NotesStore.get.notes
        .where((n) => n.category == category)
        .toList(growable: true);

    if (oldIndex < 0 || oldIndex >= filtered.length) return;

    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;

    final moved = filtered.removeAt(oldIndex);
    final newOrder = _computeSortOrder(filtered, newIndex);

    await NotesStore.get.reorder(id: moved.id, sortOrder: newOrder);

    final refreshedFiltered = NotesStore.get.notes
        .where((n) => n.category == category)
        .toList(growable: false);

    if (_needsRebalance(refreshedFiltered)) {
      await _rebalanceAll(List<Note>.from(refreshedFiltered));
    }
  }

  // ---------------------------------------------------------------------------
  // Delete with undo snackbar
  // ---------------------------------------------------------------------------

  Future<void> _deleteNote(Note note) async {
    await NotesStore.get.delete(id: note.id);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Note deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await NotesStore.get.insert(
              createdAt: note.createdAt,
              transcriptRaw: note.transcriptRaw,
              transcriptClean: note.transcriptClean,
              status: note.status,
              sortOrder: note.sortOrder,
              noteUid: note.noteUid,
              error: note.error,
              category: note.category,
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Toggle done/active
  // ---------------------------------------------------------------------------

  Future<void> _toggleStatus(Note note) async {
    final next = note.status == 'done' ? 'active' : 'done';
    await NotesStore.get.updateStatus(id: note.id, status: next);
  }

  // ---------------------------------------------------------------------------
  // Move-to-category bottom sheet
  // ---------------------------------------------------------------------------

  Future<void> _showMovePicker(Note note) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF10161C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    'Move to...',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: const Color(0xFF7C8C99),
                        ),
                  ),
                ),
                ..._categories.map((meta) {
                  final isCurrent = note.category == meta.key;
                  return ListTile(
                    leading: Icon(
                      meta.icon,
                      color: isCurrent
                          ? const Color(0xFF2E8A7A)
                          : const Color(0xFF9AB7C8),
                    ),
                    title: Text(
                      meta.label,
                      style: TextStyle(
                        color: isCurrent
                            ? const Color(0xFF2E8A7A)
                            : const Color(0xFFD4DDE5),
                      ),
                    ),
                    trailing: isCurrent
                        ? const Icon(
                            Icons.check,
                            size: 18,
                            color: Color(0xFF2E8A7A),
                          )
                        : null,
                    onTap: isCurrent
                        ? null
                        : () async {
                            Navigator.of(sheetContext).pop();
                            await NotesStore.get.updateCategory(
                              id: note.id,
                              category: meta.key,
                            );
                          },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Note tile
  // ---------------------------------------------------------------------------

  String _displayText(Note note) {
    if (note.transcriptClean != null) return note.transcriptClean!;
    if (note.transcriptRaw != null) return note.transcriptRaw!;
    return 'Transcribing...';
  }

  bool _canExpand(Note note) =>
      note.transcriptRaw != null &&
      note.transcriptClean != null &&
      note.transcriptRaw != note.transcriptClean;

  Widget _buildNoteTile(BuildContext context, Note note) {
    final theme = Theme.of(context);
    final isDone = note.status == 'done';
    final isExpanded = _expandedNoteIds.contains(note.id);
    final displayText = _displayText(note);
    final canExpand = _canExpand(note);

    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: isDone ? const Color(0xFF7C8C99) : const Color(0xFFD4DDE5),
      decoration: isDone ? TextDecoration.lineThrough : null,
    );

    return Dismissible(
      key: ValueKey('dismiss_${note.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red.shade900,
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _deleteNote(note),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF141A20),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF28313A)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: canExpand
              ? () {
                  setState(() {
                    if (isExpanded) {
                      _expandedNoteIds.remove(note.id);
                    } else {
                      _expandedNoteIds.add(note.id);
                    }
                  });
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Status toggle icon.
                    GestureDetector(
                      onTap: () => _toggleStatus(note),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 10, top: 2),
                        child: Icon(
                          isDone
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 20,
                          color: isDone
                              ? const Color(0xFF2E8A7A)
                              : const Color(0xFF7C8C99),
                        ),
                      ),
                    ),
                    // Main text content.
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(displayText, style: titleStyle),
                          if (note.error != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              note.error!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.red.shade300,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Timestamp + expand hint + move button.
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatTimestamp(note),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: const Color(0xFF7C8C99),
                          ),
                        ),
                        if (canExpand) ...[
                          const SizedBox(height: 4),
                          Icon(
                            isExpanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 16,
                            color: const Color(0xFF7C8C99),
                          ),
                        ],
                      ],
                    ),
                    // Category-move button — separate from expand column so the
                    // tap target is always reachable regardless of expand state.
                    GestureDetector(
                      onTap: () => _showMovePicker(note),
                      child: const Padding(
                        padding: EdgeInsets.only(left: 6, top: 2),
                        child: Icon(
                          Icons.more_vert,
                          size: 18,
                          color: Color(0xFF7C8C99),
                        ),
                      ),
                    ),
                  ],
                ),
                // Expanded view: raw vs clean comparison.
                if (isExpanded && canExpand) ...[
                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFF1D262E), height: 1),
                  const SizedBox(height: 12),
                  _buildTranscriptRow(
                    context,
                    label: 'Raw',
                    text: note.transcriptRaw!,
                  ),
                  const SizedBox(height: 8),
                  _buildTranscriptRow(
                    context,
                    label: 'Clean',
                    text: note.transcriptClean!,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTranscriptRow(
    BuildContext context, {
    required String label,
    required String text,
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 46,
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: const Color(0xFF7C8C99),
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF9AB7C8),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Per-category list (shared by all three TabBarView children)
  // ---------------------------------------------------------------------------

  Widget _buildCategoryList(BuildContext context, _CategoryMeta meta) {
    final notes = NotesStore.get.notes
        .where((n) => n.category == meta.key)
        .toList(growable: false);

    if (notes.isEmpty) {
      return _buildEmptyState(Theme.of(context), meta);
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: notes.length,
      onReorder: (oldIndex, newIndex) =>
          _onReorder(meta.key, oldIndex, newIndex),
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        child: child,
      ),
      itemBuilder: (context, index) {
        final note = notes[index];
        return KeyedSubtree(
          key: ValueKey(note.id),
          child: _buildNoteTile(context, note),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Empty state (per category)
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState(ThemeData theme, _CategoryMeta meta) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              meta.icon,
              size: 48,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              meta.emptyTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                color: const Color(0xFF7C8C99),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              meta.emptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF7C8C99),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Manual-add bottom sheet
  // ---------------------------------------------------------------------------

  Future<void> _showNewEntrySheet() async {
    final initialCategory = _categories[_tabController.index].key;

    final savedCategory = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF10161C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) =>
          _NewEntrySheet(initialCategory: initialCategory),
    );

    if (!mounted || savedCategory == null) return;

    final targetIndex = _categories.indexWhere((m) => m.key == savedCategory);
    if (targetIndex != -1 && targetIndex != _tabController.index) {
      _tabController.animateTo(targetIndex);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final allNotes = NotesStore.get.notes;

    int activeCount(String categoryKey) => allNotes
        .where((n) => n.category == categoryKey && n.status != 'done')
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        bottom: TabBar(
          controller: _tabController,
          tabs: _categories.map((meta) {
            final count = activeCount(meta.key);
            return Tab(
              icon: Icon(meta.icon),
              text: count > 0 ? '${meta.label} ($count)' : meta.label,
            );
          }).toList(growable: false),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: _categories
            .map((meta) => _buildCategoryList(context, meta))
            .toList(growable: false),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewEntrySheet,
        tooltip: 'New entry',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _NewEntrySheet — manual-add bottom sheet
// ---------------------------------------------------------------------------

class _NewEntrySheet extends StatefulWidget {
  const _NewEntrySheet({required this.initialCategory});

  final String initialCategory;

  @override
  State<_NewEntrySheet> createState() => _NewEntrySheetState();
}

class _NewEntrySheetState extends State<_NewEntrySheet> {
  late final TextEditingController _textController;
  late String _selectedCategory;
  bool _saveEnabled = false;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory;
    _textController = TextEditingController();
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasContent = _textController.text.trim().isNotEmpty;
    if (hasContent != _saveEnabled) {
      setState(() => _saveEnabled = hasContent);
    }
  }

  Future<void> _save() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final createdAt = DateTime.now().millisecondsSinceEpoch;
    await NotesStore.get.insert(
      createdAt: createdAt,
      transcriptRaw: null,
      transcriptClean: text,
      status: 'active',
      sortOrder: createdAt.toDouble(),
      noteUid: null,
      category: _selectedCategory,
      error: null,
    );

    AppLog.info(
      'notes_manual_add: inserted category=$_selectedCategory',
      tag: 'notes_manual_add',
    );

    if (mounted) Navigator.of(context).pop(_selectedCategory);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'New entry',
              style: theme.textTheme.titleSmall?.copyWith(
                color: const Color(0xFF7C8C99),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: _categories.map((meta) {
                final isSelected = meta.key == _selectedCategory;
                return ChoiceChip(
                  label: Text(meta.label),
                  selected: isSelected,
                  onSelected: (_) =>
                      setState(() => _selectedCategory = meta.key),
                  selectedColor: const Color(0xFF2E8A7A),
                  backgroundColor: const Color(0xFF1D262E),
                  labelStyle: TextStyle(
                    color: isSelected
                        ? const Color(0xFFD4DDE5)
                        : const Color(0xFF9AB7C8),
                  ),
                  side: BorderSide(
                    color: isSelected
                        ? const Color(0xFF2E8A7A)
                        : const Color(0xFF28313A),
                  ),
                  showCheckmark: false,
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              autofocus: true,
              maxLines: null,
              minLines: 1,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFD4DDE5),
              ),
              decoration: InputDecoration(
                hintText: 'Type your note…',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF7C8C99),
                ),
                filled: true,
                fillColor: const Color(0xFF1D262E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF28313A)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF28313A)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF2E8A7A)),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF7C8C99),
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saveEnabled ? _save : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2E8A7A),
                    disabledBackgroundColor: const Color(0xFF1D262E),
                    foregroundColor: const Color(0xFFD4DDE5),
                    disabledForegroundColor: const Color(0xFF7C8C99),
                  ),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
