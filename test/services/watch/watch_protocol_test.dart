import 'package:even_companion/models/app_mode.dart';
import 'package:even_companion/services/watch/watch_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WatchCommand.parse', () {
    test('parses every command kind by wire name', () {
      for (final kind in WatchCommandKind.values) {
        final json = <String, Object>{'seq': 3, 'cmd': kind.wire};
        if (kind == WatchCommandKind.setMode) json['mode'] = 'glance';
        expect(WatchCommand.parse(json).kind, kind);
      }
    });

    test('mode.set accepts every mode, case-insensitively', () {
      for (final mode in AppMode.values) {
        final cmd = WatchCommand.parse(
            {'cmd': 'mode.set', 'mode': ' ${mode.name.toUpperCase()} '});
        expect(cmd.mode, mode);
      }
    });

    test('mode.set rejects an unknown or missing mode instead of defaulting',
        () {
      expect(() => WatchCommand.parse({'cmd': 'mode.set', 'mode': 'teleport'}),
          throwsFormatException);
      expect(() => WatchCommand.parse({'cmd': 'mode.set'}),
          throwsFormatException);
    });

    test('rejects malformed payloads', () {
      expect(() => WatchCommand.parse('capture.start'), throwsFormatException);
      expect(() => WatchCommand.parse({'seq': 1}), throwsFormatException);
      expect(() => WatchCommand.parse({'cmd': 'self.destruct'}),
          throwsFormatException);
    });
  });

  test('RemoteResult ack shape', () {
    expect(const RemoteResult.ok('Saved x.wav').toJson(),
        {'ok': true, 'message': 'Saved x.wav'});
    expect(const RemoteResult.fail('nope').toJson(),
        {'ok': false, 'message': 'nope'});
  });

  group('WatchState.toJson', () {
    WatchState state({String title = 'Hello', DateTime? startedAt}) =>
        WatchState(
          connected: true,
          mode: AppMode.capture,
          status: 'Recording',
          displayOwner: 'Capture',
          recording: startedAt != null,
          recordingStartedAt: startedAt,
          glanceVisible: false,
          glanceIndex: 0,
          glanceCount: 4,
          glanceTitle: title,
          glanceApp: 'Messages',
          assistantListening: false,
          assistantThinking: false,
          walkActive: false,
          glassesBattery: 80,
          caseBattery: null,
        );

    test('carries protocol, mode name and epoch-ms start time', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final json = state(startedAt: at).toJson();
      expect(json['protocol'], WatchState.protocol);
      expect(json['mode'], 'capture');
      expect(json['recording'], true);
      expect(json['recordingStartedAt'], 1700000000000);
      expect(json['battery'], {'glasses': 80, 'case': null});
    });

    test('truncates long notification titles to 60 chars', () {
      final title =
          (state(title: 'x' * 100).toJson()['glance'] as Map)['title'] as String;
      expect(title.length, 60);
      expect(title.endsWith('...'), true);
    });
  });
}
