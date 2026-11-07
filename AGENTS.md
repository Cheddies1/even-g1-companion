# Even G1 Companion - Agent Context

> **Document type:** App implementation
> **Audience:** AI agents working on the EvenDemoApp codebase
> **Evidence basis:** App source code + capture-driven design decisions

This file holds durable rules and pointers only. Detail lives in `docs/`;
dated implementation history is in
[docs/archive/agents-md-history-2026-11-06.md](docs/archive/agents-md-history-2026-11-06.md)
(history only - current docs win where they disagree).

## What this is
Personal companion app for Even G1 smart glasses, evolved from the old Flutter
demo/harness, and a reverse-engineered BLE protocol knowledge base (`docs/`).
Target: Samsung Galaxy S24 Ultra on current Android, G1 firmware 1.6.6. Not a
generic SDK or cross-device release.

## Modes and features
- `glance` - notification carousel (single-tap paging on the tap-enabled `0x4E`
  surface), media line, ongoing-call HUD, assistant shortcut
- `capture` - glasses-mic WAV recording with a live HUD. Phone-mic recording is
  a home-screen button, not a mode; same WAV format, folder and list
- `navigate` - walking navigation on the firmware `0x0a` nav card from
  `cartographer` route bundles, started by a Google Maps share; the Google Maps
  notification card is the fallback. Plan:
  [docs/plans/navigate-v1-cartographer.md](docs/plans/navigate-v1-cartographer.md)
- `chat` - voice loop, paced `0x52` streaming

Speech-to-text is the self-hosted Speaches `whisper-server` on `deepthought`
(`http://deepthought:56478/v1`) over Tailscale: unauthenticated, no bearer, no
OpenAI fallback by choice. The reasoning call goes to OpenAI.
Walking-nav route bundles come from `cartographer` on deepthought
(`https://deepthought.tail082c0b.ts.net:9446/v1/route`, tailnet only, Codex-owned); schema in
[docs/cartographer-contract.md](docs/cartographer-contract.md).

For what each mode does today see [docs/current-behaviour.md](docs/current-behaviour.md);
for what is in flight see [docs/current-worklist.md](docs/current-worklist.md).

## Trusted behaviour
Only build on event meanings we trust from live testing
(full table: [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md)):
- `F5 00` = close active feature / home
- `F5 02` / `F5 03` = tilt-up / tilt-down start
- `F5 04` / `F5 05` = triple-tap silent-mode toggle
- `F5 17` / `F5 18` = left long-press down / release (voice start / stop)
- `F5 1E`/`30`, `F5 1F`/`31` = dashboard state up / down follow-ons
- `F5 20` = double-tap delegated to host (Transcribe / Translate / Teleprompter
  settings fire it; Dashboard and None do not)
- `F5 01` = single tap, **only** while a tap-enabled `0x4E` surface is up
  (open `0x31`, pin and page with `0x51`); see `docs/protocol-reference.md`
  § "Recipe: tap-enabled text surface"

Traps:
- under our usual `0x4E` status `0x71`, single taps never reach the phone
- over a text surface, double tap arrives as `F5 00`, not `F5 20`; our own
  clears and renders can make the right lens emit `F5 00`
- right long-press (QuickNote) uses the `0x21` family, not `F5 17`/`18`
- do not treat Python SDK labels as ground truth

## Protocol knowledge (refer, don't re-derive)
Start at [docs/protocol-reference.md](docs/protocol-reference.md). Source
precedence: the firmware decomp
([docs/firmware-decomp-notes.md](docs/firmware-decomp-notes.md), branch
`1.66_exact` of `JohnRThomas/even_realities_decomp`) wins on packet structure;
live device testing wins on behaviour, timing and rendering. Other external
references are compared in
[docs/external-protocol-wiki-notes.md](docs/external-protocol-wiki-notes.md).

Topic findings: `docs/FINDINGS-*.md` (taps, settings, layouts, battery and
brightness, QuickNote, Even AI flash on clear, nav marker and tiles).

Load-bearing rules (each has caused a silent failure):
- bytes 1-2 of most commands are a validated LE total length; a mismatch
  drops the packet silently
- `0x0a` TRIP_STATUS strings are capped (24/24/64/24/24 B); overflow aborts
  the whole packet
- display content is **not** relayed between lenses: write both legs. Right is
  master, left is slave ([docs/firmware-decomp-display-relay.md](docs/firmware-decomp-display-relay.md))
- `0x4E` text is capped at 480 bytes (no bounds check in firmware); acks
  `0xCB` on intermediate chunks, `0xC9` on the last
- `0x0a` nav: `0x18` clear before INIT; the master gets its final map packet
  after the slave has finished; marker within x 6..482, y 6..130
  ([docs/FINDINGS-nav-marker-tiles.md](docs/FINDINGS-nav-marker-tiles.md))
- `0x52`/`0x53` streaming: the keepalive must be the full `53 06 00 <seq> 03 00`
  frame; 30 s without one ends the session
- `0x50` is a master-only dashboard-state probe. It does not clear or prime the
  display; send it to R only
- link liveness is any write within 30 s; `0x25` sub 4 is teleprompter sync,
  not a real heartbeat
- time sync sends the `06 01` record alone; `total=1` frames on `0x06` sub
  `03`/`04`/`06` persist the dashboard layout
- do-not-send: `0x4A` with bit 0 (DFU), `0x26` sub `0x01` (user data reset),
  `0x47` (unpair)

Capture workflow: `logs/bluetooth/parse_btsnoop.py` + per-topic `analyze_*.py`.
Enable HCI snoop, BT off/on, capture, `adb bugreport`, parse.

## Debug protocol probe
Debuggable builds register an adb probe in `BleManager.kt`:

```
adb shell am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.PROBE --es hex <hex> [--es lr L|R]
```

Omit `lr` for both legs. RX frames log under `adb logcat -s G1Probe`. The
receiver registers in `MainActivity.onCreate`, so open the app after a
reinstall. `--es batch <file>` runs a timed packet script from the app's
external `files/probe/` dir; `tool/nav_harness.py` generates the `0x0a` ones.
On the master (R) many responses are queued and arrive late; use L acks for
timing. Anything worth keeping belongs in `Proto`. While a batch runs the probe
holds back `F5 00/02/03` from Dart (every mode acts on tilt; close kills nav).

Walking-nav desk test (debug): `am start -n com.eddie.evencompanion/.MainActivity` first (Android
14 refuses a background location FGS), then `am broadcast ... -a com.eddie.evencompanion.NAV_TRIP
--es dest "lat,lon" [--es replay <trace.csv from files/gps>] [--ef speed 4]` (`--es cmd stop` ends
it). Logs: logcat `[WalkNav]` and `G1Nav`. Real-trace replay test: `NAV_BUNDLE=... NAV_TRACE=...
flutter test test/services/walknav/real_trace_replay_test.dart` (skips without both).
BLE drop test: `adb shell cmd bluetooth_manager disable`, wait, `enable` (adb over Tailscale
survives it); expect `[WalkNav] resync: re-booting the card`.

Region sync (debug): `am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.REGION_SYNC
--es at "lat,lon" [--es name X] [--ez pinned true]` builds a region on cartographer and polls it
(logcat `[Regions]` and `G1Regions`); open the app once after install. A `name` with spaces needs
inner quoting over `adb shell`. Debug trips accept `--es name X` to name an offered region.

GPS trace recorder (debug): `am broadcast ... -a com.eddie.evencompanion.GPS_TRACE --es cmd
start|stop`, app foregrounded to start; CSVs hold real coordinates, keep them in gitignored
`logs/gps/`. See [docs/FINDINGS-screen-off-gps.md](docs/FINDINGS-screen-off-gps.md).

Device access: adb over Tailscale at `100.89.74.113:5555` (after a phone
reboot it needs USB `adb tcpip 5555` first).

## Key files
- `lib/services/companion_controller.dart` - mode ownership, gesture routing
- `lib/ble_manager.dart` - BLE connection, F5 dispatch
- `lib/services/proto.dart` - wire-level commands
- `lib/services/<feature>_service.dart` - per-feature logic (glance, capture,
  phone_capture, navigate, chat, device_status, recordings)
- `lib/services/glance_carousel.dart` - pure, unit-tested carousel paging
- `lib/services/nav_card_session.dart` - the `0x0a` card lifecycle (boot, master-last maps,
  SYNC keepalive + liveness, ARRIVED, EXIT) shared by both nav paths
- `lib/services/walknav/` - walking navigator: pure cores (geometry, bundle, manoeuvre
  filter, route tracker, tile selector, `0x0a` wire) + `walk_navigator_service.dart`;
  Android side `service/NavLocationService.kt` (location FGS, replay, `NavBridge`);
  regions in `walknav/region_*.dart` + `service/RegionSync.kt` (WorkManager job poller)
- `lib/services/g1_text_layout.dart` - pixel-accurate `0x4E` wrapping from the
  firmware glyph-width table
- `lib/services/streaming_render_queue.dart` - paced `0x52` queue for Chat
- `lib/services/app_settings_store.dart`, `app_log.dart`
- `lib/views/` - home, settings, recordings pages
- `android/.../bluetooth/BleManager.kt` - GATT lifecycle, write queues, probe;
  `BleChannelHelper.kt` - platform channel incl. recordings methods
- `android/.../service/` - foreground services, `GlassesCaptureRecorder.kt`,
  `PhoneCaptureRecorder.kt`, `WavRecordingStore.kt` (shared WAV + MediaStore)
- `android/app/src/main/cpp/liblc3.cpp` - LC3 decode

Architecture: [docs/current-architecture.md](docs/current-architecture.md).

## Architectural guardrails
- mode ownership stays in `CompanionController`; do not route gestures inside
  feature services
- prefer narrow hooks over duplicated control flow, narrow changes over rewrites
- `AppLog` for all Flutter logging, never raw `print()` in `lib/`.
  `info`/`error` always on; `debug` gated on `COMPANION_VERBOSE_LOGS=true`;
  always pass a subsystem `tag:`
- relative paths only in markdown docs

## Constraints
- one microphone: phone-mic recording and the glasses-mic paths (Capture, Chat,
  QuickNote, Quick Ask) are mutually exclusive, enforced in both
  `PhoneCaptureService.startRecording` and `CaptureService.startRecording`.
  Extend that check before adding a third consumer
- phone-mic recording needs its `microphone`-typed foreground service; without
  it Android 14+ records silence and still reports success
- `CaptureService` is not a `ChangeNotifier`; UI reading it refreshes only via
  `CompanionController.notifyListeners()`. New capture entry points must go
  through the controller
- one assistant backend (OpenAI). Hermes and `ChatBackendRouter` were removed
  on 2026-09-07; do not reintroduce a selectable backend without a use case
- preserve working BLE scan/connect/pairing and protocol framing
- the notification listener and foreground service are core foundations
- the BMP pipeline stays in the codebase (do not delete)
- deepthought is owned by Codex; delegate work on the box, do not change it
  directly

## Read first
- [README.md](README.md)
- [docs/current-worklist.md](docs/current-worklist.md) - active task queue
- [docs/current-architecture.md](docs/current-architecture.md)
- [docs/current-behaviour.md](docs/current-behaviour.md)
- [docs/protocol-reference.md](docs/protocol-reference.md)
