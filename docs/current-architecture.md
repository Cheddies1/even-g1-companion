# Current Architecture

> **Document type:** App implementation
> **Audience:** Eddie + AI agents working on the EvenDemoApp codebase
> **Evidence basis:** App source code + capture-driven design decisions

This file describes the current stable architecture of the app as it exists now.

It is the architecture view for the current companion app, not the old demo framing.

## Document map
- [current-behaviour.md](current-behaviour.md): user-visible behaviour and caveats
- [even-g1-event-mapping.md](even-g1-event-mapping.md): current trusted event meanings
- [protocol-reference.md](protocol-reference.md): wire-level G1 BLE command catalogue
- [investigation-notes.md](investigation-notes.md): broader exploratory findings and hypotheses

## Product shape

The app is now a mode-based personal companion app for Even G1 glasses.

Modes:
- `glance`
- `capture`
- `navigate`
- `chat`

Only one mode is active at a time.

Current implementation state:
- `glance`: implemented and actively used
- `capture`: implemented for practical on-device use, still needs ongoing validation
- `navigate`: implemented using the structured `0x0a` navigation card protocol — 108-packet interleaved bootstrap, dynamic TRIP_STATUS and MAP_OVERVIEW, 1-second SYNC poller; working for walking navigation, still open to incremental tuning
- `chat`: implemented as a practical v1 voice loop

## Android build baseline

Current Android toolchain baseline:
- AGP `8.6.1`
- Gradle wrapper `8.7`
- Kotlin Gradle plugin `2.1.10`

This is the practical baseline to preserve unless there is a deliberate upgrade pass.

## Startup flow

Flutter startup is intentionally ordered so the phone UI can come up first:
- `runApp()` happens before companion initialization completes
- companion initialization is asynchronous
- native method-channel handlers must always resolve successfully or return `notImplemented`

This matters at startup because early Android-side calls can arrive before background companion setup is finished.

As part of `CompanionController.init()`, the controller calls `attemptAutoConnect()`. This reads `ble.last_channel_number` and `ble.last_wear_state` from `AppSettingsStore`. If a prior channel number exists and the last wear state was not `inCradle`, a BLE scan is started immediately so the app reconnects to the known glasses without any manual action. If the last wear state was `inCradle`, the scan is suppressed.

## Core controller

Mode ownership is centralised in:
- [lib/services/companion_controller.dart](../lib/services/companion_controller.dart)

The controller owns:
- active mode
- active-display-state decision making
- interpretation of trusted glasses events
- routing into mode-specific services
- notification event subscription
- background-mode synchronisation with the Android foreground service

Supporting model:
- [lib/models/app_mode.dart](../lib/models/app_mode.dart)

Current mode vs active display:
- `current mode` means which service should own the next interaction
- `active display` means whether something is currently being shown on the glasses right now
- quick mode switching depends on `active display`, not only on `current mode`

Current active-display sources:
- visible Glance item
- active Capture display
- visible Navigate card
- visible Chat content

## Main services

### Glance
- [lib/services/glance_service.dart](../lib/services/glance_service.dart)
- [lib/services/glance_assistant_service.dart](../lib/services/glance_assistant_service.dart)

Owns:
- recent notification feed
- text rendering for Glance items
- auto-pop / deliberate recall timing
- phone-side dismissal of deliberately viewed notifications
- Glance-only assistant shortcut state and ephemeral follow-up context
- media state (`_currentMedia`): updated live via `updateMedia()` when a `mediaAbsorbed` notification arrives, cleared via `clearMedia()` when that notification is removed; rendered as the `▶ Artist - Track` suffix on Glance line 1
- call state (`_currentCall`): updated live via `updateCall()` when a `callAbsorbed` notification arrives, cleared via `clearCall()` when that notification is removed; drives the call HUD idle surface (see below)

