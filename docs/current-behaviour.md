# Current Behaviour

This file describes what the app currently does from a user and runtime point of view.

It is intentionally separate from:
- [current-architecture.md](current-architecture.md): structure and ownership
- [protocol-reference.md](protocol-reference.md): raw vendor/demo protocol notes
- [investigation-notes.md](investigation-notes.md): exploratory findings and hypotheses

## Current mode summary

### Glance
- default and most mature mode
- Android notifications can auto-pop into the glasses
- tilt-up recalls or advances recent notifications
- left-hold while idle triggers a lightweight assistant shortcut
- double tap closes the current visible item

### Capture
- intended to record glasses mic audio and save WAV on phone
- partially implemented
- still needs focused device validation

### Navigate
- intended to surface Google Maps navigation guidance from notifications
- implemented with a Navigate-only visual card path
- still needs longer real-world walking validation

### Chat
- voice-driven conversational mode
- implemented end-to-end on device

### Quick mode switching
- available from the persistent Android notification
- available from the app UI mode selector
- available as a narrow idle-only right-hold POC via right-leg `R21`
  (note: this POC's `len == 42` gate may no longer match current firmware,
  which appears to emit `R21` at length 15 — see
  [FINDINGS-taps.md](FINDINGS-taps.md))
- available via double-tap on either temple, contingent on the official
  Even Realities app's "double-tap action" being any host-handled feature
  (Transcribe / Translate / Teleprompter all work); the firmware then emits
  `F5 20`, which the companion app routes to a passive mode cycle. Setting
  the action to Dashboard or None makes the gesture firmware-only and the
  cycle stops working. See "Double-tap mode switch" below

## Glance mode

Glance is currently the main working user-facing feature.

### Display format

Glance is text-only by design:

```text
14:32  85%
--
AppName
Notification body
```

The glasses battery percentage is appended to the time line whenever a battery
value has been received from the glasses. If the glasses have not yet pushed a
battery reading (e.g. immediately after connect, before the first `F5 0A`), the
time line is rendered without the percentage:

```text
14:32
--
AppName
Notification body
```

It deliberately does not use the bitmap dashboard path because text is much faster and better for ambient notification use.

### Current behavior

- new notifications can auto-pop into the glasses
- proactive auto-pop does not dismiss the phone notification
- deliberate tilt-up shows the most recent notification
- the first tilt-up from true idle into Glance recall is intent-gated for `500ms`
- repeated tilt-up cycles through the feed
- when cycling deliberately:
  - normal notifications are dismissed on the phone
  - normal notifications are also removed from the local app queue
  - protected notifications stay visible on the phone and are only advanced locally
- `F5 00` closes the active Glance item
- timeout clears the active display after a short interval

### Glance assistant

- only available while current mode is `Glance`
- only triggers when Glance is idle / forward-facing
- does not trigger while a Glance notification is visible
- does not switch into Chat mode
- uses the firmware-native listening overlay during left-hold
- on release, the app:
  - finalizes the temp WAV
  - transcribes speech via the configured OpenAI transcription API
  - shows a short transcript preview
  - shows `Thinking...`
  - renders the assistant response
  - clears the response after a short timeout

### Glance assistant context model

- the first Glance assistant ask starts an ephemeral in-memory mini-session
- follow-up asks within a short inactivity window reuse that same context
- the current expiry is about 4 minutes of inactivity
- this context is separate from full Chat mode
- it is not stored in the persistent Chat log

### Current caveats

- heavy notification churn can still stress left/right synchronization
- new notifications are now queued if one is already visible, rather than interrupting the current display

### Current filtering

At notification-ingestion time, noisy system notifications are filtered out, including:
- `System UI`
- charging/battery churn

### Current notification policy

Glance now applies five notification classes:
- `blocked`: never shown
- `suppressed`: not shown in the ordinary Glance queue
- `protected`: shown in the queue but never dismissed by Glance gestures
- `normal`: shown and dismissible

Current handling:
- blocked:
  - companion app notifications
