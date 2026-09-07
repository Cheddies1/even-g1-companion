# Even G1 Companion - Agent Context

> **Document type:** App implementation
> **Audience:** AI agents working on the EvenDemoApp codebase
> **Evidence basis:** App source code + capture-driven design decisions

## What this is
Personal companion app for Even G1 smart glasses, evolved from the old Flutter demo/harness. Also a reverse-engineered BLE behaviour/protocol knowledge base — see `docs/` and `docs/FINDINGS-*.md`.

Primary target:
- Samsung Galaxy S24 Ultra
- current Android version

This is not a generic SDK or polished cross-device release.

## Product direction
Active app modes:
- `glance` — notification display + assistant shortcut
- `capture` — glasses-mic WAV recording. Phone-mic recording ships alongside it as a non-mode feature (a home-screen button), sharing the same WAV format, folder and recordings list.
- `navigate` — Google Maps turn-by-turn via firmware navigation card
- `chat` — voice loop with OpenAI-compatible backend

## Current implementation status (2026-09-07)

Recently implemented:
- **Phone-mic recording** (2026-09-07) - recording without the glasses, from
  a home-screen button rather than a mode. `PhoneCaptureRecorder.kt` reads
  the phone mic via `AudioRecord` (`VOICE_RECOGNITION` source, 16 kHz mono
  16-bit to match the glasses exactly) and publishes through the new shared
  `WavRecordingStore.kt`, so phone and glasses recordings are byte-identical
  WAVs in the same folder with the same `Capture-YYYY-MM-DD-HH-mm.wav`
  pattern - indistinguishable by design. `PhoneCaptureService.kt` is a
  `microphone`-typed foreground service held only for the length of a
  recording; without it Android 14+ feeds a backgrounded process silence and
  a locked-screen recording saves a silent file while reporting success.
  Glasses HUD mirroring happens only when Capture is the active mode, so it
  cannot fight the Glance carousel or a nav card for the `0x4E` surface.
  Phone and glasses mic sessions are mutually exclusive in both directions.
  New files: `lib/services/phone_capture_service.dart`,
  `WavRecordingStore.kt`, `PhoneCaptureRecorder.kt`, `PhoneCaptureService.kt`.
  Device-verified 2026-09-07: 13 minutes recorded with the app backgrounded
  and the screen locked came back 99.7% non-zero samples with no 30-second
  window below -55 dBFS, so the mic really is live rather than being fed
  silence. Still unverified: the phone/glasses mutual exclusion (needs a
  physical tilt-up) and the glasses HUD mirror in Capture mode.
- **Hermes removed as the assistant backend** (2026-09-07) - Hermes was
  decommissioned on the `deepthought` box, so the app-side route went with
  it. `ChatBackendRouter` and its test are deleted outright: they existed
  only to choose between Hermes and OpenAI, which also removed the health
  probe, the fallback path and the routing-notice display. `chat_service` and
  `glance_assistant_service` now hold an `OpenAiChatBackend` directly. The
  `AssistantBackendKind` enum, `resolveHermes()`, the `HERMES_*` dart-defines
  and the whole Settings section are gone. `AppSettingsStore.init` now runs
  an idempotent purge of the five retired preference keys and the
  `assistant.hermes_api_key` secure-storage entry, so an upgraded device does
  not keep a bearer token for a service that no longer exists. The purge runs
  only inside `init()`, so it fires once per process - a warm resume does not
  re-run it. Device-verified 2026-09-07 by re-injecting all five keys plus a
  stand-in bearer token and cold-starting: all six went, and the real
  `assistant.api_key` was left byte-identical. Note `deepthought` itself is
  very much alive - it runs Ollama, T3 Code and a local OpenCode provider;
  only Hermes died.
