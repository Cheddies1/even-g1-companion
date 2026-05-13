# Current Behaviour

> **Document type:** App implementation
> **Audience:** Eddie + AI agents working on the EvenDemoApp codebase
> **Evidence basis:** App source code + capture-driven design decisions

This file describes what the app currently does from a user and runtime point of view.

It is intentionally separate from:
- [current-architecture.md](current-architecture.md): structure and ownership
- [protocol-reference.md](protocol-reference.md): wire-level G1 BLE command catalogue
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
- implemented end-to-end; responses streamed word-by-word to the glasses via `0x52` live streaming text (host-managed scrolling, 3 visible rows, ~43 chars/row, paced 2 words/200 ms)

### QuickNote
- right-temple long-press records audio on-glasses
- on release, the app receives the notes-list metadata (`0x21`), requests
  the audio stream, receives LC3-encoded chunks, decodes to PCM, writes a
  WAV file, transcribes via OpenAI Whisper STT, and stores the note in SQLite
- pipeline is implemented and working end-to-end (2026-05-08 / 2026-05-09)
- the wire protocol is documented in
  [protocol-reference.md](protocol-reference.md) § "QuickNote protocol family"
- notes are stored via `NotesStore` (SQLite); a `QuickNoteTidyService` LLM
  cleanup pass runs asynchronously after the raw transcript is inserted and
  updates both `transcript_clean` and `category` when complete; if the API is
  unavailable, a keyword-regex fallback (`QuickNoteClassifier`) classifies the
  note into `shopping`, `todo`, or `notes` (default)
- **auto-categorisation:** every captured note is automatically assigned to one
  of three categories — `Shopping`, `To Do`, or `Notes`. Classification is
  performed by the same LLM tidy call (single API round-trip returns both
  cleaned text and category as JSON); `QuickNoteClassifier` is used as an
  offline fallback
- **notes UI is live:** `NotesPage` (`lib/views/notes_page.dart`) shows three
  tabs — `Shopping`, `To Do`, `Notes` — each with a badge showing the count of
  active notes in that category. Swipe-to-delete (undo snackbar), active/done
  status toggle, and expand/collapse for raw vs clean transcript comparison are
  available on all tabs. Notes can be moved between categories via the trailing
  overflow menu (`⋮`) → bottom sheet category picker.
  The HomePage shows a Notes card with a per-category breakdown; tapping it
  opens `NotesPage`
- WAV files are also retained in the app's external storage under `quicknote/`
  and can be pulled via `adb pull`
- **persisted `0x21` baseline:** the most recent 42-byte `0x21` payload is
  saved to SharedPreferences (`quicknote.last_cmd21_payload`) and restored on
  the first `0x21` after app restart, so the diff detection correctly
  identifies which note changed even after a restart
- **auto-sync of unknown notes:** on the first `0x21` after launch, the app
  compares all firmware note UIDs against the local store. Any UID not found
  locally is fetched, decoded, transcribed, and saved automatically — catching
  notes recorded via the official Even Realities app or while the companion app
  was closed. One-shot per launch; 2 s between fetches
- current status: pipeline and UI both implemented; notes management is usable