- protected:
  - YouTube notifications
  - pinned/live score notifications (Google app pinned live score and Samsung AOD sports wrapper)
- suppressed:
  - most ongoing notifications
  - low-value `Open on phone` / `Open your phone for details` style handoff notifications
  - user-suppressed packages such as SmartThings / Samsung Camera when toggled off

Current safety rules:
- protected notifications are never dismissed by Glance gestures
- ongoing notifications are never dismissed by Glance gestures

### Current package suppression controls

- the Settings screen includes a `Notification Filters` section
- it shows recently seen packages
- packages can be toggled suppressed / unsuppressed there
- built-in noisy-package suppression seeds currently include SmartThings and Samsung Camera

### Firmware Settings (Settings screen)

Below `Notification Filters` and above `Permissions`, the Settings screen
exposes two dropdowns that write persisted-on-glasses choices via BLE:

- **Tilt-up behaviour**
  - `Companion app behaviour` — sends `0x08 06 00 00 03 02`. The firmware
    does not show its own dashboard on tilt-up; the glasses still emit
    `F5 02` / `F5 03` and the companion app drives any visible response.
  - `Even firmware dashboard` — sends `0x08 06 00 00 03 00`. The firmware's
    own dashboard appears on tilt-up.

- **Double-tap behaviour**
  - `Companion app mode switch` — sends `0x26 06 00 <seq> 05 05`. Configures
    the firmware's double-tap action to "transcribe" so it fires `F5 20`,
    which the companion app routes to a passive mode cycle.
  - `Even firmware dashboard` — sends `0x26 06 00 <seq> 05 04`. Double-tap
    opens the firmware's dashboard locally; no `F5 20` fires.
  - `Do nothing` — sends `0x26 06 00 <seq> 05 00`. Only `F5 00` fires when
    double-tap closes an already-active feature.

Behavioural notes:
- Both dropdowns are disabled while the glasses are disconnected.
- The chosen values persist on the glasses themselves (they survive an app
  uninstall) and are also remembered locally so the dropdown shows the last
  pick after an app restart.
- The companion app **does not** re-send these on reconnect. To re-apply a
  setting, re-tap the dropdown. This is deliberate — it avoids overriding
  anything the user might have changed in the official Even Realities app
  between sessions.

## Capture mode

Capture is practically usable and has survived at least one long real-world recording session, but stop/save semantics still need broader confidence.

### Intended behavior

- idle + tilt-up -> start recording after a short `500ms` intent gate
- recording + tilt-up -> stop and save after the same `500ms` intent gate
- recording + double tap -> stop and save
- idle + double tap -> no-op
- idle display shows `*`
- show a recording `REC` indicator while active
- show a short save confirmation after recording completes

### Current technical status

- native LC3 decode path exists
- decoded PCM can be written to a WAV recorder
- the Flutter/native bridge for capture is in place
- saved WAV files are published to the public Android recordings collection
- on the target phone this should appear as `Internal storage/Recordings/Even Companion`

### Current caveat

What still needs device confirmation is whether the glasses mic session stops cleanly in practice when Capture mode stops saving.

So:
- WAV save path now targets a normal user-visible recordings location
- real stop semantics are still an open validation item

## Navigate mode

Navigate is intentionally lean and notification-driven.

### Current intended behavior

- user switches app into Navigate mode on phone
- Google Maps notifications are ingested
- concise turn guidance is shown in the glasses
- ordinary Glance notifications are suppressed or deprioritized while navigating

### Current status

- the notification ingestion path is already available
- Maps notification fields are parsed
- only real turn-by-turn Google Maps notifications are now eligible input
- startup and waiting states stay text-rendered
- idle state shows `Open Google Maps` / `to start navigation`
- real navigation instructions are currently debug-driven by a full
  **108-packet `0x0a` replay** of the official app's lifecycle
  (INIT + SYNC + TRIP_STATUS + icon + map + trailing SYNC), sent with an
  **interleaved per-leg fire-and-forget transport** that has now proven fast
  and stable on device for the initial bootstrap