- **Battery + wear state** on home screen and Glance HUD (pushed by firmware, no polling)
- **Brightness slider + auto toggle** on home screen
- **Firmware settings dropdowns** (tilt-up behaviour + double-tap action) on Settings page
- **Double-tap mode switch** via `F5 20` (cycles modes when official app's double-tap action is host-handled)
- **Navigate moved off the old BMP main path** — the firmware `0x0a`
  structured-card protocol is now the active direction of travel, with the
  current debug implementation replaying the full 108-packet official
  lifecycle and the production target still being dynamic TRIP_STATUS packet
  building. Direction is currently hinted with Unicode arrow text (→ ← ↑ etc.)
  prepended to road name.
- **Chat `0x52` paced streaming** (`Confirmed`, 2026-05-01) — assistant
  replies render word-by-word via a `StreamingRenderQueue` that decouples
  backend chunk arrival from display cadence (2 words / 200 ms, ~450 WPM).
  The queue sends line 1 (`\n` marker) + line 2 (visible text) on every
  tick — matching the official app's line model. The firmware does NOT
  auto-scroll; the host wraps text with `\n` at 43-char word boundaries
  and keeps only the last 3 lines (matching the firmware's 3 visible rows).
  Follow-up turns: `startListening` does `Proto.exit()` only when a prior
  `0x52` session is active. `wrapText()` still exists for non-queue `0x4E`
  renders. Key constants: `_displayLineWidth = 43`,
  `_displayVisibleRows = 3`, `wordsPerTick = 2`, `drainInterval = 200ms`.
- **Glance: Now Playing media in time line** (2026-05-06) — media
  notifications (`NotificationDisposition.mediaAbsorbed`) absorbed into the
  Glance time line as `> Artist - Track` suffix. 60-second timeout clears
  stale media. Truncated to fit the 43-char line budget.
- **Glance: ongoing call idle surface** (2026-05-06) — when a phone call
  is active, the idle surface (post-carousel-timeout) shows a persistent
  call HUD: `Ongoing call: <name>` + `Call time: M:SS`. Duration computed
  locally from `notification.when` (call connect time) via a 1 Hz timer.
  Detection: `com.samsung.android.incallui`, `category == 'call'`,
  `isOngoing`. New `callAbsorbed` disposition in NotificationPolicy.
  `GlanceService.showIdleSurfaceIfAvailable()` replaces the former stub.
  Tilt-up returns to carousel; call-end clears the HUD.
- **UI polish pass** (2026-05-07) — theme accent changed from mint
  `#7DCFA0` to deep teal-green `#1F5E54`. Home page: removed floating Stop
  Scan link, fixed chip wrapping (2×2 via LayoutBuilder), replaced
  false-affordance pair row with InkWell+Row, dropped duplicate title
  (settings cog moved to AppBar actions). Settings notifications: single
  column headers at section top, per-row labels removed. Auto-pop dismiss
  timer fix: content-refresh renders no longer cancel the auto-hide timer.
  Display duration 3 s.
- **Custom launcher icon** (2026-05-07) — adaptive icon via
  `flutter_launcher_icons ^0.14.4`. White eyeglasses glyph on `#1F5E54`
  background. Generator script at `tool/generate_app_icon.dart`.
- **Native BLE lifecycle fixes — Tier 1** (2026-05-08) — capture-driven
  analysis of HCI snoops from the official Even Realities app (cross-referenced
  with JohnRThomas wiki and Gadgetbridge constants) identified native GATT
  lifecycle bugs as the dominant cause of long-term BLE instability, not
  heartbeat cadence. Six bugs fixed in
  `android/.../bluetooth/BleManager.kt` and `MainActivity.kt`: `gatt.close()`
  now called on disconnect to prevent GATT client exhaustion; `reconnectLeg`
  switched to `autoConnect=true`; GATT setup serialised through a
  `LegSetupPhase` enum (CCCD → MTU → conditional bond → `markLegReady()`);
  missing `onMtuChanged` / `onDescriptorWrite` / `onCharacteristicWrite`
  callbacks added; `createBond()` guarded against already-bonded devices;
  bond-state `BroadcastReceiver` added to surface `bond_failed` to Flutter.
  Deferred: Tier 2 (heartbeat cadence to match official app's 2 s `0x1f`)
  and Tier 3 (reconnect tuning, connection priority for streaming).
- **Capture v2 — live recording HUD + recordings list** (v1.2.0+10,
  2026-05-18) — `CaptureService` pushes a live `0x4E` HUD every 5 s during
  recording (idle, animated `* REC  MM:SS`, save confirmation). Tilt-up
  while recording is now a no-op (was: toggle stop/start); double-tap stops
  and saves. `handleDoubleTapModeSwitch` guards block `F5 20` during active
  recording. New `RecordingsPage` (MediaStore-backed, no local db) lets the
  user browse, rename, share, and delete recordings. New filename pattern:
  `Capture-YYYY-MM-DD-HH-mm.wav`; dual-regex parser handles legacy format.
  New `G1TextLayout` module provides pixel-accurate `0x4E` line wrapping
  using the firmware's actual glyph-width table (replaces `TextPainter`-based
  measurement in `EvenAIDataMethod.measureStringList`; three call sites
  upgraded transparently). New files: `lib/services/g1_text_layout.dart`,
  `lib/models/recording.dart`, `lib/services/recordings_service.dart`,
  `lib/views/recordings_page.dart`.

Under active development:
- Navigate `0x0a` structured card — **protocol confirmed working** (full
  108-packet replay renders on the glasses). The firmware requires all three
  sub-types (text + icon + map), `0x50` mode control before INIT, and a
  continuous 1-second SYNC poller to keep the session alive. **Transport
  status:** interleaved per-leg fire-and-forget replay is now the stable debug
  mode; broadcast could starve a leg, and full sequential replay introduced a
  visible multi-second eye gap. Navigate mode entry also now delays the idle
  fallback prompt briefly so "Open Google Maps / to start navigation" does not
  override the first real nav replay, and explicitly clears that stale text
  fallback before the first lifecycle when needed. **Current live slice:**
  bootstrap uses the full 108-packet replay, but the replayed `TRIP_STATUS`
  packet is now replaced dynamically from live Google Maps fields. The
  `MAP_OVERVIEW` direction icon is now dynamically generated: the Google Maps
  notification icon PNG (`navIconPngBase64`) is scraped, decoded to 136×136
  monochrome, and RLE-encoded. Geometric arrow generation exists as fallback.
  Captured `PANORAMIC_MAP` bytes remain unchanged (static route map).
  A real 1-second SYNC poller keeps the session alive, and post-bootstrap
  updates use `TRIP_STATUS + SYNC`. The idle prompt is suppressed to avoid a
  first-load race condition with `Proto.exit()`.

Not yet implemented (documented, protocol known):
- **Dashboard content injection** — push summaries/reminders into the firmware's grid via `0x1e` TX

## Trusted behaviour
Only build on event meanings we trust from live testing:
- `F5 00` = close active feature / home
- `F5 02` = tilt-up / dashboard-open start
- `F5 03` = tilt-down / dashboard-close start
- `F5 04` / `F5 05` = triple-tap silent-mode toggle (confirmed)
- `F5 17` = left long-press press-down (voice / Even AI start)
- `F5 18` = left long-press release (voice / Even AI stop)
- `F5 1E` / `30` = dashboard/state-up follow-on
- `F5 1F` / `31` = dashboard/state-down follow-on
- `F5 20` = double-tap delegates to host (Transcribe / Translate / Teleprompter all fire it; Dashboard and None do not)

Important:
- do not design around single taps — confirmed firmware-only in every tested state
- do not treat Python SDK labels as ground truth
- right long-press (QuickNote) does NOT fire `F5 17`/`F5 18`; it uses the `0x21` family. Left and right long-press are not symmetric.

## Protocol knowledge (refer, don't re-derive)

The BLE protocol is extensively documented from four HCI snoop capture sessions. Always check these before investigating from scratch:

- [docs/protocol-reference.md](docs/protocol-reference.md) — wire-level reference for all known command/event families
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md) — every observed F5 sub-code with confidence labels
- [docs/FINDINGS-battery+brightness.md](docs/FINDINGS-battery+brightness.md)
- [docs/FINDINGS-taps.md](docs/FINDINGS-taps.md)
- [docs/FINDINGS-settings.md](docs/FINDINGS-settings.md)
- [docs/FINDINGS-layouts.md](docs/FINDINGS-layouts.md)
- [docs/external-protocol-wiki-notes.md](docs/external-protocol-wiki-notes.md) — comparison with the JohnRThomas wiki

Key protocol families already mapped:
- `0x01` brightness set, `F5 12` brightness echo
- `0x08` head-up settings, `0x26` touch settings (persisted on glasses)
- `F5 0A <pct>` glasses battery push, `F5 0F <pct>` case battery push
- `F5 06/07/08/0B` wear/cradle state
- `0x0a` navigation structured card — requires full lifecycle: `0x50` mode
  control + INIT + SYNC + TRIP_STATUS + MAP_OVERVIEW ×13 (RLE icon, 136×136)
  + PANORAMIC_MAP ×90 (raw map, 488×136) + trailing SYNC. Plus a continuous
  1-second SYNC poller for the entire nav session. Fire-and-forget writes.
  All three sub-types required (text-only rejected). Sub-command names from
  Gadgetbridge: INIT(0x00), TRIP_STATUS(0x01), MAP_OVERVIEW(0x02),
  PANORAMIC_MAP(0x03), SYNC(0x04), EXIT(0x05), ARRIVED(0x06).
  MAP_OVERVIEW RLE format: simple `<count> <byte>` pairs (count max 255),
  row-major LSB-first pixel layout, two layers (image + overlay) = 4,624
  raw bytes. Confirmed from ayroblu Swift source. Padded to 13 bands of
  185-byte chunks with 9-byte packet headers.
- `0x52` / `0x53` live streaming text (`Confirmed`, 2026-05-01): line 1
  `\n` marker + line 2 all text; firmware has 3 rows, ~43 chars/row, does
  NOT auto-scroll; host manages scrolling by wrapping at word boundaries
  and trimming to last 3 lines; `0x53` keepalive every 5 s
- `0x1e` TX dashboard data slot injection / RX quicknote post-release audio stream
- `0x50` display mode control (required before `0x0a` nav and `0x52` streaming)
- `0x06` / `0x22` note management transactions
- `0x4E` text rendering, `0x15/0x16/0x20` BMP transfer (legacy, still in codebase)

External protocol references:
- Gadgetbridge `G1Constants.java` — comprehensive named constants for all families
- ayroblu/bazel-demo Swift implementation — decoded TRIP_STATUS prefix structure,
  confirmed icon/map dimensions and encoding. See `docs/external-protocol-wiki-notes.md`.

Capture workflow: `logs/bluetooth/parse_btsnoop.py` + per-topic `analyze_*.py` scripts. Enable HCI snoop → BT off/on → capture → `adb bugreport` → parse.

## Key files
- [lib/ble_manager.dart](lib/ble_manager.dart) — BLE connection + F5 dispatch
- [lib/services/companion_controller.dart](lib/services/companion_controller.dart) — mode ownership + gesture routing
- [lib/services/device_status_service.dart](lib/services/device_status_service.dart) — battery, wear, brightness, settings state
- [lib/services/glance_service.dart](lib/services/glance_service.dart)
- [lib/services/capture_service.dart](lib/services/capture_service.dart) — Capture session, live HUD, start/stop/save
- [lib/services/phone_capture_service.dart](lib/services/phone_capture_service.dart) — phone-mic recording session, RECORD_AUDIO permission, mutual exclusion with the glasses mic
- [lib/services/recordings_service.dart](lib/services/recordings_service.dart) — MediaStore platform-channel wrapper for recordings list
- [lib/models/recording.dart](lib/models/recording.dart) — Recording model, dual-format filename parser, duration computation
- [lib/views/recordings_page.dart](lib/views/recordings_page.dart) — recordings list UI (browse, rename, share, delete)
- [lib/services/g1_text_layout.dart](lib/services/g1_text_layout.dart) — pixel-accurate 0x4E line wrapping using firmware font-width table
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart) — now uses `0x0a` card protocol
- [lib/services/nav_icon_generator.dart](lib/services/nav_icon_generator.dart) — PNG-to-RLE MAP_OVERVIEW conversion, ManoeuvreType enum, geometric arrow fallback
- [lib/services/navigate_bitmap_service.dart](lib/services/navigate_bitmap_service.dart) — legacy BMP renderer (preserved, not called from Navigate)
- [lib/services/chat_service.dart](lib/services/chat_service.dart)
- [lib/services/streaming_render_queue.dart](lib/services/streaming_render_queue.dart) — paced 0x52 display queue for Chat
- [lib/services/proto.dart](lib/services/proto.dart) — wire-level BLE commands (brightness, settings, nav card, heartbeat)
- [lib/services/app_settings_store.dart](lib/services/app_settings_store.dart) — persisted user preferences
- [lib/services/app_log.dart](lib/services/app_log.dart) — central logger
- [lib/views/home_page.dart](lib/views/home_page.dart) — battery/wear pills, brightness slider, mode selector, Recordings card
- [lib/views/settings_page.dart](lib/views/settings_page.dart) — API config, notification filters, firmware settings
- [android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt](android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleChannelHelper.kt](android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleChannelHelper.kt) — also contains listRecordings / renameRecording / deleteRecording / shareRecording platform-channel methods
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/CompanionForegroundService.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/CompanionForegroundService.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/GlassesCaptureRecorder.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/GlassesCaptureRecorder.kt) — PCM sink fed by the BLE LC3 stream; recordings management methods
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/WavRecordingStore.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/WavRecordingStore.kt) — shared WAV framing + MediaStore publishing, and the 16 kHz mono 16-bit format constants both recorders use
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/PhoneCaptureRecorder.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/PhoneCaptureRecorder.kt) — AudioRecord-based phone-mic recorder
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/PhoneCaptureService.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/PhoneCaptureService.kt) — microphone-typed foreground service; what keeps the mic live when the screen locks
- [android/app/src/main/cpp/liblc3.cpp](android/app/src/main/cpp/liblc3.cpp) — LC3 audio decode (used by Capture, Chat, QuickNote)

