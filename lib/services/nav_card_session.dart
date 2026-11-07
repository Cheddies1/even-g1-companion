import 'dart:async';
import 'dart:typed_data';

import 'package:even_companion/ble_manager.dart';
import 'package:even_companion/services/app_log.dart';
import 'package:even_companion/services/ble.dart';
import 'package:even_companion/services/proto.dart';
import 'package:even_companion/services/text_service.dart';
import 'package:even_companion/services/walknav/nav_wire.dart';

/// The glasses side of one `0x0a` navigation card session, shared by the
/// walking navigator and the Google Maps notification fallback.
///
/// Lifecycle rules (docs/protocol-reference.md "Navigation card",
/// docs/FINDINGS-nav-marker-tiles.md):
/// - clear (`0x18`) before INIT, or INIT does not take over a `0x4E` surface
/// - the firmware enters RUNNING only once both maps are on both lenses
/// - the right (master) lens gets its final map packet only after the left
///   has acked its own, else the slave can stay on "route is being generated"
/// - only the master counts SYNC (~19 s grace); its echo carries byte 5 = 0
///   when nav is not running, which is the liveness check here
/// - display content is not relayed: every packet goes to both lenses
class NavCardSession {
  NavCardSession({required this.tag, this.onLost});

  static const syncInterval = Duration(seconds: 5);
  static const _mapAckTimeout = Duration(seconds: 6);
  static const _legsWait = Duration(seconds: 15);

  /// Consecutive "not running" SYNC echoes before the session counts as lost.
  /// Two at 5 s spacing rides out a late, queued master reply.
  static const _lostAfterNotRunning = 2;

  /// Log tag of the owning service.
  final String tag;

  /// Called when the master reports nav is not running while we think it is.
  /// The owner re-boots with its current maps and status.
  final Future<void> Function()? onLost;

  final NavWire wire = NavWire();
  Timer? _syncTimer;
  StreamSubscription<BleReceive>? _syncReplies;
  bool _running = false;
  bool _busy = false;

  /// INIT has gone out since the last EXIT, so the glasses may be in nav even
  /// if the boot never finished.
  bool _inited = false;

  /// Bumped by [exit] and [drop]; a boot or swap from an older generation
  /// stops writing at its next await and never starts the keepalive.
  int _gen = 0;

  /// A leg that was down when the boot went ahead. Its recovery event can be
  /// swallowed by the boot in flight, so the keepalive re-boots once it is
  /// back.
  String? _missingLeg;
  int _notRunningStreak = 0;

  /// Seq bytes of keepalive SYNCs. Only their echoes count for liveness: the
  /// boot SYNCs go out before RUNNING and their echoes can arrive late.
  final Set<int> _keepaliveSeqs = {};

  /// INIT sent and maps on the glasses; SYNC is being kept alive.
  bool get isRunning => _running;

  /// Clear, INIT both lenses, send both maps master-last, then SYNC. Starts
  /// the master-only SYNC keepalive with liveness checks. Returns false if
  /// [exit] or [drop] cancelled it part-way.
  Future<bool> boot({
    required Uint8List miniMap,
    required Uint8List panoramic,
  }) async {
    final gen = ++_gen;
    _running = false;
    _busy = true;
    try {
      _stopSync();
      await _waitForBothLegs(gen);
      if (gen != _gen) return false;
      await TextService.get.stopTextSendingByOS();
      if (gen != _gen) return false;
      await Proto.clearDisplay();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (gen != _gen) return false;
      _inited = true;
      await _both(wire.init(), gen: gen);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (gen != _gen) return false;
      await BleManager.sendData(wire.sync(), lr: 'R');
      await _sendMaps(miniMap, panoramic, gen);
      if (gen != _gen) return false;
      await BleManager.sendData(wire.sync(), lr: 'R');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (gen != _gen) return false;
      _running = true;
      _startSync();
      return true;
    } finally {
      if (gen == _gen) _busy = false;
    }
  }