- the replayed bootstrap now replaces only the `TRIP_STATUS` packet with a
  live packet built from the current Google Maps notification fields
- after bootstrap, Navigate runs a real **1-second `0x0a` SYNC poller**
  while the session remains active
- post-bootstrap updates now default to **dynamic `TRIP_STATUS + SYNC`**
  instead of resending the full 108-packet lifecycle on every guidance change
- the production target remains a structured TRIP_STATUS packet with four
  visible null-separated text fields (ETA, total distance, road name, turn
  distance) that the firmware renders using its own built-in card template
  and font
- the **MAP_OVERVIEW direction icon is now dynamically generated** from the
  Google Maps notification icon PNG (`navIconPngBase64`): decoded to 136×136
  monochrome via alpha threshold, RLE-encoded, padded to 13 bands. Falls
  back to geometric arrow generation, then captured data.
- the `DirectionTurn` byte in TRIP_STATUS is classified by
  `classifyManoeuvre()` parsing both `navIconSource` and instruction text
- the previous BMP-per-frame approach has been replaced; the BMP pipeline
  is preserved in the codebase for potential future use but is no longer
  called from Navigate
- the rate limit between updates has been reduced from 2200 ms (BMP) to
  500 ms (the structured text packet is tiny and atomic)
- the idle prompt ("Open Google Maps to start navigation") is **suppressed**
  — no text is sent to the glasses on mode entry. This avoids a race where
  `Proto.exit()` cleanup completed mid-replay, blanking the display on first
  load. The glasses stay on whatever was displayed before until the first
  Maps notification triggers the nav card.

### Current caveats

- **The `0x0a` nav card protocol is confirmed working** with dynamic
  direction icons and live text fields. Session keepalive behaves well on
  longer routes.
- The bootstrap is still replay-based around captured snoop bytes, with
  TRIP_STATUS and MAP_OVERVIEW replaced dynamically. PANORAMIC_MAP remains
  captured/static.
- Some Google Maps updates still map the wrong source text into the
  `turnDistance` field, so payload extraction needs cleanup.
- Startup robustness still needs observation when one leg begins degraded or
  reconnecting.
- Navigate depends on how stable Google Maps notification updates are on
  the real phone/device configuration during longer walks.
- The `0x0a` code still contains replay scaffolding and captured
  `MAP_OVERVIEW` / `PANORAMIC_MAP` data. The next production step is
  replacing those captured bytes with real icon/map generation or a turn-icon
  library once lifecycle/update behavior is fully trusted.

## Chat mode

Chat mode is now a working v1 feature.

### Gesture flow

- entering Chat mode creates a fresh in-memory session
- idle state shows `Chat ready` / `Tilt up to talk`
- tilt up starts listening from the glasses mic after a short `500ms` intent gate
- tilt down stops capture and submits what was said
- once the transcript is available, Chat enters or reuses the `0x52`
  conversation surface instead of showing a separate transient transcript
  preview
- the transcribed user question is appended to the visible conversation
- while waiting for the backend, Chat shows the user turn plus a short `G1:
  Thinking...` placeholder in the same surface
- the assistant reply then fills in below that in the firmware `0x52`
  streaming text mode with the pulsing cursor on the left
- follow-up turns continue in the same session while Chat mode stays active
- leaving Chat mode resets and discards the session
- `F5 00` / close-active while a reply is visible now clears only the visible
  Chat display and returns Chat to a ready state; it does not discard the
  in-memory conversation history

### Current implementation

- glasses mic audio is captured through the existing native recorder path
- Chat uses a temporary WAV output rather than Capture's saved-public-recording path
- the WAV is transcribed through the configured OpenAI transcription API
- the transcript plus in-memory conversation history are sent to the configured
  chat backend