**Idle surface** — when `close()` fires (tilt-down timeout or carousel advance exhaustion) and `_currentCall` is non-null, `GlanceService` does **not** call `Proto.exit()` and go blank. Instead it sets `_isIdleSurfaceActive = true`, enqueues a render via the call HUD text builder, and starts a 1 Hz `Timer.periodic` (`_callTimer`) that re-renders the duration every second. This branch is embedded directly in `close()`. A separate public method `showIdleSurfaceIfAvailable()` provides the same transition and returns `false` when no call is active (intended for external callers who need to explicitly activate the idle surface). Tilt-up clears `_isIdleSurfaceActive` and cancels `_callTimer`, restoring normal carousel behaviour. Call end (`clearCall()`) cancels the timer, clears `_isIdleSurfaceActive`, and calls `close()` to tear down via `Proto.exit()`.

### Capture
- [lib/services/capture_service.dart](../lib/services/capture_service.dart)

Owns:
- capture session state
- start / stop / cancel flow
- recording indicator / save confirmation rendering
- bridge calls into native WAV recording

### Navigate
- [lib/services/navigate_service.dart](../lib/services/navigate_service.dart)
- [lib/services/nav_icon_generator.dart](../lib/services/nav_icon_generator.dart)
- [lib/services/navigate_bitmap_service.dart](../lib/services/navigate_bitmap_service.dart)

Owns:
- latest maps-derived guidance model
- suppression / prioritisation rules relative to Glance
- **uses the structured `0x0a` navigation card protocol**. The bootstrap
  path replays 108 captured official-app packets through
  [Proto.sendNavBootstrap](../lib/services/proto.dart) using
  interleaved per-leg fire-and-forget transport, with two dynamic
  replacements:
  1. `TRIP_STATUS` — rebuilt from live Google Maps notification fields
  2. `MAP_OVERVIEW` — direction icon scraped from the Google Maps
     notification PNG (`navIconPngBase64`), decoded to 136×136 monochrome
     via alpha threshold, RLE-encoded, padded to 13 bands. Falls back to
     geometric arrow generation (`ManoeuvreType` enum) if PNG unavailable,
     then to captured data. See
     [nav_icon_generator.dart](../lib/services/nav_icon_generator.dart).
- captured `PANORAMIC_MAP` bytes remain unchanged (static route map)
- owns the real 1-second `0x0a` SYNC poller for active Navigate sessions and
  the post-bootstrap update-mode switch (`fullLifecycleUpdate` vs
  `tripStatusOnlyUpdate`)
- the BMP pipeline ([NavigateBitmapService](../lib/services/navigate_bitmap_service.dart))
  is preserved in the codebase but no longer called from the main Navigate
  render path
- `DirectionTurn` byte in TRIP_STATUS is classified by `classifyManoeuvre()`
  which parses both `navIconSource` and instruction text (turnDistance +
  roadName) for direction keywords. `ManoeuvreType` enum maps to firmware
  byte values 0x01–0x0b.
- `NavigateService.showIdlePrompt()` is suppressed — no text is sent to the
  glasses on mode entry. This avoids a race condition where `Proto.exit()`
  (needed to clean up idle text) completed mid-replay, blanking the display.
  The glasses stay on whatever was shown before until the first Maps
  notification triggers the full nav card bootstrap.

### Device status
- [lib/services/device_status_service.dart](../lib/services/device_status_service.dart)

Owns:
- glasses battery percentage (push from `F5 0A`)
- case (cradle) battery percentage (push from `F5 0F`)
- wear state derived from `F5 06` / `F5 08` / `F5 0B`
- brightness level (echo from `F5 12`)
- auto-brightness flag (locally tracked from the last sent
  `0x01 <level> <auto>` because the firmware does not echo it back)
- the brightness command path itself, via `setBrightness(level, auto)`,
  delegating the wire-level send to
  [Proto.setBrightness](../lib/services/proto.dart)
- head-up (tilt-up) mode and double-tap action — the user's last picks
  from the Settings page, with the BLE writes delegated to
  [Proto.setHeadUpMode](../lib/services/proto.dart)
  and
  [Proto.setDoubleTapAction](../lib/services/proto.dart)
  and the cross-session persistence delegated to
  [AppSettingsStore](../lib/services/app_settings_store.dart)

Behaviour:
- ingests every `0xF5` event via a single entry point called from
  [lib/ble_manager.dart](../lib/ble_manager.dart)
- only notifies listeners when a value actually changes, so the per-1–2-second
  re-pushes the firmware emits while the glasses are worn do not churn the UI
