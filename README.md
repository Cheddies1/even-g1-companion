# Even G1 Companion

This repository is two things at once:

1. A reverse-engineered behaviour and protocol knowledge base for the Even
   Realities G1 smart glasses' BLE interface — built from HCI snoop captures
   of the official Android app and live testing on real hardware.
2. A personal Flutter companion app I use to drive the glasses for my own
   day-to-day use.

The companion app is **not** an official SDK, **not** a polished consumer
release, and **not** offered with support for other users — it is shaped
around my own workflow. Most people landing here will probably get more value
from the documentation than from running the app itself.

If you are investigating Even G1 BLE behaviour and want to skip past the
generic vendor demo material, the docs and the raw captures in this repo
should save you a lot of time.

## Start here for protocol and behaviour findings

If your interest is the protocol or the device's actual behaviour, these are
the documents to read first:

- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md) — current
  trusted mapping of every observed `F5` sub-code, with confidence labels and
  evidence.
- [docs/protocol-reference.md](docs/protocol-reference.md) — wire-level
  reference for every command and event family that has been pinned down,
  including the persisted-on-glasses settings opcodes.
- [docs/investigation-notes.md](docs/investigation-notes.md) — broader
  exploratory notes, the firmware / app / persisted-config three-layer model,
  and the running list of what is still unknown.
- [docs/python-sdk-comparison-notes.md](docs/python-sdk-comparison-notes.md) —
  comparison against the public Python SDK, including the places where its
  labels are stale relative to current firmware.
- [docs/current-behaviour.md](docs/current-behaviour.md) — how the companion
  app behaves at runtime; useful as a reference for what a host app is
  expected to do for each gesture / event.
- [docs/current-architecture.md](docs/current-architecture.md) — how the
  companion app is wired internally, for anyone reading the code.

The per-topic write-ups live alongside the other docs:

- [docs/FINDINGS-battery+brightness.md](docs/FINDINGS-battery+brightness.md)
- [docs/FINDINGS-taps.md](docs/FINDINGS-taps.md)
- [docs/FINDINGS-settings.md](docs/FINDINGS-settings.md)

The raw captures and parser scripts that produced them live under
`logs/bluetooth/` in the working tree (`btsnoop_hci_*.log` files,
`parse_btsnoop.py`, `analyze_*.py`, and per-session `wall clock *.md`
annotations). Those raw logs are deliberately kept out of the published
repository — the published findings stand on their own.

## Key confirmed findings

Short list of what these captures and the live testing have pinned down so
far. Each item is detailed in the docs above.

- **Battery push, no polling required.** `F5 0A <pct>` for the glasses,
  `F5 0F <pct>` for the case. Byte 2 is the percentage 0–100. Both temples
  push independently.
- **Wear / cradle state.** `F5 06` worn, `F5 07` transitioning, `F5 08`
  cradle open, `F5 0B` cradle closed.
- **Brightness.** TX `0x01 <level> <auto>` where `level` is `0..42` and
  `auto` is `0/1`. The firmware echoes the actual applied level back as
  `F5 12 <level>` when it changes — the auto flag is not echoed and must be
  tracked locally.
- **Long-press (left).** `F5 17` press-down → `F5 18` release. This is the
  voice / Even AI entry path.
- **Long-press (right) — QuickNote.** Does **not** fire `F5 17` / `F5 18`.
  Instead emits `0x21` on release, and *immediately afterwards* the firmware
  streams a chunked binary blob back on `0x1e c8 ...` whose volume scales
  with recording duration. Bitrate and shape are consistent with a
  low-bitrate voice codec — almost certainly the same LC3 stream the live
  mic uses on `0xf1`, just on a different family. Documented as a future
  audio-decode opportunity for "host-side QuickNote with hosted
  transcription".
- **Triple-tap.** `F5 04` enables silent mode, `F5 05` disables it.
- **Double-tap is the boundary between firmware-handled and host-handled
  actions.** When closing an active feature → `F5 00`. When opening a feature
  configured to a host-handled action (Transcribe / Translate / Teleprompter
  in the official Even app) → `F5 20`. Firmware-native actions (Dashboard) or
  "None" do not cross the BLE boundary at all.
- **Single taps are firmware-only in every state tested.** Idle, dashboard
  with notes list visible, dashboard with notifications visible — the
  firmware visibly responds on the glasses but no BLE event fires. Stop
  designing around them.
- **Persisted-on-glasses settings.** Head-up / tilt-up behaviour:
  `0x08 06 00 00 03 <value>`. Double-tap action: `0x26 06 00 <seq> 05 <value>`.
  Both follow the same shape as the brightness command. The values persist
  in firmware and survive an app uninstall.
- **Note management.** Delete and reorder of saved notes use a three-step
  `0x06 ... / 0x22` ack transaction with an 8-byte note UID — same UID shape
  as the trailing block in `R21` payloads, suggesting `R21` advertises the
  UID of the just-saved note.

## Personal companion app

