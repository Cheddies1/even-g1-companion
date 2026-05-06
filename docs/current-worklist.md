# Current Worklist

This is a short handoff note for new Codex sessions.

Use this with:
- [README.md](../README.md)
- [docs/current-behaviour.md](current-behaviour.md)
- [docs/current-architecture.md](current-architecture.md)
- [AGENTS.md](../AGENTS.md)

---

## Current Product State

Working well:
- Glance mode is a real daily-use feature
- Chat mode works end-to-end with OpenAI-backed STT + assistant responses, paced `0x52` streaming, host-managed scrolling
- Navigate mode boots and stays alive on the firmware `0x0a` card path (full 108-packet interleaved replay, dynamic TRIP_STATUS, 1-second SYNC poller, post-bootstrap TRIP_STATUS+SYNC updates, idle-prompt suppression)
- Quick mode switching works from app UI and persistent notification
- Right-hold QuickNote POC exists (gesture captured; transcription not yet wired)
- Per-leg BLE health and reconnect logic exists
- Battery + wear state ingested and displayed (home screen pills, Glance HUD)
- Brightness slider + auto toggle (push side)
- Firmware settings dropdowns (head-up behaviour + double-tap action) on Settings page
- Double-tap mode switch via `F5 20`
- Notification policy (blocked / suppressed / protected / normal), Filters UI, Runtime Settings UI

Working, but still needs real-world observation:
- Navigate mode startup robustness on first entry / degraded-leg recovery
- Navigate mode post-bootstrap update behaviour on longer real walks
- Capture mode stop/save reliability on device
- Protected notification handling for special ongoing items on Samsung/Android variants

---

## Now / In Flight

Nothing currently in flight. Top of Next: Navigate cleanup.

---

## Next — Prioritised

### 1. Navigate cleanup (composite)
- **Status**: Next
- **Priority**: Medium
- **Context**: Navigate is functionally working on the `0x0a` structured-card path. Several cleanup tasks remain before it can shed its debug scaffolding. Eddie expects most are straightforward.
- **Acceptance** — all of the following:
  - [ ] **Startup robustness** — keep observing first-entry Navigate starts, especially cases where one leg begins degraded or reconnecting. Idle prompt is now suppressed; verify no regressions.
  - [ ] **Field extraction cleanup** — fix `turnDistance` being populated with road text such as `towards Milton Rd` or `Home (36 Campbell Rd)`. Tighten the Google Maps notification parsing model.
  - [ ] **Proper EXIT / ARRIVED handling** — sessions are currently torn down via the existing exit path, but the `0x0a 05` EXIT and `0x0a 06` ARRIVED sub-commands are not used cleanly.
  - [ ] **Replay scaffolding decision** — `lib/services/nav_replay_data.dart` and the debug 108-packet replay path remain in use for PANORAMIC_MAP bootstrap and as MAP_OVERVIEW fallback. Once bootstrap and update behaviour are trusted, decide what to keep, what to relabel as production-fallback, and what to remove. Do NOT remove yet.
- **Notes**: Cross-ref `docs/FINDINGS-layouts.md`, `lib/services/navigate_service.dart`, `lib/services/nav_icon_generator.dart`. See the related Parked item on PANORAMIC_MAP.

### 2. QuickNote via hosted transcription (experiment)
- **Status**: Next
- **Priority**: Medium
- **Context**: Right-hold gesture surfaces as `0x21` press, followed by a chunked `0x1e c8 ...` audio-shaped stream after release. The shape is consistent with low-bitrate voice; the existing LC3 decode path (used by Capture and Chat) may handle it. End-to-end flow: `0x21` release → buffer chunked stream → LC3 decode → OpenAI STT → push note text via `0x1e` dashboard slot.
- **Acceptance**: Working POC where a right-hold quicknote on the glasses produces a transcribed note pushed back to the firmware dashboard. All pieces exist individually; integration is the work.
- **Notes**: This is an experiment — the first goal is to confirm LC3 decodes the post-release stream. Cross-ref `docs/FINDINGS-taps.md` and `docs/FINDINGS-layouts.md`.