- the visible Chat surface is displayed via `0x52` streaming text:
  - `0x50` display mode control + `0x52` init before the first streamed frame
  - each visible wrapped line is sent to its own `0x52` line index
  - historic visible lines are resent as stable committed line content
  - only the newest visible line is driven progressively with the cursor
  - each `0x52` update re-sends the full current content of that specific line
  - the visible window is trimmed from the top as wrapped lines overflow
  - `0x53` keepalive stays active while the `0x52` conversation surface is active
- assistant reply rendering is paced by a `StreamingRenderQueue` that is
  decoupled from backend chunk arrival:
  - backend chunks only append to a target text buffer
  - the queue drains ~2 words every 150 ms at its own cadence
  - only changed 0x52 lines are sent (dirty-line diffing)
  - the queue keeps draining after the backend stream completes until
    all text is displayed, then signals completion
  - line wrapping is deterministic at ~48 chars/line (word-boundary wrap)
- the visible Chat surface is now a trimmed conversation buffer separate from
  backend history, using compact labels (`You:` / `G1:`) and preserving recent
  turns across follow-up questions while Chat mode remains active
- if streaming is unavailable or fails before a visible streamed reply is on
  screen, Chat can still fall back to the older `0x4E` text path

### Response shaping and limits

- the backend uses a smart-glasses-specific system prompt
- responses are biased toward short, practical, high-signal answers
- output tokens are capped at the backend request level
- response characters are also capped locally before display as a second safety rail
- session history is only lightly capped to the most recent messages if it grows unusually large
- there is no summarisation in this phase
- the current OpenAI-compatible integration requests streamed output; a paced
  `StreamingRenderQueue` smooths coarse provider chunks into a readable
  word-by-word typewriter effect on the glasses

### Current configuration

Chat mode now prefers a runtime OpenAI-compatible configuration saved inside the app.

Current practical flow:
- install one APK
- open `Settings > API / Assistant`
- save an API key locally on device
- optionally save base URL, chat model, and transcription model overrides

Persistence:
- the API key is stored locally in secure storage
- the optional non-secret overrides are stored locally in app preferences
- both persist across restarts and normal upgrades

Fallback behaviour:
- runtime values override build-time defaults
- blank runtime fields fall back to `dart-define` values if they exist
- if no valid API key exists anywhere, Chat and the Glance assistant fail with the same `API key issue` style messaging as before

Known-good fallback examples:

```powershell
flutter run --dart-define="OPENAI_API_KEY=sk-..."
flutter build apk --release --dart-define="OPENAI_API_KEY=sk-..."
```

Important:
- use the raw key value
- do not wrap the key in square brackets

Optional defines:

```powershell
--dart-define="CHAT_API_BASE_URL=https://api.openai.com/v1"
--dart-define="CHAT_MODEL=gpt-4.1-mini"
--dart-define="CHAT_TRANSCRIPTION_MODEL=gpt-4o-mini-transcribe"
--dart-define="CHAT_TRANSCRIPTION_LANGUAGE=en"
--dart-define="CHAT_MAX_OUTPUT_TOKENS=220"
--dart-define="CHAT_MAX_RESPONSE_CHARS=900"
--dart-define="CHAT_MAX_HISTORY_MESSAGES=16"
```

### Failure handling

Current short on-glasses failure messages:
- no speech / empty transcript:
  - `Didn't catch that`
- transcription auth failure:
  - `API key issue`
- transcription timeout:
  - `Transcription timed out`
- transcription network failure:
  - `Network problem`
- generic transcription failure:
  - `Transcription failed`
- backend auth failure:
  - `API key issue`
- backend timeout:
  - `Request timed out`
- backend network failure:
  - `Network problem`
- generic backend or flow failure:
  - `Something went wrong`

Richer technical detail is kept in app logs rather than dumped into the glasses display.

### Current caveats

- Chat mode depends on network reachability and a valid API key
- long conversations are lightly windowed if they exceed the recent-history cap
- the `0x52` render path now uses a paced `StreamingRenderQueue` to decouple
  backend chunk arrival from display updates; still needs live validation of
  reading pace and long-answer scrolling behaviour