What follows is the personal app this repo also hosts. It is written for me,
on my hardware (Samsung Galaxy S24 Ultra), and is not intended as a
general-purpose product.

### Modes

- `Glance` — Android notification ingestion, lightweight text rendering to
  the glasses, proactive auto-pop, deliberate recall / cycling with head
  tilt, double-tap to close, plus a Glance-only assistant shortcut that
  reuses the same OpenAI-backed transcription / assistant path as Chat mode.
- `Capture` — start recording from the glasses mic on a trusted gesture, save
  WAV to the public `Internal storage/Recordings/Even Companion` collection.
  Practically usable; stop / save reliability is still an open validation
  item.
- `Navigate` — consumes Google Maps navigation notifications and renders
  concise turn guidance to the glasses. Real maps cards use the Maps-provided
  manoeuvre icon composed into a custom BMP. Working for walking navigation
  but still being shaken out.
- `Chat` — voice loop. Tilt up to start listening, tilt down to submit,
  transcript handed to an OpenAI-compatible backend, the response is
  rendered back to the glasses. Follow-up turns share an in-memory session
  while Chat mode stays active.

### Trusted glasses interaction model

The app routes only events that have held up in live testing:

- `F5 00` — close active feature / home (also fires on double-tap to close)
- `F5 02` — tilt-up / dashboard-open start
- `F5 03` — tilt-down / dashboard-close start
- `F5 17` — left long-press press-down (voice / Even AI start)
- `F5 18` — left long-press release
- `F5 1E` — dashboard / state-up follow-on confirmation
- `F5 1F` — dashboard / state-down follow-on confirmation
- `F5 20` — host-handled double-tap (mode cycle, contingent on the official
  Even app's double-tap action being a host-handled feature; configurable
  from this app's Settings → Firmware Settings dropdown)

Single taps are deliberately not part of the trusted set — see the findings
above. Right-long-press uses the `0x21` family rather than `F5`.

### Quick mode switching

Mode changes can come from any of:

- the persistent Android foreground notification
- the app UI mode selector
- the Settings → Firmware Settings → "Double-tap behaviour" dropdown set to
  "Companion app mode switch", which makes the firmware emit `F5 20` on
  double-tap and the companion app cycles through `Glance` → `Navigate` →
  `Chat` → `Capture` → `Glance`. Cycle is debounced at 1500 ms.
- a narrow idle-only right-hold POC via `R21` that pre-dates the `F5 20`
  path. The packet length gate (`len == 42`) may no longer match current
  firmware, which emits `R21` at length 15 — this POC is not currently
  active user-facing functionality.

### Glasses display rule

- If something is active on the glasses, double-tap closes it (`F5 00` path).
- If the display is idle, double-tap fires `F5 20` if the configured action
  is host-handled, otherwise nothing crosses BLE.

### Firmware settings (in-app)

The Settings page has a "Firmware Settings" section that writes two
persisted-on-glasses values:

- **Tilt-up behaviour** — choose between letting the firmware show its own
  dashboard on tilt-up, or suppressing the firmware overlay so the companion
  app drives any visible response.
- **Double-tap behaviour** — choose between cycling companion app modes (the
  setting that makes `F5 20` fire), opening the firmware dashboard locally,
  or doing nothing.

Both choices are stored on the glasses themselves and survive an app
uninstall. The companion app remembers the last pick across restarts but
deliberately does not re-send on reconnect — invasive to override anything
the user might have changed in the official app between sessions.

### Technical shape

The app intentionally preserves the proven BLE / protocol foundation from
the original vendor demo and refactors around it rather than replacing it.

Key pieces:

- Flutter mode/controller layer
- native dual-BLE Even G1 connection handling
- existing text rendering path (`0x4E`)
- Android notification listener
- Android foreground companion service
- native glasses-mic audio decode path (LC3 → PCM)
- Chat STT + backend request seam (`ChatBackend` abstraction)

### Project structure

Important Flutter files:

- [lib/ble_manager.dart](lib/ble_manager.dart)
- [lib/models/app_mode.dart](lib/models/app_mode.dart)
- [lib/services/companion_controller.dart](lib/services/companion_controller.dart)
- [lib/services/device_status_service.dart](lib/services/device_status_service.dart)
- [lib/services/glance_service.dart](lib/services/glance_service.dart)
- [lib/services/capture_service.dart](lib/services/capture_service.dart)
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart)
- [lib/services/chat_service.dart](lib/services/chat_service.dart)
- [lib/services/chat_backend.dart](lib/services/chat_backend.dart)
- [lib/services/openai_chat_backend.dart](lib/services/openai_chat_backend.dart)
- [lib/services/openai_transcription_service.dart](lib/services/openai_transcription_service.dart)
- [lib/services/app_settings_store.dart](lib/services/app_settings_store.dart)
- [lib/services/proto.dart](lib/services/proto.dart)
- [lib/views/home_page.dart](lib/views/home_page.dart)
- [lib/views/settings_page.dart](lib/views/settings_page.dart)

