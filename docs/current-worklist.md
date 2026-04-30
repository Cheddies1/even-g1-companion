# Current Worklist

This is a short handoff note for new Codex sessions.

Use this with:
- [README.md](../README.md)
- [docs/current-behaviour.md](current-behaviour.md)
- [docs/current-architecture.md](current-architecture.md)
- [AGENTS.md](../AGENTS.md)

## Current Product State

Working well:
- Glance mode is a real daily-use feature
- Chat mode works end-to-end with OpenAI-backed STT + assistant responses
- Navigate mode now boots and stays alive on the firmware `0x0a` card path
  using:
  - interleaved per-leg bootstrap replay
  - live dynamic `TRIP_STATUS`
  - a 1-second `0x0a` SYNC poller
  - post-bootstrap `TRIP_STATUS + SYNC` updates
- Quick mode switching works from app UI and persistent notification
- Right-hold QuickNote POC exists for idle-only mode switching
- Per-leg BLE health and reconnect logic exists

Working, but still needs real-world observation:
- Navigate mode startup robustness on first entry / degraded-leg recovery
- Navigate mode post-bootstrap update behavior on longer real walks
- Capture mode stop/save reliability on device
- Protected notification handling for special ongoing items on Samsung/Android variants

## Current Priority Areas

1. Navigate via `0x0a` structured card (protocol confirmed, implementation in progress)
- **The full `0x0a` lifecycle renders successfully.** The 108-packet
  official lifecycle is now the known-good bootstrap path.
- **Interleaved per-leg replay is the current stable bootstrap transport.**
  Current successful mode: packet `i` to right, short delay, packet `i`
  to left, short delay, with a 50 ms pause every 10 pairs. Broadcast could
  starve a leg; full sequential replay created a large eye gap.
- **Dynamic live `TRIP_STATUS` is now injected.** The current code replaces
  only the replayed `0x0a 01` packet using live Google Maps notification
  fields. Captured `MAP_OVERVIEW` and `PANORAMIC_MAP` bytes remain unchanged.
- **The 1-second SYNC poller is now implemented and working.** Navigate stays
  alive for full routes as long as the poller is running and the session is
  not explicitly closed.
- **Post-bootstrap updates now default to `TRIP_STATUS + SYNC`.** This is the
  current experiment to reduce the occasional right-eye text loss seen when
  replaying the full 108-packet lifecycle on every guidance update.
- **Navigate mode entry is guarded against stale text fallback.** The idle
  prompt is delayed, cancelled on real render paths, and the on-glasses
  `Open Google Maps / to start navigation` fallback is explicitly closed
  before the first nav lifecycle begins.
- **Heartbeat collisions during bootstrap are currently handled.** `0x25`
  heartbeats are paused during the interleaved 108-packet burst and resumed
  afterwards to avoid degraded-leg noise during replay.
- **All three sub-types are required** for bootstrap cards: TRIP_STATUS
  (text) + MAP_OVERVIEW (13 RLE icon bands) + PANORAMIC_MAP (90 map rows).
  Text-only bootstrap cards are rejected.
- **Next steps (incremental, each testable independently):**
  1. **Watch startup robustness** — keep testing first-entry Navigate starts,
     especially cases where one leg begins degraded or reconnecting. Idle
     prompt is now suppressed to avoid the first-load race condition.
  2. **Validate `TRIP_STATUS + SYNC` updates on longer walks** — determine
     whether post-bootstrap updates are now visually solid on both eyes, or
     whether some updates still require a full lifecycle resend.
  3. **Clean up field extraction** — some Google Maps updates are still
     populating `turnDistance` with road text like `towards Milton Rd` or
     `Home (36 Campbell Rd)`. Fix the text model before treating the payload
     shape as final.
  4. ~~Build real icon/map production paths~~ — **DONE**: MAP_OVERVIEW
     direction icon now scraped from Google Maps notification PNG, decoded
     to 136×136 monochrome, RLE-encoded. Geometric arrow fallback via
     `ManoeuvreType` enum in `nav_icon_generator.dart`. PANORAMIC_MAP
     remains captured/static for now.
  5. **Production cleanup** — once bootstrap and update behavior are trusted,
     remove the replay-only scaffolding, implement proper EXIT / ARRIVED
     handling, and decide what final lifecycle shape production Navigate
     should use. Consider generating PANORAMIC_MAP (placeholder grid or
     real route map).