### Quick mode switching
- available from the persistent Android notification
- available from the app UI mode selector
- *(inactive)* narrow idle-only right-hold POC via right-leg `R21` — superseded
  by the `F5 20` double-tap path. Right-hold is now consumed by the QuickNote
  pipeline rather than mode switching.
  See [FINDINGS-taps.md](FINDINGS-taps.md)
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
14:32  |  85%
AppName  ·  09:47
Notification body
```

Line 1 is the current wall-clock time, separated from the glasses battery
percentage by `  |  ` (space-pipe-space). Line 2 combines the notification
source and the time the notification was originally posted on the phone
(`HH:MM`, 24-hour, zero-padded, local time — sourced from
`CompanionNotification.postedAt`), separated by `  ·  ` (space-mid-dot-space).
Line 3 is the notification body; longer messages wrap naturally via
`TextService` rather than being truncated.

When a media notification is currently active (see "Current notification
policy" below for classification details), a third segment is appended to line
1 via a second `  |  ` separator:

```text
12:41  |  100%  |  ▶ Green Day - Dookie
WhatsApp  ·  14:23
Hey are you coming to the meeting?
```

The media segment is formatted as `▶ Artist - Track` and is truncated with
`...` to fit within the 43-character display width. Media state is held in
`_currentMedia` inside `GlanceService`, updated live as media notifications
arrive, and cleared when the source notification is removed (i.e. playback
stops). Media notifications do not appear in lines 2–3 of the Glance feed;
they are absorbed into line 1 only.

### Call HUD

When an active phone call is in progress and the Glance carousel display times
out (or is dismissed), the glasses show a persistent two-line call surface
rather than going blank:

```text
Ongoing call: Andy Hulbert
Call time: 35:12
```

Duration is formatted as `M:SS` up to 59:59, then `H:MM:SS` once the call
exceeds one hour. It is computed locally in Dart by subtracting the call
connect timestamp (`CompanionNotification.connectedAt`, sourced from
`notification.when` as set by Samsung's in-call UI) from `DateTime.now()`,
driven by a 1 Hz timer. Samsung does not re-post the in-call notification every
second, so duration is not derivable from notification updates — the local
timer is the correct approach.

Caller name is taken from `android.title` in the notification extras
(`com.samsung.android.incallui` package).

Interactions while the call HUD is showing:
- Tilt-up: exits the call HUD and opens the normal notification carousel
- Tilt-down or carousel timeout: returns to the call HUD
- Call ends: the notification is removed, the timer stops, and the HUD clears

The Glance assistant is not available while the call HUD is visible (the HUD
counts as an active display, blocking the left-hold assistant trigger).

Known gap: if the user dismisses the last carousel notification mid-call (via
tilt-up), the display currently goes blank rather than returning to the call
HUD. Tracked in Backlog (`call-idle-dismiss-fallback`).

If the glasses have not yet pushed a battery reading (e.g. immediately after
connect, before the first `F5 0A`), the battery field is omitted and line 1 is
the wall-clock time alone:

```text
14:32
AppName  ·  09:47
Notification body
```

The idle / "No notifications" branch is unchanged — it still renders:

```text
14:32
--
No notifications
```

It deliberately does not use the bitmap dashboard path because text is much faster and better for ambient notification use.

### Current behaviour

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
- timeout clears the active display after a short interval — unless a call is
  active, in which case the display transitions to the call HUD rather than
  going blank (see "Call HUD" in "Display format" above)

### Glance assistant

- only available while current mode is `Glance`
- only triggers when Glance is idle / forward-facing
- does not trigger while a Glance notification is visible
- does not trigger while the call HUD is showing (the HUD sets `_isVisible = true`, so `hasActiveDisplay` is true and the left-hold assistant path is blocked)
- does not switch into Chat mode
- uses the firmware-native listening overlay during left-hold
- on release, the app:
  - finalises the temp WAV
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

- heavy notification churn can still stress left/right synchronisation
- new notifications are now queued if one is already visible, rather than interrupting the current display

### Current filtering

At notification-ingestion time, noisy system notifications are filtered out, including:
- `System UI`
- charging/battery churn

### Current notification policy

Glance now applies six notification dispositions:
- `blocked`: never shown
- `suppressed`: not shown in the ordinary Glance queue
- `callAbsorbed`: not queued in the Glance carousel; routed to the call idle
  surface (see "Call HUD" in "Display format" above). `shouldBlockFromGlance`
  returns `true` for this disposition. Call state is cleared when the source
  notification is removed.
- `protected`: shown in the queue but never dismissed by Glance gestures
- `normal`: shown and dismissible
- `mediaAbsorbed`: not queued in the Glance carousel; absorbed into the Glance
  time line as the media suffix on line 1 (see "Display format" above).
  `shouldBlockFromGlance` returns `true` for this disposition. Media state is
  cleared when the source notification is removed.

Classification into `mediaAbsorbed` uses two-tier detection:
1. Auto-detect: notification has `isMediaStyle == true` **and** either
   `category == 'transport'` or `channelId` contains `media`, `playback`, or
   `transport`.
2. Per-app override: the "Now Playing" toggle in Settings → Notification
   Filters sets `media_override` in SQLite, forcing the classification
   regardless of style/channel heuristics.

Applies to streaming apps such as Spotify, YouTube Music, Podcast Addict, and
YouTube when they post media-style notifications.

Current handling:
- blocked:
  - companion app notifications
- callAbsorbed:
  - active phone call notifications (`com.samsung.android.incallui`, `isOngoing == true`, `category == 'call'` or `CallStyle` template) — routed to the call idle surface rather than the carousel
- protected:
  - YouTube notifications
  - pinned/live score notifications (Google app pinned live score and Samsung AOD sports wrapper)
- suppressed:
  - most ongoing notifications (call notifications are intercepted before this rule applies)
  - low-value `Open on phone` / `Open your phone for details` style handoff notifications
  - user-suppressed packages such as SmartThings / Samsung Camera when toggled off

Current safety rules:
- protected notifications are never dismissed by Glance gestures
- ongoing notifications are never dismissed by Glance gestures

### Current package suppression controls

- the Settings screen includes a `Notification Filters` section
- it shows recently seen packages
- each package row now has two toggles:
  - **Now Playing** — enables `mediaAbsorbed` classification for that package,
    absorbing its notifications into the Glance time line instead of the
    carousel; stored as `media_override` in SQLite (DB v2,
    `notification_settings_store.dart`)
  - **Mute** — suppresses the package entirely from Glance
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
- The companion app **re-pushes these on every BLE reconnect**, overriding
  whatever the official Even Realities app may have set while disconnected.
  This applies to brightness level, auto-brightness, tilt-up behaviour, and
  double-tap action. Only settings that have been interacted with at least
  once in this app are pushed — never-touched settings are left at the
  firmware's current value. See `current-architecture.md` — "Authoritative
  settings model" for the full design rationale.

## Capture mode

Capture is practically usable and has survived at least one long real-world recording session, but stop/save semantics still need broader confidence.

### Intended behaviour

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

### Current intended behaviour

- user switches app into Navigate mode on phone
- Google Maps notifications are ingested
- concise turn guidance is shown in the glasses
- ordinary Glance notifications are suppressed or deprioritised while navigating

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
- on mode entry, a "Navigate" title card is shown for ~500 ms **only when
  no nav instruction is currently held**. When an instruction is already in
  hand, the title card is suppressed entirely — a clear sequence fired mid-bootstrap
  would cancel the nav session start. The glasses stay on whatever was displayed
  before until the first Maps notification triggers the nav card. The idle prompt
  ("Open Google Maps to start navigation") is not sent on mode entry regardless.

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
  library once lifecycle/update behaviour is fully trusted.

## Chat mode

Chat mode is now a working v1 feature.

### Gesture flow

- entering Chat mode creates a fresh in-memory session
- idle state shows `Chat ready` / `Tilt up to talk`
- tilt up starts listening from the glasses mic after a short `500ms` intent gate
- tilt down stops capture and submits what was said
- once the transcript is available, Chat enters the `0x52` conversation
  surface
- the transcribed user question and a `G1: Thinking...` placeholder are
  shown via `0x4E` while waiting for the backend
- when the assistant reply starts streaming, the render queue takes over
  the glasses display via a fresh `0x52` surface and sends the reply word
  by word (line 1 `\n` marker + line 2 growing text; host-managed
  scrolling keeps the last 3 lines visible)
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
- the visible Chat surface is displayed via `0x52` streaming text
  (`Confirmed`, 2026-05-01):
  - `0x50` display mode control + `0x52` init before the first streamed frame
  - `0x53` keepalive sent every 5 s while the `0x52` surface is active
  - non-streaming renders (user turn, Thinking) use `0x4E` text blocks
- assistant reply rendering is paced by a `StreamingRenderQueue`:
  - backend chunks only append to a target text buffer
  - the queue drains 2 words every 200 ms (~450 WPM effective with BLE
    overhead)
  - each tick: adds 2 words to displayed text, wraps with `\n` at 43-char
    word boundaries, keeps only the last 3 lines (matching the firmware's
    3 visible rows), sends line 1 (`\n` marker) + line 2 (visible text)
  - scrolling is host-managed — the firmware does NOT auto-scroll; the
    host trims the oldest line when a 4th line wraps
  - the queue keeps draining after the backend stream completes until
    all text is displayed, then signals completion via `onDrained`
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
- the `0x52` render path is fully working (`Confirmed`, 2026-05-01):
  host-managed scrolling (43 chars/row, 3 visible rows, 2 words/tick at
  200 ms); long-answer behaviour confirmed — oldest line is trimmed as new
  content wraps
- during assistant streaming the glasses show only the assistant reply
  (all on line 2), not the user question as context
- the user question is visible during the "Thinking..." phase and again
  in the final committed view after streaming completes
- there is no spoken TTS reply in this phase
- there is no consumer ChatGPT account linking in this phase

## Quick mode switching

Quick mode switching is now part of normal companion behaviour.

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

### App and glasses behaviour

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

## Mode-entry title cards and reconnect behaviour

### Mode-entry title cards

On entering Glance or Navigate mode (via double-tap, notification action, or app UI), the glasses
briefly flash the mode name before auto-clearing.

| Mode | Title text | Duration | Condition |
|---|---|---|---|
| Glance | `Glance` | ~500 ms | Always |
| Navigate | `Navigate` | ~500 ms | Only when no nav instruction is currently held |

The title card is rendered via `Proto.showTitleCard` (the `0x4E` text path), then auto-cleared
with `0x50 + 0x18` after the duration elapses. There is no persistence — the glasses return to
blank after the clear.

**Navigate hard constraint:** when a nav instruction is already in hand, the Navigate title card
is suppressed entirely. The clear sequence that ends a title card would cancel the nav session
bootstrap if it landed mid-replay. See "Current status" in the Navigate section above, and
`current-architecture.md` § "Transport health and recovery" for the `CompanionController` design.

Capture and Chat do not receive title cards in this version.

### Reconnected force-clear

On transport recovery after a real disconnect, the app:

1. Flashes "Reconnected" on the glasses for ~1 s (via `Proto.showTitleCard`).
2. Force-clears the display with `0x50 + 0x18`.
3. Conditionally resumes content in this priority order:
   - **REC indicator** — if a Capture recording is active.
   - **Nav refresh** — if Navigate was the visible mode and a nav instruction is held.
   - **Call HUD** — if a phone call is active.
   - **Blank** — otherwise; no content is sent.

The first connect of each app session is excluded — the "Reconnected" flash only fires on
reconnects after a real disconnect, not on the initial pairing at startup.

**Rationale:** after a partial or full disconnect the glasses can be left with stuck or stale
content on one or both lenses. The reconnect event is the natural moment to force-clear. The
previous behaviour — resending the last visible text via `TextService.resendLastText` and
`FeaturesServices.resendLastBmpData` — has been removed; replaying stale Glance content on
reconnect was the wrong policy.

See `current-architecture.md` § "Transport health and recovery — Reconnect display recovery"
for the implementation detail.

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

Current runtime behaviour:
- left and right legs are monitored separately
- heartbeat success is tracked per leg
- repeated heartbeat/request failures can mark one leg degraded without declaring the whole session dead
- degraded legs can trigger bounded reconnect attempts
- **single-leg disconnects now trigger automatic reconnect:** if one leg drops while the other
  stays up, the app detects this and attempts to restore the dropped leg without any manual
  action or full-session teardown. Previously, only a full both-legs-down disconnect triggered
  automatic recovery for a single-leg drop.
- when transport recovers after a real disconnect (not the first connect of a session), the app
  flashes "Reconnected" for ~1 s, force-clears the display via `0x50 + 0x18`, then conditionally
  resumes content — see "Mode-entry title cards and reconnect behaviour" below

Practical effect:
- one eye can remain usable while the other is recovering
- single-leg drops auto-recover without requiring a manual `Force Reconnect`
- on full-session reconnect, a force-clear ensures stale content from either lens is wiped before
  content is conditionally restored
- a restart/reconnect should no longer be the only way to recover from every partial transport problem

## Auto-reconnection

The app reconnects automatically in two scenarios: after an unexpected full disconnect, and on app launch when a previously-paired device is known.

### Post-disconnect auto-reconnect

When the glasses disconnect unexpectedly, the app attempts reconnect using exponential backoff:

| Attempt | Delay before attempt |
|---|---|
| 1 | Immediate (0 s) |
| 2 | 30 s |
| 3 | 60 s |
| 4 | 120 s |

After four attempts without success, the app gives up and waits for a manual `Force Reconnect`.

With the native reconnect path now using `autoConnect=true`, devices coming back into range after a drop (glasses removed and replaced, briefly pocketed, emerging from sleep) should reconnect silently within approximately 10 seconds without any manual intervention.

During active reconnect attempts, the connection status shown in the app is `Reconnecting...`.

### Cradle-aware skip

Before starting auto-reconnect, the app checks the last known wear state (persisted in `AppSettingsStore`). If the glasses were last seen in cradle — `F5 08` or `F5 0B` — auto-reconnect is skipped entirely. The assumption is that the user deliberately put the glasses away, and retrying would be unwanted churn.

Auto-reconnect proceeds only when the last recorded wear state was worn (`F5 06`) or is not yet known (the app has never received a wear-state event from the current pairing).

The persisted wear state survives both disconnection and app restart, so the cradle-check works correctly even if the app is restarted while the glasses are in their case.

### Single-leg auto-reconnect

If one leg disconnects whilst the other remains connected (for example, the left temple briefly
goes out of range), the app detects this and attempts to restore the dropped leg automatically.
Up to 3 per-leg reconnect attempts are made. No full-session teardown is triggered, and no
manual `Force Reconnect` is needed.

The check is gated on the session having been fully connected at least once before (`wasConnected`),
which prevents false triggers during initial connection setup when the two legs connect a few
milliseconds apart.

When a leg drop is detected, per-service session flags (`_isListening`, `_isThinking`,
`_isRecording`) are reset synchronously before any reconnect attempt. This prevents stale
in-progress state from a mid-session drop from blocking self-clearing status messages (such as
"Mic start failed") on the recovered leg.

If Android's `autoConnect=true` reconnect path silently pends with no callback (a known Android
behaviour), a 30-second watchdog clears the in-flight flag so the health monitor can retry.

### App-launch auto-connect

On app launch, if a previously-paired device exists (channel number persisted in `AppSettingsStore.ble.last_channel_number`) AND the last recorded wear state is not `inCradle`, the app starts a BLE scan automatically and connects when the known glasses are found. No manual action is required.

If the last wear state was `inCradle`, the launch-time scan is suppressed — consistent with the cradle-aware skip above.

Once a successful connection is made (whether via auto-reconnect or app-launch auto-connect), the authoritative settings re-push applies as normal — see `current-architecture.md` § "Authoritative settings model".

## Home screen

Current behaviour:
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
- during auto-reconnect attempts the connection status shows `Reconnecting...`
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
firmware does not echo it back. On full disconnect, the displayed slider
position and auto flag reset to defaults in the UI. On the next connect, the
persisted values are re-pushed to the firmware as part of the authoritative
settings reconcile (see `current-architecture.md` — "Authoritative settings
model").

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

Current behaviour:
- the app captures recent Android notifications
- recent notifications are cached natively
- Flutter hydrates from that feed and also receives pushed notification events
- phone-side dismissal by notification key is supported on a best-effort basis

This supports:
- Glance mode
- Navigate mode

## Current known problems / open edges

- Glance left/right synchronisation still needs watching under rapid notification arrival
- some notification sources/messages still need smarter formatting
- Capture mode needs real device validation for start/stop/save reliability
- Navigate mode still needs longer human review against real Google Maps walking sessions
- Chat mode still needs broader real-world testing for latency, retries, and edge-case error handling
- Chat `0x52` streaming is confirmed working (host-managed scrolling, 43 chars/row, 3 rows, 200 ms pacing); follow-up turn rendering still benefits from broader real-world observation
