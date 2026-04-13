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

## Glance mode

Glance is currently the main working user-facing feature.

### Display format

Glance is text-only by design:

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
- repeated tilt-up cycles through the feed
- when idle and a pinned live score exists, Glance can show that score as the idle surface
- tilt-up from the idle live-score surface clears it and enters normal recall/cycling
- if a normal notification arrives while the idle live score is showing, the normal notification takes over
- when Glance returns to true idle and the live score still exists, the score reappears automatically
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
- `liveScore`: separate pinned live-score slot, not a normal queue item

Current handling:
- blocked:
  - companion app notifications
- protected:
  - YouTube notifications
- suppressed:
  - most ongoing notifications
  - low-value `Open on phone` / `Open your phone for details` style handoff notifications
  - user-suppressed packages such as SmartThings / Samsung Camera when toggled off
- liveScore:
  - pinned ongoing sports-style score notifications that match the current live-score classifier

Current safety rules:
- protected notifications are never dismissed by Glance gestures
- ongoing notifications are never dismissed by Glance gestures
- live score notifications are never dismissed by Glance gestures

### Current package suppression controls

- the app home screen now includes a `Notification Filters` section
- it shows recently seen packages
- packages can be toggled suppressed / unsuppressed there
- built-in noisy-package suppression seeds currently include SmartThings and Samsung Camera

## Capture mode

Capture is the most important practical mode after Glance, but it is not yet fully proven.

### Intended behavior

- idle + tilt-up -> start recording
- recording + tilt-up -> stop and save
- recording + double tap -> stop and save
- idle + double tap -> no-op
- idle display shows `*`
- show a recording indicator while active
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
- real navigation instructions use a custom BMP card with the Maps-provided maneuver icon and text fields
- updates are throttled and serialized to reduce unstable overlapping BMP uploads

### Current caveat

Navigate v1 depends on how stable Google Maps notification updates are on the real phone/device configuration during longer walks.

## Chat mode

Chat mode is now a working v1 feature.

### Gesture flow

- entering Chat mode creates a fresh in-memory session
- idle state shows `Chat ready` / `Tilt up to talk`
- tilt up starts listening from the glasses mic
- tilt down stops capture and submits what was said
- a short transcript preview may be shown
- `Thinking...` is shown while waiting for the backend
- the assistant reply is rendered via the normal text path
- follow-up turns continue in the same session while Chat mode stays active
- leaving Chat mode resets and discards the session

### Current implementation

- glasses mic audio is captured through the existing native recorder path
- Chat uses a temporary WAV output rather than Capture's saved-public-recording path
- the WAV is transcribed through the configured OpenAI transcription API
- the transcript plus in-memory conversation history are sent to the configured chat backend
- the assistant reply is displayed in the glasses and can page across multiple screens if long

### Response shaping and limits

- the backend uses a smart-glasses-specific system prompt
- responses are biased toward short, practical, high-signal answers
- output tokens are capped at the backend request level
- response characters are also capped locally before display as a second safety rail
- session history is only lightly capped to the most recent messages if it grows unusually large
- there is no summarisation in this phase

### Current configuration

Chat mode requires an OpenAI API key at build/run time.

Known-good examples:

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

## Logging

Current logging posture:
- operational lifecycle and error logs remain enabled
- verbose investigation logs are disabled by default

To re-enable verbose Flutter-side logging:

```powershell
flutter run --dart-define="COMPANION_VERBOSE_LOGS=true"
```

To re-enable native Google Maps payload dumps:

```powershell
adb shell setprop log.tag.MapsNotificationDump DEBUG
adb logcat -s MapsNotificationDump
```

This keeps normal daily-use builds quieter while preserving a path for targeted investigation.

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