- there is no spoken TTS reply in this phase
- there is no consumer ChatGPT account linking in this phase

## Quick mode switching

Quick mode switching is now part of normal companion behavior.

### Notification switching

- the persistent Android foreground notification shows the 3 modes that are not currently active
- the action order is stable using the global mode order:
  - `Glance`
  - `Navigate`
  - `Chat`
  - `Capture`
- tapping one switches mode immediately
- the mode changes without opening the full app UI
- the notification title updates to the new mode
- tapping the notification body opens the main app screen

### App and glasses behavior

- app UI mode buttons switch mode immediately through the same central controller path as notification actions
- idle right-hold can cycle mode when a right-leg `R21` packet with the current stable `len == 42` shape is observed
- double tap still closes the current feature when something is active on the glasses
- if the glasses display is idle, double tap is now a no-op
- if the glasses display is active, the right-hold POC does nothing

### Passive switching rules

Quick mode switches are passive:
- they do not auto-start Capture recording
- they do not auto-start Chat listening
- they do not auto-open a live Navigate instruction card
- they do not force a Glance notification render
- the right-hold POC does not depend on `F5` companion events

Leaving a mode through quick switching follows the same cleanup rules as normal mode changes, including Chat session reset.

### Right-hold POC limits

- this is a proof of concept, not yet a fully trusted primary control
- it is gated on right-leg `R21` only
- it currently requires the observed stable `len == 42` packet shape
- repeated `R21` triggers are ignored for `1500ms`
- it is intentionally idle-only to avoid colliding with active display content or firmware QuickNote UI
- in the 2026-04-28 taps capture every right-hold release produced an `R21`
  of length `15`, not `42`, so the gate may need updating before this POC
  re-enters active use

### Double-tap mode switch

- the companion app subscribes to `F5 20` and treats it as "double-tap fired,
  cycle to the next mode"
- mode order: `Glance` → `Navigate` → `Chat` → `Capture` → `Glance`
  (reusing the `AppMode.nextMode` cycle the right-hold POC uses)
- repeated triggers debounced at `1500ms`
- no idle-only gate is needed: when a feature is already active, the firmware
  emits `F5 00` (close-active) instead of `F5 20`, and that path is the
  existing close-active handling
- this depends on the user setting the official Even Realities app's
  double-tap action to any **host-handled** feature. Verified configurations:
  - **Transcribe** ✓ — `F5 20` fires, mode cycle works
  - **Translate** ✓ — `F5 20` fires, mode cycle works
  - **Teleprompter** ✓ — `F5 20` fires, mode cycle works
  - **Dashboard** ✗ — firmware-native, `F5 20` does not fire (the dashboard
    still opens on-glasses, even with the official app force-stopped)
  - **None / Close active feature** ✗ — only `F5 00` fires (and only when
    something is open to close)
  - the setting is persisted on the glasses themselves, so it survives the
    official app being uninstalled, but if the user picks Dashboard or None
    the cycle will stop working
- the on-glasses overlay for the configured action (e.g. Transcribe's
  listening prompt) appears briefly alongside the mode switch — there is no
  way for the companion app to suppress it
- the firmware emits `F5 20` 1–6 s after the physical tap, so the mode change
  has a noticeable latency
- when this is removed or replaced, the wired up F5 20 case in
  [`lib/ble_manager.dart`](../lib/ble_manager.dart)
  should be cleaned up alongside the `handleDoubleTapModeSwitch` method in
  [`lib/services/companion_controller.dart`](../lib/services/companion_controller.dart)

## Logging

Current logging posture:
- all Flutter-side logs route through a single `AppLog` helper
- operational lifecycle (`AppLog.info`) and error (`AppLog.error`) logs remain enabled
- verbose investigation logs (`AppLog.debug`) are disabled by default
- every log line carries a category tag prefix (e.g. `[BLE]`, `[Glance]`, `[Chat]`) for easy filtering

To re-enable verbose Flutter-side logging:

```powershell
flutter run --dart-define="COMPANION_VERBOSE_LOGS=true"
```

