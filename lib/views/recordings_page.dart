import 'package:even_companion/models/recording.dart';
import 'package:even_companion/services/recordings_service.dart';
import 'package:flutter/material.dart';

/// A flat, filesystem-backed list of audio recordings captured via the
/// glasses (tilt-up → record). No local database — every visit re-queries
/// MediaStore so the list always reflects what is on disk.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  List<Recording> _recordings = const <Recording>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final items = await RecordingsService.get.list();
    if (!mounted) return;
    setState(() {
      _recordings = items;
      _loading = false;
    });
  }

  String _formatDate(DateTime dt) {
    final months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} $hh:$mm';
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    if (totalSeconds <= 0) return '—';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    }
    return '${seconds}s';
  }

  Future<void> _openRenameDialog(Recording recording) async {
    final controller = TextEditingController(text: recording.prefix);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Rename recording'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Change the prefix only — the timestamp suffix is preserved.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Prefix',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) => Navigator.of(ctx).pop(value),
              ),
              const SizedBox(height: 8),
              if (recording.timestampSuffix != null)
                Text(
                  'Will save as: ${recording.renamedTo(controller.text.isEmpty ? recording.prefix : controller.text)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (newName == null || newName.trim().isEmpty) return;
    final result = await RecordingsService.get.renamePrefix(recording, newName);
    if (!mounted) return;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rename failed')),
      );
      return;
    }
    await _reload();
  }

  Future<void> _confirmDelete(Recording recording) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete recording?'),
          content: Text(
            '${recording.fileName} will be permanently removed from this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final deleted = await RecordingsService.get.delete(recording);
    if (!mounted) return;
    if (!deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delete failed')),
      );
      return;
    }
    await _reload();
  }

  Future<void> _share(Recording recording) async {
    final ok = await RecordingsService.get.share(recording);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Share failed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _recordings.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _recordings.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _buildRow(_recordings[index]),
                  ),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mic_none,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No recordings yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Switch to Capture mode and tilt your head up to start recording.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(Recording recording) {
    return ListTile(
      title: Text(recording.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_formatDate(recording.recordedAt)} · ${_formatDuration(recording.duration)}',
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'rename':
              _openRenameDialog(recording);
              break;
            case 'share':
              _share(recording);
              break;
            case 'delete':
              _confirmDelete(recording);
              break;
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'share', child: Text('Share / export')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