## Architectural guardrails
- mode ownership must stay in CompanionController
- do not route gesture behaviour directly inside feature services
- prefer adding narrow hooks over duplicating control flow
- use `AppLog` for all Flutter-side logging; do not reintroduce raw `print()` in `lib/`
  - `AppLog.info` / `AppLog.error` are always on (lifecycle, state changes, error paths)
  - `AppLog.debug` is gated behind `COMPANION_VERBOSE_LOGS=true` (per-event chatter, probes, render traces)
  - always pass a `tag:` matching the subsystem (e.g. `BLE`, `Glance`, `Chat`, `Navigate`, `Companion`, `DeviceStatus`)
- use only relative paths in markdown docs — never commit absolute local filesystem paths

## Constraints
- the phone has one microphone: phone-mic recording and the glasses mic paths (Capture, Chat, QuickNote, Quick Ask) are mutually exclusive, enforced in both `PhoneCaptureService.startRecording` and `CaptureService.startRecording`. Do not add a third audio consumer without extending that check
- phone-mic recording needs its `microphone`-typed foreground service to be running. Android 14+ feeds a backgrounded process silence rather than an error, so dropping the service produces a silent WAV that still reports success
- the assistant has one backend. Hermes was removed on 2026-09-07 (`hermes-dewire-chat`) along with `ChatBackendRouter`, the health probe and the fallback path. Do not reintroduce a selectable backend without a use case that needs one
- preserve working BLE scan/connect/pairing and protocol framing
- prefer narrow changes over broad rewrites
- treat the Android notification listener and foreground service as core app foundations
- the BMP pipeline is preserved in the codebase for potential future use (do not delete)
- Glance has a call-HUD idle surface but no live-score idle surface; pinned/live score notifications stay in the normal protected notification flow

## Read first
- [README.md](README.md) — repo overview + key confirmed findings
- [docs/current-worklist.md](docs/current-worklist.md) — **start here for
  the active task queue**, including the current Navigate checkpoint and next
  incremental `0x0a` tasks
- [docs/current-architecture.md](docs/current-architecture.md)
- [docs/current-behaviour.md](docs/current-behaviour.md)
- [docs/protocol-reference.md](docs/protocol-reference.md) — wire-level
  reference for all known protocol families
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md)
- [docs/external-protocol-wiki-notes.md](docs/external-protocol-wiki-notes.md) —
  cross-references to Gadgetbridge constants + ayroblu Swift implementation
- [docs/FINDINGS-layouts.md](docs/FINDINGS-layouts.md) — the rendering
  protocol findings including the nav card debugging results