When verbose is enabled, the per-event BLE packet trace, F5/R21/RightHold probes, Glance/Navigate render diagnostics, tilt-intent traces, and dashboard/legacy traces all come back on.

To re-enable native Google Maps payload dumps:

```powershell
adb shell setprop log.tag.MapsNotificationDump DEBUG
adb logcat -s MapsNotificationDump
```

This keeps normal daily-use builds quieter while preserving a path for targeted investigation.

Tilt-intent debug logging:
- the controller emits narrow debug-level `TiltIntent` logs for pending, confirmed, cancelled, and cleanup cases around the `500ms` gate

Filtering by tag in `logcat` (examples):

```powershell
adb logcat | findstr "\[BLE\]"
adb logcat | findstr "\[Glance\] \[GlanceAssistant\]"
adb logcat | findstr "\[R21Probe\] \[RightHoldProbe\] \[QuickNoteProbe\]"
```

## Connection and transport reliability

Current runtime behavior:
- left and right legs are monitored separately
- heartbeat success is tracked per leg
- repeated heartbeat/request failures can mark one leg degraded without declaring the whole session dead
- degraded legs can trigger bounded reconnect attempts
- when transport recovers, the app resends the current active content to help both lenses converge again

Practical effect:
- one eye can remain usable while the other is recovering
- Navigate BMP divergence should self-correct more often after recovery
- a restart/reconnect should no longer be the only way to recover from every partial transport problem

## Home screen

Current behavior:
- the connection area stays prominent at the top during startup, scanning, disconnected, or degraded states
- once both legs are healthy, that area compresses into a smaller status card
- the compact state still shows:
  - connection state
  - left/right compact status
  - current mode
  - health summary
  - glasses battery percentage when known
  - case (cradle) battery percentage when known
  - wear state: `Worn`, `In cradle`, or `—` if not yet known
  - last saved capture when present
- battery and wear state values are pushed by the glasses; once a value
  arrives the relevant pill appears, and the home card live-updates as the
  glasses re-push values
- on full disconnect, battery values clear and wear state returns to `—`
- a `Force Reconnect` action remains available in the connection area
- occasional setup items now live under `Settings` rather than staying on the main screen

### Display section

When the glasses are connected, a `Display` card appears between the Modes
card and the Chat Log on the home screen. It contains:

- a brightness slider with the underlying firmware range 0–42; dragging the
  slider does not send anything in flight, the value is committed on release
- an `Auto brightness` switch which, when toggled, immediately sends the
  current slider value with the new auto flag
- a small `Confirmed: N` label that reflects the most recent
  `F5 12 <level>` echo from the firmware so the user can see the difference
  between requested and actually applied brightness when auto brightness is
  doing its own thing

The auto flag is locally tracked from the last sent command because the
firmware does not echo it back. On full disconnect, both the slider state and
the auto flag reset to defaults.

## Background behaviour

The app is intended to keep functioning as a permanent companion app, not only while visible on screen.

Current foundation:
- Android foreground service
- persistent Android notification
- notification listener remains active
- mode state is reflected in the ongoing system notification

This is implemented narrowly, but it is already part of the current app shape.

## Validation workflow

Known-good local validation commands:

```powershell
flutter analyze
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Practical rule:
- `flutter run` is not enough as final validation
- the app must also be checked from an installed release APK on the target phone

## Notification ingestion

Current behavior:
- the app captures recent Android notifications
- recent notifications are cached natively
- Flutter hydrates from that feed and also receives pushed notification events
- phone-side dismissal by notification key is supported on a best-effort basis

This supports:
- Glance mode
- Navigate mode

## Current known problems / open edges

- Glance left/right synchronization still needs watching under rapid notification arrival
- some notification sources/messages still need smarter formatting
- Capture mode needs real device validation for start/stop/save reliability
- Navigate mode still needs longer human review against real Google Maps walking sessions
- Chat mode still needs broader real-world testing for latency, retries, and edge-case error handling