- BMP pipeline preserved in the codebase as fallback.
- The debug replay path and `lib/services/nav_replay_data.dart` remain in use
  for PANORAMIC_MAP bootstrap data and MAP_OVERVIEW fallback. Do not remove yet.

2. Chat streaming polish via `0x52`
- **Implemented:** Chat uses `0x52` as its on-glasses conversation surface.
  `0x50` mode control + `0x52` init + `0x53` keepalive are managed by
  `ChatService` and `Proto`.
- **Paced streaming via `StreamingRenderQueue`:** Backend chunks are
  decoupled from display updates. The backend appends raw text to a target
  buffer; the queue drains ~2 words every 150 ms and sends line 1 (empty
  cursor marker) + line 2 (all text, growing word by word) on every tick.
  The firmware handles all wrapping and scrolling natively. If text exceeds
  ~230 chars, only the tail is sent. The queue keeps draining after the
  backend stream completes until all text is displayed. The old
  `TextPainter`-based wrapping, committed-line buffer, multi-line-index
  approach (lines 1-4), and 80 ms flush timer are all removed. The
  `_charsPerLine` constant and `maxVisibleLines` are removed — the firmware
  handles wrapping. `wrapText()` still exists on `StreamingRenderQueue` for
  non-queue `0x4E` renders.
- **Official app line model (confirmed from BLE capture analysis):** the
  official Even Realities app uses only two line indices: line 1 as an
  empty cursor/status marker (always `\n`), and line 2 for ALL text
  content. Every update sends both packets. The firmware wraps at its
  display width and scrolls oldest rows off the top. New paragraphs use
  embedded `\n` within line 2. No confirmed-flag management is needed.
  The previous multi-line-index approach only showed 1-2 visible lines due
  to firmware cursor-proximity rendering. This finding is also documented
  in `protocol-reference.md`.
- **Recent fix:** `F5 00` while a Chat reply is visible now clears only the
  visible Chat display and preserves the in-memory Chat session for follow-up
  turns.
- **Next steps:**
  1. Live-validate reading pace on device — tune `wordsPerTick` (currently 2)
     and `drainInterval` (currently 150 ms) if the pace feels too fast or slow.
  2. Validate long-answer behaviour and confirm the firmware's native
     scrolling works well for extended replies.
  3. Validate follow-up turns still render correctly after the line-model
     change.

3. QuickNote via hosted transcription (future feature)
- Right-hold → `0xf1` mic audio during hold → `0x1e c8` chunked post-release
  stream (likely LC3) → existing LC3 decode path → OpenAI STT → `0x1e` TX
  note push to dashboard slots.
- All pieces exist individually; the integration is the work.

4. Notification quality
- Notification policy now supports:
  - `blocked`
  - `suppressed`
  - `protected`
  - `normal`
- Ongoing notifications are generally not ordinary Glance items
- YouTube / media protection is behaving correctly in recent logs
- pinned/live score notifications now flow through the ordinary Glance queue as `protected`
- Notification Filters UI exists for package suppression
- Runtime Settings UI now owns API key, backend overrides, notification filters, and permission shortcuts

## Recent Confirmed Findings

Battery and wear state:
- HCI snoop of the official Even Realities Android app (firmware 1.6.6)
  resolved the previously-unknown `F5` sub-codes for battery and wear:
  - `F5 06` worn, `F5 08` cradle open, `F5 0B` cradle closed
  - `F5 0A <pct>` glasses battery percentage push
  - `F5 0F <pct>` case (cradle) battery percentage push