- resets to defaults on full disconnect so stale values are not displayed
- accepts updates from either temple; the glasses share a single battery, so
  whichever side reports last wins
- **wear state is persisted to `AppSettingsStore` (`ble.last_wear_state`) on
  every `F5` wear-state change.** This allows the auto-reconnect logic in
  `BleManager` to make a cradle-aware decision even after the app has been
  restarted — see "Auto-reconnect" in the "Transport health and recovery"
  section below.

Consumers:
- [lib/services/glance_service.dart](../lib/services/glance_service.dart)
  reads the glasses battery label at render time so the Glance heads-up display
  shows e.g. `14:32  85%` next to the time
- [lib/views/home_page.dart](../lib/views/home_page.dart)
  subscribes to the service and renders glasses %, case %, and the worn /
  in cradle state as status pills, plus the Display section with brightness
  slider and auto switch

### Chat
- [lib/services/chat_service.dart](../lib/services/chat_service.dart)
- [lib/services/streaming_render_queue.dart](../lib/services/streaming_render_queue.dart)
- [lib/services/chat_backend.dart](../lib/services/chat_backend.dart)
- [lib/services/openai_chat_backend.dart](../lib/services/openai_chat_backend.dart)
- [lib/services/openai_transcription_service.dart](../lib/services/openai_transcription_service.dart)
- [lib/services/app_settings_store.dart](../lib/services/app_settings_store.dart)

Owns:
- Chat mode session lifecycle
- in-memory turn history while Chat mode remains active
- start / stop / submit flow driven by trusted gestures
- STT handoff
- backend request / response handling
- concise text-state rendering back to the glasses
- Chat uses the confirmed `0x52` streaming text protocol as its on-glasses
  conversation surface (`Confirmed`, 2026-05-01).
  `Proto.startStreamingText()` sends `0x50` display-mode control and the
  `0x52` init frame. `0x53` keepalive runs every 5 s while the `0x52`
  surface is active.
- **Paced streaming via `StreamingRenderQueue`:** Backend chunks are
  decoupled from display updates. The backend appends raw text to a target
  buffer; a separate `StreamingRenderQueue` drains that buffer at a paced
  cadence (2 words every 200 ms, ~450 WPM effective with BLE overhead).
  Each tick: adds 2 words to the displayed text, wraps with `\n` at
  43-char word boundaries, keeps only the last 3 lines (matching the
  firmware's 3 visible rows), and sends line 1 (`\n` marker) + line 2
  (visible text) via `Proto.sendStreamingLine`. The host manages
  scrolling — the firmware does NOT auto-scroll. The `wrapText()` static
  method still exists on `StreamingRenderQueue` for non-queue `0x4E`
  renders. The queue keeps draining after the backend stream completes
  until all text is displayed, then signals completion via `onDrained`.
- **Firmware display characteristics (`Confirmed`, 2026-05-01):** 3
  visible text rows, ~43 characters per row (proportional font). The
  firmware wraps at its display width and respects embedded `\n` as line
  breaks, but does NOT scroll — the host trims to the last 3 lines.
  Character-wraps mid-word at the display boundary.
- **Official app line model (`Confirmed`, 2026-05-01):** the official Even
  Realities app uses only two `0x52` line indices: line 1 as a
  cursor/status marker (a regular text packet with `\n` content, NOT a
  special cursor frame), and line 2 for all text content. Every update
  sends both packets. No confirmed-flag management is needed. The previous
  multi-line-index approach (lines 1-4 with host-side `TextPainter`
  wrapping and committed-line buffers) only rendered 1-2 visible lines due
  to firmware cursor-proximity behaviour.
- Chat keeps a **display buffer** separate from backend message history.
  The display buffer is the on-glasses conversation surface (`You:` / `G1:`),
  with committed wrapped lines. During assistant streaming the queue takes
  over the glasses display entirely — the user question is shown before
  streaming (in the "Thinking..." frame) and committed after streaming, but
  not interleaved with the streaming assistant text. The backend message
  list remains the source of truth for conversational context.
- `F5 00` while a Chat reply is merely visible now closes the visible Chat
  display without discarding the in-memory session. A full Chat session reset
  still happens on mode switch away from Chat or explicit session teardown.

Current backend seam:
- `ChatService` depends on the `ChatBackend` abstraction, not a controller-level hardcoded backend
- the current v1 implementation uses an OpenAI-compatible backend and OpenAI transcription API
- runtime backend settings are resolved through `AppSettingsStore` first, then `dart-define` fallbacks
- the API key is stored locally in secure storage; non-secret overrides use app preferences
- the backend can be replaced later without rewriting mode ownership

## Quick mode switching

Quick switching is routed centrally through:
- [lib/services/companion_controller.dart](../lib/services/companion_controller.dart)

Input paths:
- Android foreground notification action buttons
- phone UI mode selector
- idle-only right-hold QuickNote POC via right-leg `R21`

Notification path:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)
- [lib/ble_manager.dart](../lib/ble_manager.dart)

