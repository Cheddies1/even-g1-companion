# AGENTS.md archive (trimmed 2026-11-06)

Verbatim sections removed from `AGENTS.md` when it was cut to a pointer file.
History only: where this disagrees with `docs/protocol-reference.md`,
`docs/current-behaviour.md` or the FINDINGS docs, those win.

## Current implementation status (2026-11-06)

Recently implemented:
- **Glance tap paging** (2026-11-06, `single-tap-0x5x-adoption`, device test
  pending) - tilt-up recall renders on the tap-enabled `0x4E` surface
  (`0x31` open, `0x51` pin and page). Right tap = read, next; left tap = back;
  an end card follows the oldest notification. Phone dismissals are deferred
  to carousel close so back works. Paging state lives in the pure, unit-tested
  `GlanceCarousel` (`lib/services/glance_carousel.dart`); `Proto` tracks
  whether a tap surface is open (`isTapSurfaceOpen`) so every `TextService`
  render stays in the same layout, and marks an 800 ms window after our own
  `0x18`/tap open in which `F5 00` is ignored as self-inflicted. Text on that
  surface wraps to `G1TextLayout.evenAiLayoutWidth` (472 of 576 px). Kill
  switch: `GlanceService.tapPagingEnabled`.
- **Firmware source re-based onto `1.66_exact`; four protocol fixes**
  (2026-11-06, branch `decomp-1.66-fixes`) - the decomp repo is now named C
  source that rebuilds byte-identical to v1.66 (branch `1.66_exact`,
  `435c138`), so offsets read from it are the shipped behaviour. Re-reading
  our protocol use against it found and fixed four things: the Chat `0x53`
  keepalive was a bare byte that failed the length check and never reset the
  firmware's 30 s transcribe timeout (now `53 06 00 <seq> 03 00`,
  device-confirmed: both legs reply `03 c9`, Chat reply held over 60 s);
  `0x4E` text is capped at 480 bytes because the firmware reassembly buffer
  has no bounds check; `0x50` goes to the right lens only (clear, streaming
  init, nav bootstrap) because the left rejects it and it gates nothing; and
  time sync sends only the `06 01` record, because the two frames around it
  persisted the dashboard layout every minute (device-confirmed ack).
  Device run the same day also confirmed **single taps reach the phone**
  as `F5 01` under `0x4E` status `0x5x` (see Trusted behaviour), that the
  `0x3F` readbacks work, and that the native `0x07` countdown timer renders
  garbled digits on 1.66 and is unusable. Debug builds now carry an adb
  protocol probe (see "Debug protocol probe" below). Details in
  [docs/firmware-decomp-notes.md](../firmware-decomp-notes.md) §
  "Re-base onto `1.66_exact`" and
  [docs/protocol-reference.md](../protocol-reference.md).
- **Firmware decompilation folded in as a protocol source** (2026-09-08) —
  `JohnRThomas/even_realities_decomp` is the only reference that is the
  *receiver* rather than another sender, so it outranks the wiki, Gadgetbridge,
  ayroblu and fahrplan on packet structure, and says nothing about behaviour.
  See [docs/firmware-decomp-notes.md](../firmware-decomp-notes.md) and
  [docs/firmware-decomp-display-relay.md](../firmware-decomp-display-relay.md).
  It corrected several things we had wrong: the `0x0a` TRIP_STATUS field model
  (`x` and `y` are both `uint16`, no null separator), the `0x06` family model
  (byte 4 is a content-type sub-command, not a transaction step — and
  `0x03`/`0x04`/`0x05`/`0x07` are firmware-native schedule/stocks/news/citywalk
  record types we do not use), and `0x50` (a **master-only dashboard lock**,
  not display-mode control — do not describe it as clearing or priming the
  display). Display content is **not** relayed between the temples, so the host
  must write both legs. Right lens is master, left is slave.