- Now ingested by `lib/services/device_status_service.dart`
- Glasses % renders next to the Glance time line; home screen shows
  glasses %, case %, and a `Worn` / `In cradle` pill
- Full write-up in `FINDINGS-battery+brightness.md`

Brightness:
- TX `0x01 <level> <auto>` is the brightness command (level 0..42, auto 0/1)
- The glasses push `F5 12 <level>` whenever the level actually changes,
  giving a confirmation channel
- Now wired in this app: a Display section on the home screen has a
  brightness slider (commits on release) and an auto-brightness switch.
  `Proto.setBrightness` is the wire-level send; `DeviceStatusService` owns
  the locally-tracked auto flag and the echoed level.

Persisted-on-glasses settings (head-up + double-tap):
- 2026-04-28 settings capture (`FINDINGS-settings.md`)
  pinned the wire formats for both:
  - Head-up: TX `08 06 00 00 03 <value>` — `0x00` = firmware dashboard,
    `0x02` = no firmware overlay (companion app drives any visible
    response).
  - Double-tap: TX `26 06 00 <seq> 05 <value>` — `0x00` none, `0x02`
    translate, `0x03` teleprompter, `0x04` dashboard, `0x05` transcribe.
- Wired into the Settings page as a "Firmware Settings" section between
  Notification Filters and Permissions. Two dropdowns: Tilt-up behaviour
  and Double-tap behaviour. Choices are persisted in `AppSettingsStore`
  so they survive app restarts; the companion app does **not** re-send
  on connect (non-invasive). The settings themselves persist on the
  glasses' firmware regardless.

Quicknote post-release stream:
- `0x21` release is followed by a chunked binary stream on `0x1e c8 ...`,
  scaling with recording duration and shaped like a low-bitrate voice
  codec. Documented but not decoded; future feature for "companion-app
  quicknotes with hosted transcription".

Note-management family `0x06`:
- Three-step transaction with an 8-byte note UID, used by the official
  app for delete / reorder. UID shape matches the trailing block in
  `R21` payloads. Out of scope for the current app.

Rendering protocols (layouts capture):
- 2026-04-28 layouts capture (`FINDINGS-layouts.md`) discovered three new
  rendering paths the official app uses beyond `0x4E` text and BMP:
  - **`0x52` live streaming text** — word-by-word with cursor, confirmed
    with a known phrase. `0x53` keepalive every ~5 s. **Now implemented in
    Chat** via paced `StreamingRenderQueue` with sequential line-fill model
    (firmware only reliably renders lines near the cursor position).
  - **`0x0a` navigation card** — structured text data slots in one ~48-byte
    packet (ETA, distance, road, turn distance) plus optional icon/map
    bitmap chunks. The current Navigate implementation uses:
    - full 108-packet interleaved replay for bootstrap
    - dynamic live `TRIP_STATUS` replacement inside that replay
    - 1-second `SYNC` keepalive while the session is active
    - post-bootstrap `TRIP_STATUS + SYNC` updates as the current experiment
  - **`0x1e` TX dashboard data slots** — pushes titled content into the
    firmware's grid layout. Enables companion-app quicknote and dashboard
    injection features.
  - **`0x50` display mode control** — primes the display before entering
    streaming text or navigation card mode.
- `0x52` and `0x0a` are both now implemented in the companion app (Chat and
  Navigate respectively). `0x1e` dashboard injection remains a future
  protocol-driven area.

Tap and long-press mapping:
- 2026-04-28 capture (`FINDINGS-taps.md`) hardened the
  understanding of the touch family:
  - **single taps (left or right) are not surfaced over BLE in any tested
    state** (idle, dashboard with notes, dashboard with notifications). The
    firmware visibly responds on the glasses but no BLE event fires.
  - `F5 17` / `F5 18` is left long-press press-down / release (Confirmed)
  - right long-press (QuickNote) does not fire `F5 17` / `F5 18`; it fires
    `0x21` only, currently length `15` (the historical `len == 42` may have
    been a different family member or earlier firmware)
  - `F5 04` / `F5 05` triple-tap silent toggle (now Confirmed)
  - **`F5 20` is new**: fires when a double-tap triggers the official Even
    app's configured double-tap action (currently observed only with that
    action set to "transcribe")