Current behaviour:
- notification actions request a passive mode switch
- the controller performs the actual switch
- the foreground notification is updated to reflect the new mode
- tapping the notification body opens the main app screen
- a narrow `R21` hook in `BleManager` can also request an idle-only passive mode switch during QuickNote POC testing

Phone UI path:
- the home screen mode buttons route through the same central controller `setMode(...)` path
- mode selection is immediate and does not depend on a temporary title-card overlay

Long-press-right release (`0x21`):
- `BleManager._logCmd21(...)` observes `0x21` and emits the `QuickNoteProbe`
  diagnostic log for right-leg packets, surfacing length / payload / mode
  context for the QuickNote pipeline to consume
- mode-switching on long-press-right was retired on 2026-05-08; double-tap
  is now the sole mode-switch surface (see `handleDoubleTapModeSwitch`)

Double-tap mode-switch path:
- `BleManager` F5 dispatch routes `case 32:` (= `F5 0x20`) to
  `CompanionController.handleDoubleTapModeSwitch()`
- the controller cycles through the four modes via `AppMode.nextMode`
- repeated triggers debounced at `1500ms`
- no `hasActiveDisplay` check is needed here because the firmware emits
  `F5 00` (close-active) instead of `F5 20` when a feature is already up
- depends on the official Even Realities app's double-tap action being set to
  a **host-handled** feature: confirmed working with Transcribe, Translate,
  and Teleprompter. Setting it to Dashboard or None routes the gesture
  inside the firmware and `F5 20` is not emitted.
- the on-glasses overlay for the configured action briefly appears alongside
  the mode switch and cannot be suppressed from the companion side

Glasses close path:
- `F5 00` has one trusted meaning only:
  - if something is active on the glasses, close it
  - if the display is idle, do nothing

Current request shaping:
- the OpenAI-compatible backend applies a glasses-specific system prompt
- request output is bounded with a max completion token limit
- response text is also capped locally before being rendered to the glasses
- the backend now exposes both one-shot and streamed response paths through
  the `ChatBackend` abstraction; Chat mode uses the streamed path first and
  falls back to one-shot rendering if needed

Current session-history behaviour:
- the full in-memory Chat turn list is tracked while Chat mode stays active
- requests currently send only the most recent history window when the conversation grows beyond a light cap
- there is no summarisation in this phase
- the cap is intentionally light-touch so useful follow-up context is preserved for normal conversations

Current mode-entry idle displays:
- `capture`: `*`
- `chat`: `Chat ready` / `Tilt up to talk`
- `navigate`: idle prompt is suppressed — no text sent to the glasses on mode
  entry. The first Maps notification triggers the full nav card bootstrap.
- `glance`: no separate idle title card; content appears only when a Glance item is actually shown

Glance assistant:
- while in Glance mode and idle, left-hold enters a lightweight assistant flow without changing mode
- the firmware owns the listening overlay during hold
- after release, Flutter reuses the existing OpenAI transcription and backend request path
- follow-ups use a small in-memory mini-session that expires after roughly 4 minutes of inactivity
- this mini-session is separate from Chat mode and is not persisted to the Chat log

## BLE and protocol path

The app intentionally preserves the working BLE and protocol foundation from the old demo app.