---

## Backlog — Unprioritised

### dashboard-injection: Dashboard content injection
- **Status**: Backlog
- **Priority**: Low
- **Context**: `0x1e` TX can push titled content into the firmware's dashboard grid layout — useful for summaries, reminders, or status info.
- **Acceptance**: Demonstrable injection of titled content into a dashboard slot, with a real use case identified.
- **Notes**: Eddie's view: "Probably less useful than QuickNote unless you have a clear use case." Open question: what would actually go in the slot? Demoted from Next — lacks a concrete use case. Revisit when a clear scenario emerges.

### now-playing-mediasession: Now Playing: extract MediaSession metadata for apps with empty notification fields
- **Status**: Backlog
- **Priority**: Unprioritised
- **Context**: Some media apps (confirmed: Audible / `com.audible.application`) send `MediaStyle` notifications with `category=transport` but leave all content fields (`title`, `text`, `subText`) as empty strings. The actual track/chapter/artist metadata lives in the `MediaSession.metadata` object, not in the notification's `extras` bundle. `RecentNotificationsListenerService.kt` only extracts standard notification text fields — it does not read `MediaSession` metadata.
- **Evidence (2026-05-06 logs)**:
  - Flutter side: `title="" text="" subText="" category=transport media=true template="android.app.Notification$MediaStyle"` — all content fields empty
  - System UI side: `metaData=The Wee Free Men, Chapter 7: First Sight and Second Thoughts, Terry Pratchett` — full metadata available in the `MediaSession`
- **Proposed fix**: Enhance `RecentNotificationsListenerService.kt` to detect `MediaStyle` notifications and, when standard title/text fields are empty, fall back to extracting `MediaMetadata.METADATA_KEY_TITLE` and `MediaMetadata.METADATA_KEY_ARTIST` from the notification's associated `MediaSession`. The `MediaSession.Token` is available in notification extras under `android.mediaSession`.
- **Acceptance**: Audible (and similarly-behaving apps) produce a non-empty title/text pair that the Now Playing feature can display on the glasses. Apps that already populate standard notification fields (Spotify, YouTube Music, Podcast Addict) are unaffected.
- **Notes**: Low urgency — the feature works correctly for the three most common music/podcast apps. Audible is the only confirmed failure case. Other audiobook/podcast apps may behave similarly and would benefit automatically. Files likely touched: `android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt`, possibly `lib/models/companion_notification.dart` if new fields are added for media metadata.

### ghost-listening-screen: Investigate firmware "listening" screen on display clear
- **Status**: Backlog
- **Priority**: Unprioritised
- **Context**: When the app sends a screen-clear command, the G1 firmware occasionally displays the "Even AI is listening, release to finish recording" screen instead of clearing cleanly. This suggests the clear/exit command sequence may be inadvertently triggering a firmware listening state.
- **Investigation needed**: Check what `Proto.exit()` (`0x18`) and `TextService.stopTextSendingByOS()` actually send. Cross-reference with `docs/protocol-reference.md`, `docs/external-protocol-wiki-notes.md`, and Gadgetbridge `G1Constants.java`. Determine whether there is a sequence that produces a clean screen clear without triggering the voice prompt.
- **Acceptance**: Root cause identified. Either confirmed that the current sequence is correct (and the ghost screen is a firmware quirk), or a cleaner alternative command sequence is identified and implemented.
- **Notes**: Pre-existing issue, not caused by recent changes. Requires protocol investigation before a fix can be designed. Files likely involved: `lib/services/proto.dart` (`exit()`, line ~475), `lib/services/text_service.dart` (`stopTextSendingByOS()`), `docs/protocol-reference.md`.