Important Android / native files:

- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt](android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)
- [android/app/src/main/cpp/liblc3.cpp](android/app/src/main/cpp/liblc3.cpp)

Capture / analysis material:

- [docs/FINDINGS-battery+brightness.md](docs/FINDINGS-battery+brightness.md),
  [docs/FINDINGS-taps.md](docs/FINDINGS-taps.md),
  [docs/FINDINGS-settings.md](docs/FINDINGS-settings.md) — the per-topic
  write-ups produced from the snoop captures.
- `logs/bluetooth/` (kept out of the published repository) — raw HCI
  snoop logs, parser scripts (`parse_btsnoop.py`, `analyze_*.py`), and
  per-session `wall clock *.md` annotations.

### Prerequisites

- Flutter SDK
- Android SDK / platform tools
- a paired Even G1 glasses set
- an Android phone with notification access enabled for the app
- an OpenAI API key if you want Chat mode to work end to end

Primary target: Samsung Galaxy S24 Ultra on current Android. Other devices
are not exercised.

### Android build baseline

- AGP `8.6.1`
- Gradle wrapper `8.7`
- Kotlin Gradle plugin `2.1.10`

### Connection reliability

- Per-leg health is tracked separately (connected / degraded / disconnected).
- Heartbeat `0x25` is sent per leg on a timer.
- Repeated missed heartbeats degrade the leg; degraded legs trigger bounded
  reconnect attempts.
- When a leg recovers, the app resends current active content so left/right
  displays converge again.

### Permissions / setup

- Notification access — required for Glance and Navigate. Toggle under
  `Settings > Notification access` on the phone.
- Bluetooth — required for scanning, pairing, and the dual-leg connection.
- Foreground service — used so the app continues working while backgrounded.

### Chat backend configuration

Recommended setup:

- install one APK
- open `Settings > API / Assistant`
- save your API key once
- optionally save base URL and model overrides

The API key is stored in secure storage; non-secret overrides go into app
preferences. Both persist across restarts and normal upgrades.

Optional `dart-define` fallback:

```powershell
flutter run --dart-define="OPENAI_API_KEY=sk-..."
```

```powershell
--dart-define="CHAT_API_BASE_URL=https://api.openai.com/v1"
--dart-define="CHAT_MODEL=gpt-4.1-mini"
--dart-define="CHAT_TRANSCRIPTION_MODEL=gpt-4o-mini-transcribe"
--dart-define="CHAT_TRANSCRIPTION_LANGUAGE=en"
--dart-define="CHAT_MAX_OUTPUT_TOKENS=220"
--dart-define="CHAT_MAX_RESPONSE_CHARS=900"
--dart-define="CHAT_MAX_HISTORY_MESSAGES=16"
```

Pass the raw key value — do not wrap it in square brackets.

### Debug logging

- Verbose Flutter-side logs are off by default. Enable them with
  `--dart-define="COMPANION_VERBOSE_LOGS=true"`.
- Verbose native Google Maps payload dumps are off by default. Enable on a
  connected device with:

  ```powershell
  adb shell setprop log.tag.MapsNotificationDump DEBUG
  adb logcat -s MapsNotificationDump
  ```

### Running the app

```powershell
flutter run
flutter run --dart-define="OPENAI_API_KEY=sk-..."
flutter build apk --debug
flutter build apk --release --dart-define="OPENAI_API_KEY=sk-..."
```

Validation note: `flutter run` is useful for iteration but is not enough as
final validation. Final Android validation is an installed release APK on
the target phone.

### Current status

Working well:

- BLE scan / connect / dual-leg pairing
- text rendering to the glasses
- Glance notification display, cycling, deliberate dismissal
- Chat mode end-to-end voice loop
- battery / wear / brightness state on the home screen
- Firmware settings dropdowns (tilt-up + double-tap) writing persisted
  values via the newly-decoded settings opcodes
- foreground companion-service foundation

In progress / needs more device validation:

- Capture mode end-to-end recording reliability
- Navigate mode longer real-world Google Maps walking behaviour
- background behaviour polish
- left/right render synchronisation under heavy notification churn

## What this repo is not

- not an official Even Realities SDK
- not a complete protocol specification
- not a polished consumer app
- not a supported app for other users
- not a public product roadmap
- not a consumer ChatGPT client

## Documentation

The full document map:

- [AGENTS.md](AGENTS.md)
- [docs/current-architecture.md](docs/current-architecture.md)
- [docs/current-behaviour.md](docs/current-behaviour.md)
- [docs/current-worklist.md](docs/current-worklist.md)
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md)
- [docs/protocol-reference.md](docs/protocol-reference.md)
- [docs/investigation-notes.md](docs/investigation-notes.md)
- [docs/python-sdk-comparison-notes.md](docs/python-sdk-comparison-notes.md)
- [docs/archive/](docs/archive/)

---

If you are not me, you will probably get more out of the behaviour
documentation in `docs/` than out of the personal companion app itself.