Flutter entry:
- [lib/ble_manager.dart](../lib/ble_manager.dart)

Key protocol helper:
- [lib/services/proto.dart](../lib/services/proto.dart)

Native BLE manager:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)

Key preserved behaviours:
- dual-leg scan/connect
- left/right pairing by channel
- native GATT notification setup
- existing text rendering send path
- existing LC3 decode path

## Transport health and recovery

Transport health is now modelled per leg in:
- [lib/ble_manager.dart](../lib/ble_manager.dart)

Current model:
- left and right legs each track:
  - connected state
  - health state: `healthy`, `degraded`, `disconnected`
  - last heartbeat timestamp
  - last acknowledged command timestamp
  - bounded reconnect attempt count

Heartbeat handling:
- `0x25` is sent per leg on a timer
- heartbeat success marks that leg healthy
- repeated heartbeat/request timeouts degrade that leg
- a stale leg can be treated as degraded even before a full disconnect is reported

Reconnect handling (per-leg):
- degraded legs trigger bounded reconnect attempts through the native bridge
- reconnect is per-leg, not always full-session teardown
- reconnect attempts are intentionally bounded to avoid loops or storms

Resync handling:
- when a degraded leg recovers, Flutter requests a lightweight content resync
- active Navigate content is rerendered through the current Navigate render path
- active text content is replayed through the shared text renderer
- this is intended to help left/right displays converge again after one-leg transport degradation

Navigate-specific transport protection:
- `BleManager` can temporarily suspend `0x25` heartbeats
- the current Navigate bootstrap replay uses this during the 108-packet
  interleaved burst, then resumes heartbeats afterwards
- this is specifically to avoid degraded-leg noise and false transport
  failures during the large fire-and-forget bootstrap

### Auto-reconnect (full session)

Full-session disconnect detection and auto-reconnect are a distinct concern from the per-leg degraded handling above.

**Dead-code fix note:** `_onGlassesDisconnected()` in `ble_manager.dart` was historically dead code. Android's GATT stack routes disconnect events through `_onGlassesConnectionStateChanged()` / `_applyConnectionPayload()`, not through `_onGlassesDisconnected()`. As a result, timer cleanup (heartbeat, reconnect monitor) never ran on real disconnects. This has been fixed: `_applyConnectionPayload()` now detects a full disconnect via a `wasConnected && !isConnected` transition check, and performs the full cleanup and auto-reconnect trigger from there.

Full-session auto-reconnect behaviour (`BleManager`):
- on detecting a full disconnect, checks the last wear state from `AppSettingsStore`
- if last wear state is `inCradle` (`F5 08` / `F5 0B`), auto-reconnect is skipped
- if last wear state is `worn` (`F5 06`) or unknown, reconnect proceeds using `forceReconnect()`
- backoff schedule: immediate → 30 s → 60 s → 120 s (four attempts total)
- after four unsuccessful attempts, auto-reconnect stops and waits for manual action
- the channel number used for reconnect is persisted in `AppSettingsStore`
  (`ble.last_channel_number`) on every successful connect, so it survives
  app restart

New methods added to `BleManager` for this feature:
- full-disconnect detection in `_applyConnectionPayload()`
- backoff scheduling and state tracking
- channel persistence on connect
- `_pendingAutoConnectChannel` scan-then-connect pattern for app-launch auto-connect

**AppSettingsStore fields added:**

| Field | Written by | Read by | Purpose |
|---|---|---|---|
| `ble.last_channel_number` | `BleManager` on connect | `BleManager` on launch | Identifies which glasses to scan for on app start |
| `ble.last_wear_state` | `DeviceStatusService` on every F5 wear event | `BleManager` before reconnect / on launch | Enables cradle-aware reconnect skip |

### Native BLE lifecycle (Android)