### ongoing-call-idle: Ongoing call idle surface
- **Status**: Backlog
- **Priority**: Unprioritised
- **Context**: When a phone call is active, the idle surface (what the glasses show when the display times out and the user looks forward) should become a persistent call HUD rather than going blank. The feature leverages the existing `GlanceService.showIdleSurfaceIfAvailable()` stub (currently returns false) as the exact insertion point — the controller calls it after `close()` fires on tilt-down timeout.
- **Design** (fully specified, capture faithfully):
  - **Detection**: Call notifications are typically `category == 'call'` and `isOngoing == true`. Expected source: Samsung dialer (`com.samsung.android.incallui` or similar). Fields likely include: `source="Call"`, `title=<caller name>`, duration in `text` or `subText`. A log capture during a real call will confirm exact field names and package — treat this as a small precursor investigation embedded in this item.
  - **Idle surface hook**: After `close()` fires (tilt-down timeout), `CompanionController` calls `GlanceService.showIdleSurfaceIfAvailable()`. If a call is active, this renders the call HUD instead of going blank. The stub already exists; the implementation fills it in.
  - **Duration updates**: Android fires periodic notification updates during a call (duration ticking). Each update refreshes `_currentCall` and re-renders the idle surface — duration stays live with no separate timer needed.
  - **Interaction model**:
    - Looking forward (idle): `Ongoing call: Andy Hulbert` + `Call time: 35:12` (persistent, refreshed by notification updates)
    - Tilt up: normal notification carousel (existing behaviour, unchanged)
    - Tilt down / timeout: returns to call idle surface (not blank)
    - Call ends: notification removed, `_currentCall` cleared, idle reverts to blank
  - **Reference screenshot**: `logs/images/ongoing-call.jpg`
- **Acceptance**: When a call is active and the display times out, the glasses show the caller name and live call duration. Tilt-up opens the notification carousel as normal. When the call ends the idle surface clears.
- **Notes**: Precursor investigation — do a log capture during a real call to confirm: Samsung dialer package name, exact notification field names for caller name and duration, and whether `isOngoing` is the reliable discriminator. Keep this investigation inside the item rather than as a separate entry. Implementation files likely involved: `lib/services/glance_service.dart` (`showIdleSurfaceIfAvailable`), `lib/services/companion_controller.dart` (post-`close()` call path), `lib/services/notification_policy.dart` (call detection / `_currentCall` state).

---

## Parked

### PANORAMIC_MAP decision
- **Status**: Parked — decision pending
- **Context**: The 488×136 PANORAMIC_MAP region is shown in the glasses' "look up" mode and is a large piece of screen real estate. Currently the app sends a static capture taken from the official app during a previous route — meaning it looks like a map and feels like a map but is NOT active to the user's actual location. Eddie considers this misleading.
- **Why parked**: Eddie cannot currently think of anything genuinely useful to do with it. The ideal would be a real-time map of the user's current surroundings (a few hundred metres around current location, NOT tied to the active route) rendered as a line drawing — but that requires maps-service integration, current-location handling, and an image pipeline to render the map as 488×136 monochrome. Eddie's words: "feels like a big lift for a nice-to-have".
- **Three options on the table**:
  1. Keep static forever (current behaviour — but misleading)
  2. Generate a neutral placeholder (decorative, honest about not being a map)
  3. Build the real local-surroundings line-drawing path (significant lift, maps-service dependency)
- **Constraint**: Do NOT attempt to render the user's actual route geometry — Google Maps notifications do not expose the geometry, and that path is described as "tiny cartography hell".
- **Revival trigger**: Revisit if a clear use case emerges, or if the static capture becomes actively annoying enough to warrant the placeholder fix.

---

## Recently Done

### BLE connection stability and auto-reconnection (2026-05-06)
Three capabilities implemented across 5 files (`app_settings_store.dart`, `device_status_service.dart`, `ble_manager.dart`, `companion_controller.dart`, `home_page.dart`). (1) Post-disconnect auto-reconnect with exponential backoff: immediate → 30 s → 60 s → 120 s → give up. (2) Cradle-aware smart disconnect: skips reconnect when last persisted wear state was "in cradle" (`F5 08` / `F5 0B`). (3) Auto-connect on app launch using persisted `ble.last_channel_number`. Also fixed a critical bug: `_onGlassesDisconnected()` was dead code — disconnect timer cleanup never ran; fixed via `wasConnected && !isConnected` transition detection in `_applyConnectionPayload()`. New persisted settings: `ble.last_channel_number`, `ble.last_wear_state`. UI shows "Reconnecting..." during backoff attempts.