- `F5 20` is now wired into the companion app as a passive mode-cycle hook
  via `CompanionController.handleDoubleTapModeSwitch`.
- Live testing across configurations of the official app's double-tap
  setting confirmed `F5 20` is generic to "host-handled action":
  Transcribe / Translate / Teleprompter all fire `F5 20` and the mode
  cycle works. Dashboard is firmware-native (no `F5 20`); None only fires
  `F5 00` and only when there is something to close.

Pinned score:
- `com.samsung.android.app.aodservice` is definitely observed
- In probe logs it exposed:
  - `title=Premier League`
  - `channelId=google_sports_nowbar_ongoing_channel`
  - `android.ongoingActivityNoti.secondaryInfo=ambientData:sportsScore:/g/...`
- `com.google.android.googlequicksearchbox` is also observed as a pinned live score source:
  - `channelId=XBLEND_BUBBLE_PERSISTENT_NOTIFICATION`
  - `text=Pinned live score`
  - no usable team/score/status payload was exposed in notification extras
- Live-score as an app-owned feature is parked as unviable for now
- No pinned-score probe logging should remain in the codebase

YouTube / media:
- `com.google.android.youtube` is a real package variant on this phone
- Media notifications can be `MediaStyle` with `category=transport`
- Recent policy logs showed these classifying as `protected`, not `normal`

Navigate:
- Logs captured real per-leg CRC failures and native write anomalies like `writeResult=201`
- Current diagnosis is transport-level BMP commit failure on one leg, not bitmap format error

## Useful Log Filters

Navigate BMP transport:

```powershell
adb logcat -d | Select-String "NavigateBmpTrace|NavigateBmpTraceNative"
```

Navigate bitmap generation check:

```powershell
adb logcat -d | Select-String "Navigate BMP: render complete"
```

Notification classification and routing:

```powershell
adb logcat -d | Select-String "NotificationPolicy:"
```

Google Maps payload dump:

```powershell
adb shell setprop log.tag.MapsNotificationDump DEBUG
adb logcat -d -s MapsNotificationDump
```

## Current Guardrails

Do not casually change:
- trusted gesture meanings in `AGENTS.md`
- Chat mode backend shape unless the task is Chat-specific
- general BLE framing / pairing flow
- Java/Kotlin target versions unless there is an explicit Android toolchain pass

Prefer narrow changes in:
- `lib/services/notification_policy.dart`
- `lib/services/glance_service.dart`
- `lib/services/navigate_service.dart`
- `lib/services/features_services.dart`
- `lib/controllers/bmp_update_manager.dart`

## What To Tell A Fresh Session

Good first prompt pattern:
- say which single area is being worked on now
- mention whether the issue is:
  - Chat `0x52` streaming / render queue
  - notification policy
  - Navigate `0x0a` card
  - Capture validation
- point the agent to:
  - `AGENTS.md`
  - `README.md`
  - `docs/current-behaviour.md`
  - `docs/current-architecture.md`
  - this file

## Files Most Likely Relevant Next

- [lib/services/chat_service.dart](../lib/services/chat_service.dart)
- [lib/services/streaming_render_queue.dart](../lib/services/streaming_render_queue.dart)
- [lib/services/notification_policy.dart](../lib/services/notification_policy.dart)
- [lib/services/glance_service.dart](../lib/services/glance_service.dart)
- [lib/services/companion_controller.dart](../lib/services/companion_controller.dart)
- [lib/services/navigate_service.dart](../lib/services/navigate_service.dart)
- [lib/services/features_services.dart](../lib/services/features_services.dart)
- [lib/controllers/bmp_update_manager.dart](../lib/controllers/bmp_update_manager.dart)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)