The `BluetoothGatt` lifecycle in
[android/.../bluetooth/BleManager.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
is now strictly managed to prevent GATT resource exhaustion and silent setup
failures. Prior to the 2026-05-08 fix, several native GATT lifecycle bugs were
the dominant cause of long-term BLE instability — exhausting Android's per-app
GATT client cap over a day of drop/reconnect cycles. Analysis of HCI snoops
from the official Even Realities app (cross-referenced with JohnRThomas wiki and
Gadgetbridge constants) identified the root causes as lifecycle mistakes rather
than heartbeat cadence.

**Connection setup state machine.** A per-callback-closure `LegSetupPhase` enum
(`IDLE` / `DESCRIPTOR_WRITE_PENDING` / `MTU_PENDING` / `BOND_PENDING` / `READY`)
serialises Android GATT operations, which require only one in-flight operation at a
time. The sequence is:

1. `onServicesDiscovered` — writes the CCCD descriptor to enable notifications;
   sets phase to `DESCRIPTOR_WRITE_PENDING`.
2. `onDescriptorWrite` — on success, requests MTU 251; sets phase to `MTU_PENDING`.
3. `onMtuChanged` — on success, calls `createBond()` if the device is not already
   bonded (guards against stray re-pairing prompts on reconnects); sets phase to
   `BOND_PENDING` or `READY`. Then calls `markLegReady(gatt)` to notify Flutter.

`markLegReady(gatt)` is a helper extracted from the old monolithic
`onServicesDiscovered`: it updates the `BlePairDevice` connection state, fires
the initial heartbeat (`0xf4 0x01`), and calls `flutterGlassesConnected` when
both legs are up.

**Lifecycle invariants.**
- `STATE_DISCONNECTED` in `onConnectionStateChange` now calls `gatt.close()` on
  the received `gatt` instance and nulls the stored `BleDevice.gatt` and
  `writeCharacteristic` references — but only when the stored ref still matches
  the disconnecting instance, to avoid closing a freshly-created reconnect.
- `connectToGlass` (initial connect) uses `autoConnect=false` for fast
  time-to-connect; `reconnectLeg` uses `autoConnect=true` so the OS maintains a
  background scan and re-establishes the link automatically when the device
  returns into range.
- A `bondStateReceiver: BroadcastReceiver` is registered against
  `applicationContext` in `initBluetooth()` and unregistered in a new
  `BleManager.deinit()` method. It filters by connected device addresses and
  surfaces `bond_failed` to Flutter via `notifyConnectionState` when bonding
  fails. `deinit()` is called from `MainActivity.onDestroy()`.
- `onCharacteristicWrite` is now implemented (errors-only logging) to surface
  write failures that were previously silent.

## Trusted event routing

The app only routes trusted gesture/state events into product behaviour:
- `F5 00`
- `F5 02`
- `F5 03`
- `F5 17`
- `F5 18`
- `F5 20` (mode-switch, contingent on the official Even app's double-tap
  action being a host-handled feature — Transcribe / Translate / Teleprompter
  all confirmed working; Dashboard and None are firmware-only and won't fire)

The broader mapping is documented in:
- [even-g1-event-mapping.md](even-g1-event-mapping.md)

The app does not rely on single taps as a core input.

Current use of left-hold events:
- in Glance mode only, the connected left-hold voice path is used for the Glance assistant shortcut
- compatibility routing also accepts the legacy Even AI start/stop event family where needed on-device

QuickNote note:
- the right-hold mode-switch POC does not depend on `F5`
- it is intentionally based on right-leg `R21` only because `F5` proved too overloaded for QuickNote modeling

Tilt-up intent gating:
- `CompanionController` applies a shared `500ms` tilt-up intent gate for a small subset of `F5 02` actions
- the gate exists to filter quick incidental look-ups before committing to a mode action
- current gated paths are:
  - first deliberate Glance entry from idle into recall
  - Capture start and stop
  - Chat start listening
- current non-gated paths are:
  - Glance while already in active recall/cycling
  - Navigate
  - Chat stop/submit on `F5 03`
- return-to-centre on `F5 03` cancels any still-pending gated tilt-up intent
- the helper and narrow `TiltIntent` debug logging live in [lib/services/companion_controller.dart](../lib/services/companion_controller.dart)
- [lib/services/glance_service.dart](../lib/services/glance_service.dart) exposes a small state getter so idle Glance entry can be distinguished from active recall

## Notification ingestion

Native Android listener:
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)

Native rolling store:
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt)

Flutter model:
- [lib/models/companion_notification.dart](../lib/models/companion_notification.dart)

