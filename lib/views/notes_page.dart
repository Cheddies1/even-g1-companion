import 'package:demo_ai_even/models/note.dart';
import 'package:demo_ai_even/services/notes_store.dart';
import 'package:flutter/material.dart';

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final Set<int> _expandedNoteIds = {};

  @override
  void initState() {
    super.initState();
    NotesStore.get.addListener(_refresh);
  }

  @override
  void dispose() {
    NotesStore.get.removeListener(_refresh);
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

    // Older than a week: show local date.
    final local = created.toLocal();
    return '${local.day}/${local.month}/${local.year}';
  }

  // ---------------------------------------------------------------------------
  // Reorder logic
  // ---------------------------------------------------------------------------

  /// Computes the new [sortOrder] for the item moved to [newIndex] within
  /// [notes] (already in DESC sort-order, largest = top).
  ///
  /// [notes] is the list *after* the item has been removed from its old
  /// position and *before* it is inserted at [newIndex].
  double _computeSortOrder(List<Note> notes, int newIndex) {
    // Top of the list.
    if (newIndex == 0) {
      return notes.isEmpty ? 1000.0 : notes[0].sortOrder + 1.0;
    }
    // Bottom of the list.
    if (newIndex >= notes.length) {
      return notes.last.sortOrder - 1.0;
    }
    // Middle: fractional midpoint between the two neighbours.
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
    // Assign even integer spacing in DESC order (top note gets the highest value).
    final count = notes.length;
    for (int i = 0; i < count; i++) {
      final newOrder = (count - i) * 1000.0;
      if (notes[i].sortOrder != newOrder) {
        await NotesStore.get.reorder(id: notes[i].id, sortOrder: newOrder);
      }
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final notes = List<Note>.from(NotesStore.get.notes);
    if (oldIndex < 0 || oldIndex >= notes.length) return;

    // ReorderableListView gives newIndex *before* the item is removed, so when
    // dragging downward the effective insertion index is one lower.
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;

    final moved = notes.removeAt(oldIndex);
    final newOrder = _computeSortOrder(notes, newIndex);

    await NotesStore.get.reorder(id: moved.id, sortOrder: newOrder);

    // After the store refresh, check whether the gap has collapsed.
    final refreshed = NotesStore.get.notes;
    if (_needsRebalance(refreshed)) {
      await _rebalanceAll(List<Note>.from(refreshed));
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
            // Re-insert with the same sort order and timestamps so it returns
            // to approximately the same position.
            await NotesStore.get.insert(
              createdAt: note.createdAt,
              transcriptRaw: note.transcriptRaw,
              transcriptClean: note.transcriptClean,
              status: note.status,
              sortOrder: note.sortOrder,
              noteUid: note.noteUid,
              error: note.error,
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
                    // Timestamp + expand hint.
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
                  ],
                ),
                // Expanded view: raw vs clean comparison.
                if (isExpanded && canExpand) ...[
                  const SizedBox(height: 12),
                  Divider(color: const Color(0xFF1D262E), height: 1),
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
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final notes = NotesStore.get.notes;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
      ),
      body: notes.isEmpty
          ? _buildEmptyState(theme)
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: notes.length,
              onReorder: _onReorder,
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
            ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mic_none,
              size: 48,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No notes yet',
              style: theme.textTheme.titleMedium?.copyWith(
                color: const Color(0xFF7C8C99),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Long-press the right temple to record one.',
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
}