### Glance: tilt-down display stuck bug fixed (2026-05-06)
The tilt-down handler (case 3, `F5 03`) in `companion_controller.dart` had an early `break` when cancelling a pending tilt-up intent, which skipped calling `GlanceService.startLookDownTimeout()`. If the display was already visible from a previous confirmed intent or notification auto-pop, the clear timer never started and the display stayed on the glasses indefinitely. Fix: `startLookDownTimeout()` is now called unconditionally on every tilt-down in Glance mode. The method's own `if (!_isVisible) return;` guard makes it a safe no-op when the display is not visible. One case block changed; no new fields or methods.

### Glance: "Now Playing" media integration (2026-05-06)
Media notifications from streaming apps are now absorbed into Glance line 1 instead of cycling through the notification carousel. Line 1 shows `12:41  |  100%  |  ▶ Green Day - Dookie` when playback is active; reverts to `12:41  |  100%` when stopped. New `NotificationDisposition.mediaAbsorbed` classification. Two-tier detection: auto-detect (`isMediaStyle && category == transport`) plus per-app "Now Playing" toggle in Settings. Track text truncated with `...` at 43-char display width. DB migrated v1 → v2 (`media_override` column). Settings UI gains two toggles per app: "Now Playing" and "Mute". 6 files changed: `notification_policy.dart`, `notification_settings_store.dart`, `notification_package_preference.dart`, `glance_service.dart`, `companion_controller.dart`, `settings_page.dart`.

### Glance: notification display reworked to 3-line format (2026-05-04)
`lib/services/glance_service.dart` (`_buildDisplayText`). The Glance notification HUD is now a compact 3-line layout: line 1 shows `HH:MM  |  <battery>` (pipe separator between time and battery); line 2 shows `<source>  ·  HH:MM` (mid-dot separator between source and posted time); line 3 is the message content, wrapping naturally via TextService. Earlier in the day the posted time was added as a fourth line; this follow-up merged source and posted time onto one line and dropped the count to three. No model or protocol change — `CompanionNotification.postedAt` was already populated. The "No notifications" idle branch is unchanged. Build green; no new analysis issues.

### Authoritative settings reconcile — brightness, auto, head-up, double-tap (2026-05-01)
Device testing confirmed complete. Settings persist across cold launches; slider loads its last position from `AppSettingsStore` on startup. All four firmware settings (brightness level, auto-brightness, head-up behaviour, double-tap action) re-assert on every BLE reconnect — even when the official Even Realities app has written different values in between.