Bridge methods/events:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)

This listener path is a core foundation for both Glance and Navigate.

Maps payload dump logging:
- the Android notification listener still contains a deep Google Maps payload dump path for investigation
- it is now gated behind the native log tag `MapsNotificationDump` and is off by default

Notification policy:
- [lib/services/notification_policy.dart](../lib/services/notification_policy.dart)
- [lib/services/notification_settings_store.dart](../lib/services/notification_settings_store.dart)

Current responsibility:
- central classification of notifications as `blocked`, `suppressed`, `callAbsorbed`, `protected`, `normal`, or `mediaAbsorbed`
- one place for package-based Glance suppression, dismissal protection, media absorption, and call routing rules
- persistence of user-managed suppressed package and media-override preferences (DB v2)

Current built-in rules:
- block the companion app's own notifications from entering Glance
- route active-call notifications (`callAbsorbed`) to `GlanceService.updateCall()` — bypasses the ongoing-suppressed rule; excluded from the carousel via `shouldBlockFromGlance()`; detection uses the `CompanionNotification.isCall` getter (`isOngoing && (category == 'call' || template contains 'CallStyle')`)
- protect YouTube notifications from Glance-driven dismissal side effects
- protect pinned/live score notifications (Google pinned live score and Samsung AOD sports wrapper) so they remain visible but non-dismissible
- suppress most ongoing notifications from the ordinary Glance queue
- suppress low-value `Open on phone` style handoff notifications
- seed user-manageable noisy-package suppression for SmartThings / Samsung Camera style churn
- absorb media-style notifications (`mediaAbsorbed`) from streaming apps (Spotify, YouTube Music, Podcast Addict, YouTube, etc.) into the Glance time line rather than the carousel; controlled by auto-detect heuristics and per-app `media_override` toggle

Classification order in `classify()`: `blocked` → `callAbsorbed` → protected-pinned → suppressed-ongoing → `normal` / `mediaAbsorbed`. The `callAbsorbed` check precedes the ongoing-suppressed rule intentionally — call notifications are `isOngoing == true` and would otherwise be suppressed.

## Background / permanent companion foundation

The app is designed to keep functioning as a companion app while backgrounded.

Foreground service:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)

Manifest/service registration:
- [android/app/src/main/AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml)

Current role:
- persistent Android notification
- mode label in the notification
- foundation for ongoing companion behaviour

This is intentionally minimal, but it is part of the current architecture rather than a future bolt-on.

Foreground service note:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt) uses `specialUse`
- `connectedDevice` was the wrong foreground service type for app startup behaviour on the target Android environment

## Capture audio path

Native recorder:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)

Decode path:
- [android/app/src/main/cpp/liblc3.cpp](../android/app/src/main/cpp/liblc3.cpp)

Current technical model:
- glasses mic packets arrive natively
- LC3 is decoded to PCM natively
- decoded PCM is buffered privately, then the final WAV is published via Android's public recordings media collection

Capture mode depends on this existing path rather than inventing a new one.

Chat mode reuse:
- Chat reuses the same native LC3 decode and PCM buffering path
- for Chat, a narrow native method returns a temporary local WAV file instead of publishing to MediaStore
- that temp WAV is used for speech transcription, then deleted

Glance assistant reuse:
- Glance assistant reuses the same temp-WAV recorder, transcription client, and OpenAI-compatible backend
- it deliberately avoids Chat persistence and does not create a `ChatHistoryStore` session

This keeps Capture and Chat on the same proven recorder foundation while allowing different stop/output behaviour.

## Phone UI

Current phone control surface:
- [lib/main.dart](../lib/main.dart)
- [lib/views/home_page.dart](../lib/views/home_page.dart)
- [lib/views/settings_page.dart](../lib/views/settings_page.dart)

The UI is intentionally simple:
- a prominent connection/status area that collapses once both legs are healthy
- mode selector
- chat log
- settings entry for occasional setup tasks
- legacy/demo area separated from the main UX