- **"Even AI is listening" flash on clear — investigated, closed unfixed**
  (2026-09-08) — long-standing intermittent flash root-caused to a firmware
  transient: `0x18` teardown out of screen id `0x10` (`ui_even_ai_task`) on the
  master/right lens. Three candidate fixes disproved on device. Fixed one real
  bug on the way: `Proto.readScreenState` was reading `response.data[1]` (the
  echoed request length) instead of index 5. `clearDisplay` is unchanged in
  behaviour; the `0x39` sampling is retained behind
  `Proto.postClearStateProbe`, default `false`. Full write-up and the two
  measurement mistakes that cost the day in
  [docs/FINDINGS-evenai-flash-on-clear.md](../FINDINGS-evenai-flash-on-clear.md).
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
  silence. The glasses HUD mirror and the phone-then-glasses direction of the
  mic exclusion were confirmed on 2026-09-07 too: with a phone recording live
  and the glasses in Capture mode, the HUD showed the REC state and two
  tilt-ups were both refused (`Capture: start refused - phone recording
  active`) while the phone file saved intact. The reverse direction was
  confirmed the same day: starting a glasses capture by tilt-up greys out the
  phone Record button immediately, and it re-enables only once the glasses
  recording is ended. Both directions of the mic exclusion therefore hold.
  Note the phone card's enabled state reads `CaptureService.isRecording`, and
  `CaptureService` is not a `ChangeNotifier` - the refresh works because every
  path that changes its recording flag runs inside a `CompanionController`
  method that calls `notifyListeners()`, or alongside a `DeviceStatusService`
  reset on transport loss. A new entry point that starts or stops a glasses
  capture outside those paths would leave the button stale.
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
  Deferred: Tier 3 (reconnect tuning, connection priority for streaming).
  Tier 2 (heartbeat cadence to match the official app's 2 s `0x1f`) is moot
  as of 2026-11-06: `0x1f` is onboarding, not a heartbeat, and the firmware
  only needs any write within 30 s.
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
  sub-types (text + icon + map), a `0x50` before INIT in the capture (not
  actually required - it gates nothing; sent to R only since 2026-11-06), and a
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


## Key protocol families (as listed in AGENTS.md)


Key protocol families already mapped:
- `0x01` brightness set, `F5 12` brightness echo
- `0x08` head-up settings, `0x26` touch settings (persisted on glasses)
- `F5 0A <pct>` glasses battery push, `F5 0F <pct>` case battery push
- `F5 06/07/08/0B` wear/cradle state
- `0x0a` navigation structured card — requires full lifecycle: `0x50` mode
  control + INIT + SYNC + TRIP_STATUS + MAP_OVERVIEW ×13 (RLE icon, 136×136)
  + PANORAMIC_MAP ×90 (raw map, 488×136) + trailing SYNC. Plus a continuous
  1-second SYNC poller for the entire nav session. Fire-and-forget writes,
  though INIT and SYNC are in fact acked. Only the master counts SYNC, with
  about 19 s of grace, so the 1 s poller to both legs is more than needed.
  The `0x50` is not required (it gates nothing) and goes to R only.
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
  and trimming to last 3 lines; `0x53` keepalive every 5 s, which must be
  the full `53 06 00 <seq> 03 00` frame - the firmware ends the session after
  30 s without a valid `0x52`/`0x53`
- `0x1e` TX dashboard data slot injection / RX quicknote post-release audio stream
- `0x50` **dashboard-state probe** (the firmware calls it a dashboard lock) -
  master-only, does not touch the display, gates nothing. It arms a 1 s
  window in which the master pushes `50 06 00 00 01 01|02` if the dashboard
  is up. Sent to R only since 2026-11-06; full removal is a follow-up. Do not
  describe `0x50` as clearing or priming the display
- `0x25` sub 4 (our "heartbeat") is really the teleprompter app-sync packet;
  link liveness is any write within 30 s on Android
- `0x3F` sub 5-8 readbacks (double-tap action, brightness %, long-press,
  head-up mic) and `0x2C 01` (firmware versions) - device-confirmed
- do-not-send: `0x4A` with bit 0 (enters DFU), `0x26` sub `0x01` (user data
  reset), `0x47` (unpair); see `docs/protocol-reference.md` § "Do-not-send list"
- `0x06` **dashboard information family** — byte 4 is a content-type
  sub-command, not a transaction step: `0x01` time/date + weather,
  `0x03` schedule/calendar, `0x04` stocks, `0x05` news, `0x06` display mode,
  `0x07` citywalk. `0x03`/`0x04`/`0x05`/`0x07` are firmware-native structured
  record types we do not use yet. Corrected 2026-09-07 from the firmware
  decomp — the old "three-step transactional wrapper" model was wrong. Any
  frame with `total=1` on `0x03`/`0x04`/`0x06` persists the dashboard layout,
  so time sync sends `06 01` alone
- `0x22` note management ack
