import 'package:even_companion/services/walknav/region_model.dart';
import 'package:even_companion/services/walknav/region_service.dart';
import 'package:flutter/material.dart';

/// Walking regions on cartographer (plan region-sync, phase 3): list, pin,
/// rename, delete, and "Sync current location". The list is the server's,
/// cached for offline display.
class RegionsPage extends StatefulWidget {
  const RegionsPage({super.key});

  @override
  State<RegionsPage> createState() => _RegionsPageState();
}

class _RegionsPageState extends State<RegionsPage> {
  final RegionService _svc = RegionService.get;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_changed);
    _svc.init().then((_) => _svc.refresh());
  }

  @override
  void dispose() {
    _svc.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _toast(String? msg) {
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _syncHere() async {
    final name = await _askText(
      title: 'Sync current location',
      label: 'Name (optional)',
      hint: 'About 10 x 10 km around you',
      action: 'Sync',
    );
    if (name == null) return; // cancelled
    setState(() => _locating = true);
    final fix = await _svc.currentFix();
    if (!mounted) return;
    setState(() => _locating = false);
    if (fix == null) {
      _toast('No location fix. Check location is on and try again.');
      return;
    }
    _toast(await _svc.syncAt(fix.lat, fix.lon, name: name));
  }

  Future<void> _rename(WalkRegion r) async {
    final name = await _askText(
      title: 'Rename region',
      label: 'Name',
      initial: r.name,
      action: 'Save',
    );
    if (name == null || name.trim().isEmpty || name.trim() == r.name) return;
    _toast(await _svc.rename(r, name));
  }

  Future<void> _delete(WalkRegion r) async {
    if (r.pinned) {
      _toast('Unpin the region before deleting it.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${r.name}?'),
        content: const Text(
            'Walking routes here stop working until it is synced again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) _toast(await _svc.delete(r));
  }

  /// Returns null on cancel, possibly-empty text otherwise.
  Future<String?> _askText({
    required String title,
    required String label,
    required String action,
    String? hint,
    String initial = '',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: InputDecoration(labelText: label, helperText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(action)),
        ],
      ),
    );
  }

  String _subtitle(WalkRegion r) {
    final parts = <String>[formatBytes(r.sizeBytes)];
    final days = r.daysUntilExpiry(DateTime.now());
    if (r.pinned) {
      parts.add('pinned');
    } else if (days != null) {
      parts.add(days <= 0 ? 'expires at next sweep' : 'expires in ${days}d unless used');
    }
    final used = r.lastUsed;
    parts.add(used == null ? 'never used' : 'used ${_ago(used)}');
    return parts.join(' - ');
  }

  String _ago(DateTime t) {
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inDays >= 1) return '${d.inDays}d ago';
    if (d.inHours >= 1) return '${d.inHours}h ago';
    return '${d.inMinutes}m ago';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _locating || _svc.syncing;
    final muted = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(color: const Color(0xFF9AB7C8));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walking regions'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _svc.loading ? null : _svc.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: busy ? null : _syncHere,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.my_location),
        label: Text(_locating ? 'Locating...' : 'Sync current location'),
      ),
      body: RefreshIndicator(
        onRefresh: _svc.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            if (_svc.lastError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${_svc.lastError} Showing the copy from '
                  '${_svc.fetchedAt == null ? 'never' : _ago(_svc.fetchedAt!)}.',
                  style: muted?.copyWith(color: const Color(0xFFE0A458)),
                ),
              ),
            for (final j in _svc.pendingJobs)
              Card(
                child: ListTile(
                  leading: const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  title: Text(j.name),
                  subtitle: Text('Building: ${j.statusLabel}'),
                ),
              ),
            if (_svc.regions.isEmpty && !_svc.loading)
              Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Text('No regions yet.', style: muted),
              ),
            for (final r in _svc.regions)
              Card(
                child: ListTile(
                  title: Text(r.name),
                  subtitle: Text(_subtitle(r), style: muted),
                  leading: IconButton(
                    tooltip: r.pinned ? 'Unpin' : 'Pin',
                    icon: Icon(r.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                    onPressed: () async =>
                        _toast(await _svc.setPinned(r, !r.pinned)),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'rename' ? _rename(r) : _delete(r),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: !r.pinned,
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