Settings now own:
- OpenAI-compatible API key and backend overrides
- notification filter management
- firmware-persisted gesture settings (head-up / tilt-up behaviour and
  double-tap behaviour) — two dropdowns wired through
  [DeviceStatusService](../lib/services/device_status_service.dart)
  and
  [Proto.setHeadUpMode](../lib/services/proto.dart)
  /
  [Proto.setDoubleTapAction](../lib/services/proto.dart),
  with the user's pick persisted in
  [AppSettingsStore](../lib/services/app_settings_store.dart)
  for cross-session display. Re-push behaviour on reconnect follows the
  authoritative-settings model described below.
- permission/setup affordances

The home screen stays focused on day-to-day companion control. Runtime backend configuration now comes from the Settings screen, with `dart-define` retained only as fallback/default input.

## Authoritative settings model

The companion app treats its own persisted settings as the source of truth
and re-pushes them on every fresh BLE reconnect. Settings covered by this
model:

- brightness level (slider position)
- auto-brightness toggle
- head-up (tilt-up) behaviour
- double-tap action

This is a deliberate divergence from the previous non-invasive stance (under
which head-up and double-tap were set once and not re-asserted). The
rationale: this is a personal companion app, and intent expressed inside this
app should win over whatever the official Even Realities app may have written
whilst disconnected.

**Gating:** Only settings the user has interacted with at least once are
pushed. Settings that have never been touched in this app are left at whatever
the firmware currently holds — the app does not stamp defaults over
unvisited controls.

See also: [FINDINGS-battery+brightness.md](FINDINGS-battery+brightness.md)
§ "`F5 12` on-connect timing" — the firmware's passive brightness push on
connect lets the host display the pre-push level for comparison.

## Logging posture

Single Flutter-side logger:
- [lib/services/app_log.dart](../lib/services/app_log.dart)

Raw `print()` is no longer used anywhere in `lib/`. Every Flutter-side log goes through `AppLog`, which exposes three levels and an optional category tag:
- `AppLog.info(msg, tag: ...)`  : always enabled. Concise operational lifecycle and state changes.
- `AppLog.error(msg, tag: ...)` : always enabled. Error paths, failed guards, recoverable bugs.
- `AppLog.debug(msg, tag: ...)` : gated behind the build-time define `COMPANION_VERBOSE_LOGS`. Used for investigation-grade chatter (per-event BLE packet notes, tilt-intent traces, heartbeat details, probe output).

When a `tag` is provided, it is rendered as a `[TAG] ` prefix so logs can be filtered by category in `logcat` / IDE output.

Canonical tags currently in use:
- `BLE`, `Companion`, `Glance`, `GlanceAssistant`, `Chat`, `ChatBackend`, `Capture`, `Navigate`, `NavigateBmp`, `TiltIntent`, `NotificationPolicy`, `Transport`, `DeviceStatus`, `AppStartup`, `Text`, `BmpUpdate`
- probe tags kept distinct from their owning subsystem for targeted filtering: `R21Probe`, `QuickNoteProbe`, `RightHoldProbe`
- legacy/demo quarantine tags: `Dashboard`, `DashboardBmp`, `EvenAI`, `Features`, `ApiService`, `DeepSeek`, `BmpPage`, `Utils`

Split posture preserved:
- concise operational lifecycle/error logs remain enabled by default
- verbose investigation logs are gated behind:
  - Flutter build-time define: `COMPANION_VERBOSE_LOGS=true`
  - Android log tag enablement for Maps payload dumps: `MapsNotificationDump`

This keeps day-to-day release builds quieter while preserving useful diagnosis paths when needed. Because all Flutter-side logs now flow through `AppLog`, the `COMPANION_VERBOSE_LOGS` gate now applies uniformly — including the BLE packet, F5 event, R21, RightHold, and Glance/Navigate render paths that previously bypassed it via raw `print()`.

New Flutter-side log sites should use `AppLog` with an appropriate level and tag. Raw `print()` should not be reintroduced.

## Legacy / demo code posture

The project is no longer treated as a feature-zoo demo app.

Current stance:
- preserve proven BLE/protocol/rendering code
- de-emphasize or quarantine legacy demo surfaces
- avoid broad deletion while the companion behaviours are still being validated

Old demo material remains useful mainly as:
- protocol harness code
- debug hooks
- historical reference