### Brightness readback investigation (2026-05-01)
Empirical testing pinned `0x29` as the brightness GET path (level only; the wiki's claim that byte 3 carries the auto flag was not reproduced). Identified triggers for `0x6e` (TX `23 74`), `0x3e` (TX `3e`), and `0x2c` (host poll, not unsolicited firmware push). Confirmed the right-temple ambient light sensor location. Confirmed `F5 12` already fires unprompted ~15 s after connect with the current level. Decision: pivot to authoritative settings model rather than firmware readback — companion app re-pushes all four settings on every BLE reconnect (see 2026-05-01 authoritative settings entry above). Full protocol detail in `docs/FINDINGS-battery+brightness.md`.

### Chat `0x52` streaming (Confirmed, 2026-05-01)
Paced streaming via `StreamingRenderQueue` is fully implemented in Chat. Backend chunks are decoupled from display: the queue drains 2 words every 200 ms (~450 WPM effective with BLE overhead), wraps at 43-char word boundaries, and keeps only the last 3 lines — matching the firmware's 3 visible rows. The firmware does NOT auto-scroll; the host manages scrolling. Line 1 carries a `\n` marker; line 2 carries all visible text. Follow-up turns do `Proto.exit()` only when a prior `0x52` session is active. Full reference detail is in `AGENTS.md` and `docs/FINDINGS-layouts.md`.

### Battery + wear state
`F5 06/08/0B/0A/0F` ingestion wired into `DeviceStatusService`. Glasses battery % displays next to the Glance time line; home screen shows glasses %, case %, and a Worn / In cradle pill.

### Brightness slider + auto toggle (push side)
`0x01 <level> <auto>` set wired via `Proto.setBrightness`. `F5 12 <level>` echo handled by `DeviceStatusService`. Home screen Display section has a brightness slider (commits on release) and an auto-brightness switch.

### Firmware settings dropdowns (push side)
Head-up behaviour (`0x08`) and double-tap action (`0x26`) wired as dropdowns on the Settings page. Choices persisted in `AppSettingsStore`; companion app does not re-send on reconnect (non-invasive — superseded by authoritative model, see 2026-05-01 entry above).

### Double-tap host-action mode switch
`F5 20` wired to `CompanionController.handleDoubleTapModeSwitch`. Cycles companion app modes when the official app's double-tap action is set to a host-handled type (Transcribe / Translate / Teleprompter).

### Navigate `0x0a` lifecycle proven
Full 108-packet interleaved replay renders on the glasses. Dynamic TRIP_STATUS injection from live Google Maps fields is working. MAP_OVERVIEW direction icon is dynamically generated from the Google Maps notification PNG (decoded to 136×136 monochrome, RLE-encoded), with geometric arrow fallback via `ManoeuvreType` enum. 1-second SYNC poller keeps the session alive. Post-bootstrap updates use TRIP_STATUS+SYNC. Idle-prompt suppression prevents first-load race conditions.

---

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
- `0x29` is the brightness GET path (level only); the auto flag is NOT
  readable back — the wiki's byte-3 auto claim was not reproduced in testing
- `0x2c` is a host-poll opcode (the host sends it; not an unsolicited push from
  the firmware). Do not treat it as a proactive status broadcast.
- The ambient light sensor used for auto-brightness is physically located in
  the right temple of the glasses

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
  on connect (non-invasive — superseded by authoritative model, see 2026-05-01 Recently Done). The settings themselves persist on the
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
  - **`0x52` live streaming text** — word-by-word with cursor, `0x53`
    keepalive every 5 s. **Fully implemented in Chat** (`Confirmed`,
    2026-05-01) via paced `StreamingRenderQueue` with host-managed
    scrolling: 43 chars/row, 3 visible rows, 2 words/tick at 200 ms.
    The firmware does NOT auto-scroll; the host wraps at word boundaries
    and trims to the last 3 lines.
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

---

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

---

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

---

## What To Tell A Fresh Session

Good first prompt pattern:
- say which single area is being worked on now
- mention whether the issue is:
  - Navigate `0x0a` cleanup (`navigate_service.dart`, `nav_icon_generator.dart`) — top of Next; field extraction, EXIT/ARRIVED, replay scaffolding decision
  - QuickNote transcription experiment (`0x21` + LC3 + STT) — Next #2
  - notification policy
  - Capture validation
- point the agent to:
  - `AGENTS.md`
  - `README.md`
  - `docs/current-behaviour.md`
  - `docs/current-architecture.md`
  - this file

---

## Files Most Likely Relevant Next

- [lib/services/chat_service.dart](../lib/services/chat_service.dart)
- [lib/services/streaming_render_queue.dart](../lib/services/streaming_render_queue.dart)
- [lib/services/notification_policy.dart](../lib/services/notification_policy.dart)
- [lib/services/glance_service.dart](../lib/services/glance_service.dart)
- [lib/services/device_status_service.dart](../lib/services/device_status_service.dart)
- [lib/services/companion_controller.dart](../lib/services/companion_controller.dart)
- [lib/services/navigate_service.dart](../lib/services/navigate_service.dart)
- [lib/services/features_services.dart](../lib/services/features_services.dart)
- [lib/controllers/bmp_update_manager.dart](../lib/controllers/bmp_update_manager.dart)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)