  /// Transport recovery can fire when the first leg is back; a boot then
  /// would leave the other lens without INIT or maps. Wait a while for both,
  /// then go ahead with what is there and let liveness catch the rest.
  Future<void> _waitForBothLegs(int gen) async {
    final ble = BleManager.get();
    _missingLeg = null;
    final deadline = DateTime.now().add(_legsWait);
    while (!(ble.isLegAvailable('L') && ble.isLegAvailable('R'))) {
      if (gen != _gen) return;
      if (DateTime.now().isAfter(deadline)) {
        _missingLeg = ble.isLegAvailable('L') ? 'R' : 'L';
        AppLog.error('booting without leg $_missingLeg', tag: tag);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Replace both maps inside a running session (a tile swap). Returns true
  /// when the left lens acked both final packets.
  Future<bool> swapMaps({
    required Uint8List miniMap,
    required Uint8List panoramic,
  }) async {
    final gen = _gen;
    _busy = true;
    try {
      return await _sendMaps(miniMap, panoramic, gen);
    } finally {
      if (gen == _gen) _busy = false;
    }
  }

  /// One TRIP_STATUS packet from [NavWire.tripStatus], to both lenses.
  Future<void> sendTripStatus(Uint8List packet) => _both(packet);

  /// ARRIVED status 2: the firmware's "arrived complete" page for ~5 s.
  Future<void> arrived(String prompt) => _both(wire.arrived(prompt));

  /// EXIT to both lenses and stop the keepalive. Safe to call when not
  /// running.
  Future<void> exit() async {
    final wasInNav = _running || _inited;
    _cancel();
    if (wasInNav) await _both(wire.exit());
  }

  /// Forget the session without sending anything (the link is gone).
  void drop() => _cancel();

  void _cancel() {
    _gen++;
    _running = false;
    _busy = false;
    _inited = false;
    _stopSync();
  }

  Future<bool> _sendMaps(
      Uint8List miniMap, Uint8List panoramic, int gen) async {
    final okMini = await _sendMapMasterLast(wire.miniMapPackets(miniMap),
        sub: 0x02, gen: gen);
    if (gen != _gen) return false;
    final okPano = await _sendMapMasterLast(wire.panoramicPackets(panoramic),
        sub: 0x03, gen: gen);
    return okMini && okPano;
  }

  /// All packets to both lenses, except the master's final packet, which
  /// goes only after the left has acked its own final packet. Use L acks for
  /// timing: the master queues its responses.
  Future<bool> _sendMapMasterLast(List<Uint8List> packets,
      {required int sub, required int gen}) async {
    final total = packets.length;
    for (var i = 0; i < total - 1; i++) {
      await _both(packets[i], gen: gen);
    }
    if (gen != _gen) return false;
    final ack = BleManager.navFrames.stream
        .where((r) => r.lr == 'L' && NavWire.isFinalMapAck(r.data, sub, total))
        .first
        .timeout(_mapAckTimeout);
    await BleManager.sendData(packets.last, lr: 'L');
    var acked = true;
    try {
      await ack;
    } on TimeoutException {
      acked = false;
      AppLog.error('no L ack for final map packet (sub $sub)', tag: tag);
    }
    if (gen != _gen) return false;
    await BleManager.sendData(packets.last, lr: 'R');
    return acked;
  }

  /// Both lenses, L first. With [gen], nothing goes out once that
  /// generation is cancelled, not even the second leg.
  Future<void> _both(Uint8List packet, {int? gen}) async {
    if (gen != null && gen != _gen) return;
    await BleManager.sendData(packet, lr: 'L');
    if (gen != null && gen != _gen) return;
    await BleManager.sendData(packet, lr: 'R');
  }

  // ---- keepalive and liveness ------------------------------------------------

  void _startSync() {
    _stopSync();
    _notRunningStreak = 0;
    _syncReplies = BleManager.navFrames.stream
        .where((r) => r.lr == 'R')
        .listen((r) => _onSyncReply(r.data));
    _syncTimer = Timer.periodic(syncInterval, (_) {
      if (!_running) return;
      final missing = _missingLeg;
      if (missing != null && !_busy && BleManager.get().isLegAvailable(missing)) {
        _missingLeg = null;
        AppLog.info('leg $missing back after a one-leg boot: re-booting',
            tag: tag);
        final lost = onLost;
        if (lost != null) unawaited(lost());
        return;
      }
      final packet = wire.sync();
      if (_keepaliveSeqs.length > 32) _keepaliveSeqs.clear();
      _keepaliveSeqs.add(packet[3]);
      unawaited(BleManager.sendData(packet, lr: 'R'));
    });
  }

  void _stopSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _keepaliveSeqs.clear();
    unawaited(_syncReplies?.cancel());
    _syncReplies = null;
  }

  void _onSyncReply(Uint8List frame) {
    final running = NavWire.syncSaysRunning(frame);
    if (running == null || !_running) return;
    if (!_keepaliveSeqs.remove(frame[3])) return;
    if (running) {
      _notRunningStreak = 0;
      return;
    }
    // Map transfers and boots legitimately run with nav not yet RUNNING.
    if (_busy) return;
    _notRunningStreak++;
    if (_notRunningStreak < _lostAfterNotRunning) return;
    _notRunningStreak = 0;
    AppLog.info('master reports nav not running: re-booting', tag: tag);
    final lost = onLost;
    if (lost != null) unawaited(lost());
  }

  /// A blank mini-map (RLE: all zero, one packet) and a blank panoramic map
  /// (raw only, 90 packets), for sessions with no rendered maps.
  static final Uint8List blankMiniMap = _rleZeros(4624);
  static final Uint8List blankPanoramic = Uint8List(16592);

  static Uint8List _rleZeros(int n) {
    final out = <int>[];
    for (var left = n; left > 0; left -= 255) {
      out
        ..add(left > 255 ? 255 : left)
        ..add(0);
    }
    return Uint8List.fromList(out);
  }
}
