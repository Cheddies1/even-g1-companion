import 'package:demo_ai_even/models/companion_notification.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/services/text_service.dart';

class NavigateService {
  NavigateService._();

  static NavigateService? _instance;
  static NavigateService get get => _instance ??= NavigateService._();

  CompanionNotification? _latestInstruction;
  bool _isVisible = false;
  bool _showingDetail = false;

  CompanionNotification? get latestInstruction => _latestInstruction;
  bool get hasInstruction => _latestInstruction != null;
  bool get isVisible => _isVisible;
  bool get isShowingDetail => _showingDetail;

  Future<void> ingestNotification(CompanionNotification notification) async {
    if (!notification.isGoogleMaps) {
      return;
    }
    _latestInstruction = notification;
    final snapshot = _buildSnapshot(notification);
    print(
      '${DateTime.now()} Navigate: payload title="${notification.title}" text="${notification.text}" bigText="${notification.bigText}"',
    );
    print(
      '${DateTime.now()} Navigate: instruction updated -> ${snapshot.primaryInstruction}',
    );
  }

  Future<void> showLatest() async {
    _showingDetail = false;
    await _renderCurrentView();
  }

  Future<void> showDetail() async {
    _showingDetail = true;
    await _renderCurrentView();
  }

  Future<void> returnToPrimary() async {
    _showingDetail = false;
    await _renderCurrentView();
  }

  Future<void> refreshVisibleView() async {
    if (!_isVisible) {
      return;
    }
    await _renderCurrentView();
  }

  Future<bool> clearIfMatches({
    required String key,
    required String packageName,
  }) async {
    final latest = _latestInstruction;
    if (latest == null || !latest.isGoogleMaps) {
      return false;
    }
    final samePackage = packageName.contains('com.google.android.apps.maps');
    final sameKey = latest.key == key;
    if (!samePackage && !sameKey) {
      return false;
    }
    _latestInstruction = null;
    _showingDetail = false;
    await close();
    print('${DateTime.now()} Navigate: cleared after notification removal');
    return true;
  }

  Future<void> close() async {
    if (!_isVisible) {
      return;
    }
    _isVisible = false;
    _showingDetail = false;
    await TextService.get.stopTextSendingByOS();
    await Proto.exit();
    print('${DateTime.now()} Navigate: closed');
  }

  Future<void> leaveMode() async {
    await close();
  }

  Future<void> _renderCurrentView() async {
    final notification = _latestInstruction;
    final text = notification == null
        ? 'Start navigation in Google Maps'
        : _showingDetail
            ? _buildSnapshot(notification).detailDisplay
            : _buildSnapshot(notification).primaryDisplay;
    _isVisible = true;
    await TextService.get.startSendText(text);
    print(
      '${DateTime.now()} Navigate: render -> ${_showingDetail ? 'detail' : 'primary'}',
    );
  }

  _NavigateSnapshot _buildSnapshot(CompanionNotification notification) {
    final rawFields = <String>[
      notification.title,
      notification.text,
      notification.bigText,
      notification.message,
    ];
    final candidates = rawFields
        .map(_normalizeField)
        .where((field) => field.isNotEmpty)
        .toList();

    final primaryInstruction =
        candidates.firstWhere(_looksLikeNavigationInstruction, orElse: () {
      return candidates.firstWhere(
        (field) => !_looksLikeNavigationMeta(field),
        orElse: () => notification.message,
      );
    });

    final directionCue = _inferDirectionCue(primaryInstruction);
    final detailLines = <String>[];

    if (directionCue != null) {
      detailLines.add('Direction: $directionCue');
    }

    for (final field in candidates) {
      if (field == primaryInstruction) {
        continue;
      }
      final line = _formatDetailLine(field);
      if (line != null && !detailLines.contains(line)) {
        detailLines.add(line);
      }
    }

    final currentStreet = _extractStreetName(primaryInstruction);
    if (currentStreet != null) {
      final streetLine = 'Current street: $currentStreet';
      if (!detailLines.contains(streetLine)) {
        detailLines.add(streetLine);
      }
    }

    return _NavigateSnapshot(
      primaryInstruction: primaryInstruction,
      directionCue: directionCue,
      detailLines: detailLines,
    );
  }

  String _normalizeField(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized.toLowerCase() == 'google maps') {
      return '';
    }
    return normalized;
  }

  bool _looksLikeNavigationInstruction(String value) {
    final normalized = value.toLowerCase();
    return RegExp(
      r'\b(turn|head|continue|keep|take|merge|exit|u-turn|uturn|arrive|destination|roundabout|slight)\b',
    ).hasMatch(normalized);
  }

  bool _looksLikeNavigationMeta(String value) {
    final normalized = value.toLowerCase();
    if (normalized == 'starting navigation') {
      return true;
    }
    return RegExp(
      r'\b(min|mins|hour|hours|km|m|mi|eta|arrive|remaining)\b',
    ).hasMatch(normalized);
  }

  String? _inferDirectionCue(String instruction) {
    final normalized = instruction.toLowerCase();
    if (normalized.contains('u-turn') || normalized.contains('uturn')) {
      return 'U-turn';
    }
    if (normalized.contains('slight left')) {
      return '<~';
    }
    if (normalized.contains('slight right')) {
      return '~>';
    }
    if (normalized.contains('left')) {
      return '<-';
    }
    if (normalized.contains('right')) {
      return '->';
    }
    if (normalized.contains('roundabout')) {
      return 'Roundabout';
    }
    if (normalized.contains('continue') || normalized.contains('head')) {
      return '^';
    }
    if (normalized.contains('merge')) {
      return 'Merge';
    }
    return null;
  }

  String? _formatDetailLine(String value) {
    if (value.isEmpty || value.toLowerCase() == 'starting navigation') {
      return null;
    }
    final normalized = value.toLowerCase();
    if (normalized.contains('eta')) {
      return value;
    }
    if (RegExp(r'\b\d+\s?(m|km|mi)\b').hasMatch(normalized) ||
        RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(normalized)) {
      return value;
    }
    return value;
  }

  String? _extractStreetName(String instruction) {
    final match = RegExp(
      r'\b(?:onto|on|to)\s+([A-Z0-9][A-Za-z0-9 .-]+)',
      caseSensitive: false,
    ).firstMatch(instruction);
    if (match == null) {
      return null;
    }
    return match.group(1)?.trim();
  }
}

class _NavigateSnapshot {
  const _NavigateSnapshot({
    required this.primaryInstruction,
    required this.directionCue,
    required this.detailLines,
  });

  final String primaryInstruction;
  final String? directionCue;
  final List<String> detailLines;

  String get primaryDisplay {
    if (directionCue == null) {
      return primaryInstruction;
    }
    return '$primaryInstruction\n$directionCue';
  }

  String get detailDisplay {
    if (detailLines.isEmpty) {
      return primaryDisplay;
    }
    return detailLines.join('\n');
  }
}
