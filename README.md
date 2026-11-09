# Even G1 Companion

This repository is two things at once:

1. A reverse-engineered behaviour and protocol knowledge base for the Even
   Realities G1 smart glasses' BLE interface, built from HCI snoop captures
   of the official Android app, a firmware decompilation, and live testing on
   real hardware (firmware 1.6.6).
2. A personal Flutter companion app I use to drive the glasses for my own
   day-to-day use.

The companion app is **not** an official SDK, **not** a polished consumer
release, and **not** offered with support for other users. It is shaped
around my own workflow. Most people landing here will probably get more value
from the documentation than from running the app itself.

If you are investigating Even G1 BLE behaviour and want to skip past the
generic vendor demo material, the docs in this repo should save you a lot of
time.

## Start here for protocol and behaviour findings

If your interest is the protocol or the device's actual behaviour, these are
the documents to read first:

- [docs/protocol-reference.md](docs/protocol-reference.md): wire-level
  reference for every command and event family that has been pinned down,
  including the persisted-on-glasses settings opcodes and the recipe for a
  tap-enabled text surface.
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md): current
  trusted mapping of every observed `F5` sub-code, with confidence labels and
  evidence.
- [docs/firmware-decomp-notes.md](docs/firmware-decomp-notes.md):
  reconciliation against `JohnRThomas/even_realities_decomp`, a Ghidra
  decompilation of the G1 firmware. Every other external source is another
  sender; this one is the receiver, so it outranks them on packet structure
  (and only on packet structure). Records what it confirmed, what it
  corrected (the `0x0a` TRIP_STATUS field model and the `0x06` family model
  were both wrong) and the firmware-native record types we are not using.
- [docs/firmware-decomp-display-relay.md](docs/firmware-decomp-display-relay.md):
  inter-leg forwarding subset, the `0x4E` ack structure, the per-lens `0x39`
  display-state query, and lens roles (right is master, left is slave).
  Display content is not relayed between temples, so the host must write both
  legs.
- [docs/investigation-notes.md](docs/investigation-notes.md): broader
  exploratory notes, the firmware / app / persisted-config three-layer model,
  and the running list of what is still unknown.
- [docs/python-sdk-comparison-notes.md](docs/python-sdk-comparison-notes.md):
  comparison against the public Python SDK, including the places where its
  labels are stale relative to current firmware.
- [docs/external-protocol-wiki-notes.md](docs/external-protocol-wiki-notes.md):
  comparison against external protocol sources: the JohnRThomas wiki, the
  Gadgetbridge `even-g1-custom-drawing-experiment` branch (which names all
  navigation sub-commands), and the ayroblu/bazel-demo Swift implementation
  (which decodes the TRIP_STATUS packet structure and confirms the icon/map
  bitmap dimensions and encoding).
- [docs/g1-companion-apps-comparison-notes.md](docs/g1-companion-apps-comparison-notes.md):
  how other G1 companion apps approach the same problems.
- [docs/current-behaviour.md](docs/current-behaviour.md): how the companion
  app behaves at runtime; useful as a reference for what a host app is
  expected to do for each gesture / event.
- [docs/current-architecture.md](docs/current-architecture.md): how the
  companion app is wired internally, for anyone reading the code.

The per-topic write-ups live alongside the other docs:

- [docs/FINDINGS-taps.md](docs/FINDINGS-taps.md): taps and long-press.
- [docs/FINDINGS-settings.md](docs/FINDINGS-settings.md): persisted settings
  opcodes.
- [docs/FINDINGS-battery+brightness.md](docs/FINDINGS-battery+brightness.md):
  battery, wear state and brightness.
- [docs/FINDINGS-layouts.md](docs/FINDINGS-layouts.md): display layout
  protocol (`0x50`, `0x52`/`0x53` live streaming text, `0x0a` navigation card,
  `0x1e` dashboard injection).
- [docs/FINDINGS-quicknote.md](docs/FINDINGS-quicknote.md): right long-press
  QuickNote recording and audio retrieval.
- [docs/FINDINGS-evenai-flash-on-clear.md](docs/FINDINGS-evenai-flash-on-clear.md):
  the intermittent "Even AI is listening" flash on screen clear, traced to a
  firmware race. Also corrects `0x50`: it is a master-only dashboard-state
  probe, not display-mode control.
- [docs/FINDINGS-nav-marker-tiles.md](docs/FINDINGS-nav-marker-tiles.md):
  position marker bounds and route tiles on the `0x0a` card.
- [docs/FINDINGS-screen-off-gps.md](docs/FINDINGS-screen-off-gps.md): GPS
  behaviour with the phone screen off during walking navigation.

The raw captures and parser scripts that produced them live under
`logs/bluetooth/` in the working tree (`btsnoop_hci_*.log` files,
`parse_btsnoop.py`, `analyze_*.py`, and per-session `wall clock *.md`
annotations). Those raw logs are deliberately kept out of the published
repository; the published findings stand on their own.

## Key confirmed findings

Short list of what the captures, the decomp and live testing have pinned down
so far. Each item is detailed in the docs above.

- **Length-validated framing.** Bytes 1-2 of most commands are a validated
  little-endian total length. A mismatch drops the packet silently.
- **Both legs must be written.** Display content is not relayed between
  lenses. Right is master, left is slave.
- **Battery push, no polling required.** `F5 0A <pct>` for the glasses,
  `F5 0F <pct>` for the case. Byte 2 is the percentage 0-100. Both temples
  push independently.
- **Wear / cradle state.** `F5 06` worn, `F5 07` transitioning, `F5 08`
  cradle open, `F5 0B` cradle closed.
- **Brightness.** TX `0x01 <level> <auto>` where `level` is `0..42` and
  `auto` is `0/1`. The firmware echoes the actual applied level back as
  `F5 12 <level>` when it changes; the auto flag is not echoed and must be
  tracked locally.
- **Long-press (left).** `F5 17` press-down, `F5 18` release. This is the
  voice / Even AI entry path.
- **Long-press (right): QuickNote.** Does **not** fire `F5 17` / `F5 18`.
  Instead emits `0x21` on release (notes-list metadata). The firmware records
  into a circular 4-slot buffer on the glasses; the host requests audio via
  `1e 06 00 <seq> 02 <noteIndex>` and receives an LC3 stream on `0x1e c8`
  chunks (10-byte header + 190-byte payload).
- **Triple-tap.** `F5 04` enables silent mode, `F5 05` disables it.
- **Double-tap is the boundary between firmware-handled and host-handled
  actions.** When closing an active feature it sends `F5 00`. When opening a
  feature configured to a host-handled action (Transcribe / Translate /
  Teleprompter in the official Even app) it sends `F5 20`. Firmware-native
  actions (Dashboard) or "None" do not cross the BLE boundary at all. Over a
  text surface, double-tap arrives as `F5 00`, not `F5 20`.
- **Single taps reach the host only on a tap-enabled surface.** `F5 01`
  fires only while a tap-enabled `0x4E` text surface is up (open `0x31`, pin
  and page with `0x51`). Under the usual `0x4E` status `0x71`, single taps
  never reach the phone.
- **Persisted-on-glasses settings.** Head-up / tilt-up behaviour:
  `0x08 06 00 00 03 <value>`. Double-tap action: `0x26 06 00 <seq> 05 <value>`.
  Both follow the same shape as the brightness command. The values persist
  in firmware and survive an app uninstall.
- **Text rendering (`0x4E`).** Text is capped at 480 bytes with no bounds
  check in firmware. Intermediate chunks ack `0xCB`, the last acks `0xC9`.
- **Live streaming text (`0x52`).** Word-by-word incremental rendering with a
  cursor and live-updating clock. The keepalive must be the full
  `53 06 00 <seq> 03 00` frame; 30 s without one ends the session.
- **Navigation structured card (`0x0a`).** TRIP_STATUS carries
  null-separated text fields (capped at 24/24/64/24/24 bytes; overflow aborts
  the whole packet) plus a built-in direction arrow and a position marker
  (x 6..482, y 6..130). Route tiles go on both map packets. Send a `0x18`
  clear before INIT, and send the master its final map packet after the slave
  has finished.
- **Dashboard data slot injection (`0x1e` TX).** Pushes titled content (note
  title + body) into the firmware's built-in dashboard grid layout.
- **Note management.** Delete and reorder of saved notes use a three-step
  `0x06 ... / 0x22` ack transaction with an 8-byte note UID, the same UID
  shape as the trailing block in `R21` payloads, suggesting `R21` advertises
  the UID of the just-saved note.
- **Link liveness.** Any write within 30 s keeps the link alive. `0x25`
  sub 4 is teleprompter sync, not a real heartbeat.

## Personal companion app

What follows is the personal app this repo also hosts. It is written for me,
on my hardware (Samsung Galaxy S24 Ultra, G1 firmware 1.6.6), and is not
intended as a general-purpose product.

### Modes

- `Glance`: Android notification ingestion with a notification carousel
  paged by single tap on a tap-enabled `0x4E` surface, a media line,
  proactive auto-pop, deliberate recall with head tilt, double-tap to close,
  and a Glance-only assistant shortcut on left long-press. Includes a
  persistent call HUD: active phone calls are detected via
  `TelephonyEventService` (with `READ_PHONE_STATE` permission) and rendered
  as a duration-counting HUD that stays on the glasses for the call's
  lifetime.
- `Capture`: records from the glasses mic with a live HUD and saves WAV to
  the public `Internal storage/Recordings/Even Companion` collection. Phone-mic
  recording is a home-screen button rather than a mode; it uses the same WAV
  format, folder and recordings list.
- `Navigate`: walking navigation on the firmware `0x0a` navigation card.
  Sharing a destination from Google Maps starts a trip; the route bundle
  comes from `cartographer`, a self-hosted routing service, and the app
  tracks GPS progress, swaps route tiles and moves the position marker.
  Routing works inside synced regions, managed from the Regions page. With
  no shared trip, live Google Maps navigation notifications drive the card
  as a fallback.
- `Chat`: voice loop. Tilt up to start listening, tilt down to submit; the
  transcript goes to an OpenAI-compatible backend and the reply streams back
  word by word on `0x52`. Follow-up turns share an in-memory session while
  Chat mode stays active.

QuickNote (right long-press) runs in every mode: the app pulls the LC3 audio,
decodes it to WAV, transcribes it, tidies and categorises it, and files it in
a Notes page with Shopping / To Do / Notes tabs.

### Trusted glasses interaction model

The app routes only events that have held up in live testing:

- `F5 00`: close active feature / home (also fires on double-tap to close)
- `F5 01`: single tap, only while a tap-enabled `0x4E` surface is up
- `F5 02`: tilt-up start
- `F5 03`: tilt-down start
- `F5 04` / `F5 05`: triple-tap silent-mode toggle
- `F5 17`: left long-press down (voice start)
- `F5 18`: left long-press release (voice stop)
- `F5 1E` / `F5 30`: dashboard state-up follow-on
- `F5 1F` / `F5 31`: dashboard state-down follow-on
- `F5 20`: host-handled double-tap (mode cycle), contingent on the glasses'
  double-tap action being a host-handled feature; configurable from this
  app's Settings → Firmware Settings dropdown

Right long-press uses the `0x21` family rather than `F5`. Our own clears and
renders can make the right lens emit `F5 00`, so it is not always a user
gesture.

### Quick mode switching

Mode changes can come from any of:

- the persistent Android foreground notification
- the app UI mode selector
- the Settings → Firmware Settings → "Double-tap behaviour" dropdown set to
  "Companion app mode switch", which makes the firmware emit `F5 20` on
  double-tap and the companion app cycles through `Glance` → `Navigate` →
  `Chat` → `Capture` → `Glance`. The cycle is debounced at 1500 ms and
  blocked while a Capture recording is running.

### Glasses display rule

- If something is active on the glasses, double-tap closes it (`F5 00` path).
- If the display is idle, double-tap fires `F5 20` if the configured action
  is host-handled, otherwise nothing crosses BLE.

### Firmware settings (in-app)

The Settings page has a "Firmware Settings" section that writes two
persisted-on-glasses values:

- **Tilt-up behaviour**: choose between letting the firmware show its own
  dashboard on tilt-up, or suppressing the firmware overlay so the companion
  app drives any visible response.
- **Double-tap behaviour**: choose between cycling companion app modes (the
  setting that makes `F5 20` fire), opening the firmware dashboard locally,
  or doing nothing.

Both choices are stored on the glasses themselves and survive an app
uninstall. The companion app remembers the last pick across restarts and
re-pushes persisted values on every reconnect (the authoritative-settings
model; see `docs/current-architecture.md`).

### Technical shape

The app intentionally preserves the proven BLE / protocol foundation from
the original vendor demo and refactors around it rather than replacing it.

Key pieces:

- Flutter mode/controller layer (`CompanionController` owns modes and
  gesture routing)
- native dual-BLE Even G1 connection handling with per-leg write queues
- pixel-accurate `0x4E` text layout from the firmware glyph-width table
- paced `0x52` streaming queue for Chat
- shared `0x0a` nav card lifecycle for both Navigate paths
- Android notification listener and foreground companion service
- native glasses-mic audio decode path (LC3 → PCM)
- self-hosted speech-to-text plus an OpenAI chat backend

### Project structure

Important Flutter files:

- [lib/ble_manager.dart](lib/ble_manager.dart)
- [lib/services/companion_controller.dart](lib/services/companion_controller.dart)
- [lib/services/proto.dart](lib/services/proto.dart)
- [lib/services/glance_service.dart](lib/services/glance_service.dart)
- [lib/services/glance_carousel.dart](lib/services/glance_carousel.dart)
- [lib/services/capture_service.dart](lib/services/capture_service.dart)
- [lib/services/phone_capture_service.dart](lib/services/phone_capture_service.dart)
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart)
- [lib/services/nav_card_session.dart](lib/services/nav_card_session.dart)
- [lib/services/walknav/](lib/services/walknav/)
- [lib/services/chat_service.dart](lib/services/chat_service.dart)
- [lib/services/streaming_render_queue.dart](lib/services/streaming_render_queue.dart)
- [lib/services/g1_text_layout.dart](lib/services/g1_text_layout.dart)
- [lib/services/openai_chat_backend.dart](lib/services/openai_chat_backend.dart)
- [lib/services/openai_transcription_service.dart](lib/services/openai_transcription_service.dart)
- [lib/services/device_status_service.dart](lib/services/device_status_service.dart)
- [lib/services/recordings_service.dart](lib/services/recordings_service.dart)
- [lib/services/app_settings_store.dart](lib/services/app_settings_store.dart)
- [lib/views/](lib/views/)

Important Android / native files:

- [android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt](android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleChannelHelper.kt](android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleChannelHelper.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/notifications/RecentNotificationsListenerService.kt](android/app/src/main/kotlin/com/eddie/evencompanion/notifications/RecentNotificationsListenerService.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/notifications/NotificationFeedStore.kt](android/app/src/main/kotlin/com/eddie/evencompanion/notifications/NotificationFeedStore.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/CompanionForegroundService.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/CompanionForegroundService.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/GlassesCaptureRecorder.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/GlassesCaptureRecorder.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/PhoneCaptureRecorder.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/PhoneCaptureRecorder.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/WavRecordingStore.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/WavRecordingStore.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/NavLocationService.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/NavLocationService.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/service/RegionSync.kt](android/app/src/main/kotlin/com/eddie/evencompanion/service/RegionSync.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/telephony/TelephonyEventService.kt](android/app/src/main/kotlin/com/eddie/evencompanion/telephony/TelephonyEventService.kt)
- [android/app/src/main/cpp/liblc3.cpp](android/app/src/main/cpp/liblc3.cpp)

### Prerequisites

- Flutter SDK
- Android SDK / platform tools
- a paired Even G1 glasses set
- an Android phone with notification access enabled for the app
- an OpenAI API key if you want Chat mode to work end to end
- a reachable Whisper-compatible transcription endpoint (see below)

Primary target: Samsung Galaxy S24 Ultra on current Android. Other devices
are not exercised.

### Android build baseline

- AGP `8.6.1`
- Gradle wrapper `8.7`
- Kotlin Gradle plugin `2.1.10`

### Connection reliability

- Per-leg health is tracked separately (connected / degraded / disconnected).
- A `0x25` keepalive goes to each leg independently every 2 seconds. It is
  really teleprompter sync; what keeps the link up is any write within 30 s.
- A leg is marked degraded after 8 consecutive missed keepalives; degraded
  legs trigger bounded reconnect attempts, and a single-leg drop reconnects
  that leg without tearing down the session.
- After a real disconnect the app flashes "Reconnected", force-clears both
  lenses and resumes current content (a live nav card is re-booted instead).

### Permissions / setup

- Notification access: required for Glance and the Navigate fallback. Toggle
  under `Settings > Notification access` on the phone.
- Bluetooth: required for scanning, pairing, and the dual-leg connection.
- Phone state (`READ_PHONE_STATE`): required for the call HUD.
- Microphone: required for phone-mic recording, which runs in a
  `microphone`-typed foreground service (without it Android 14+ records
  silence).
- Location: required for walking navigation and region sync.
- Foreground service: keeps the app working while backgrounded.

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
--dart-define="TRANSCRIPTION_API_BASE_URL=http://deepthought:56478/v1"
--dart-define="CHAT_TRANSCRIPTION_MODEL=deepdml/faster-whisper-large-v3-turbo-ct2"
--dart-define="CHAT_TRANSCRIPTION_LANGUAGE=en"
--dart-define="CHAT_MAX_OUTPUT_TOKENS=220"
--dart-define="CHAT_MAX_RESPONSE_CHARS=900"
--dart-define="CHAT_MAX_HISTORY_MESSAGES=16"
```

Pass the raw key value; do not wrap it in square brackets.

### Speech-to-text runs on the local whisper-server

Transcription does not go to OpenAI. Quick Ask, Chat mode and QuickNote all
post to the self-hosted Speaches `whisper-server` on `deepthought`
(`http://deepthought:56478/v1`, model
`deepdml/faster-whisper-large-v3-turbo-ct2`), reached over Tailscale. It is
unmetered and measured at 0.34 s for 9.7 s of glasses audio, roughly 28x
realtime on the RTX 3090, which is faster than the OpenAI round trip.

Consequences worth knowing:

- The endpoint is **tailnet-only and unauthenticated**, so no API key is sent.
  A bearer is attached only when the transcription base URL is `https://`,
  which keeps a token off a cleartext request to a host that ignores it.
- There is **no fallback to OpenAI**. If the box is asleep or the tailnet is
  down, transcription fails and the glasses show `Whisper unreachable`. That
  is deliberate: a silent fallback would spend OpenAI credit without saying so.
- The **reasoning call still goes to OpenAI** (`CHAT_API_BASE_URL`). Only
  speech-to-text moved. Quick Ask therefore needs the local box for the
  transcript and OpenAI for the answer.
- Override both the URL and the model at runtime under Settings → API, so
  repointing at a different endpoint needs no rebuild.

### Debug logging

- Verbose Flutter-side logs are off by default. Enable them with
  `--dart-define="COMPANION_VERBOSE_LOGS=true"`.

- Verbose native Google Maps payload dumps are off by default. Enable on a
  connected device with:

  ```powershell
  adb shell setprop log.tag.MapsNotificationDump DEBUG
  adb logcat -s MapsNotificationDump
  ```

- Debuggable builds also expose adb broadcast hooks (protocol probe, walking
  nav desk test, region sync, GPS trace recorder); see [AGENTS.md](AGENTS.md).

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

Kotlin unit tests run on the JVM with
`cd android && ./gradlew :app:testDebugUnitTest`.

### Current status

Working well:

- BLE scan / connect / dual-leg pairing and auto-reconnect
- text rendering to the glasses
- Glance notification carousel with single-tap paging, deliberate dismissal
  and the call HUD
- QuickNote: right long-press → `0x21` → `0x1e c8` LC3 audio stream →
  STT → tidy → categorised notes in a 3-tab Notes panel
- Chat mode end-to-end voice loop with `0x52` streaming
- glasses-mic Capture and phone-mic recording, with a shared recordings list
- walking navigation on the `0x0a` card (passed a live walk on 2026-11-07),
  with region sync
- time sync on connect
- battery / wear / brightness state on the home screen
- Firmware settings dropdowns (tilt-up + double-tap) writing persisted values

In progress / needs more device validation:

- Navigate: longer real-world walks; the Google Maps notification fallback
  has not been device-tested since its rewrite
- Capture stop/save semantics under continued real-world use
- Chat latency, retries and edge-case error handling
- left/right render synchronisation under rapid notification arrival

The live task queue is [docs/current-worklist.md](docs/current-worklist.md).

## What this repo is not

- not an official Even Realities SDK
- not a complete protocol specification
- not a polished consumer app
- not a supported app for other users
- not a public product roadmap
- not a consumer ChatGPT client

## Documentation

### How this README is organised

This README serves two audiences. The first half (up to "Personal companion
app") is for anyone investigating the G1 BLE protocol: it covers confirmed
findings, evidence basis, and links to the reference documentation. The
second half is for anyone who wants to understand or run the personal Flutter
companion app.

The full document map:

G1 reference layer (public findings):

- [docs/protocol-reference.md](docs/protocol-reference.md)
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md)
- [docs/firmware-decomp-notes.md](docs/firmware-decomp-notes.md)
- [docs/firmware-decomp-display-relay.md](docs/firmware-decomp-display-relay.md)
- [docs/investigation-notes.md](docs/investigation-notes.md)
- [docs/python-sdk-comparison-notes.md](docs/python-sdk-comparison-notes.md)
- [docs/external-protocol-wiki-notes.md](docs/external-protocol-wiki-notes.md)
- [docs/g1-companion-apps-comparison-notes.md](docs/g1-companion-apps-comparison-notes.md)
- [docs/FINDINGS-taps.md](docs/FINDINGS-taps.md)
- [docs/FINDINGS-settings.md](docs/FINDINGS-settings.md)
- [docs/FINDINGS-battery+brightness.md](docs/FINDINGS-battery+brightness.md)
- [docs/FINDINGS-layouts.md](docs/FINDINGS-layouts.md)
- [docs/FINDINGS-quicknote.md](docs/FINDINGS-quicknote.md)
- [docs/FINDINGS-evenai-flash-on-clear.md](docs/FINDINGS-evenai-flash-on-clear.md)
- [docs/FINDINGS-nav-marker-tiles.md](docs/FINDINGS-nav-marker-tiles.md)
- [docs/FINDINGS-screen-off-gps.md](docs/FINDINGS-screen-off-gps.md)

App implementation layer (private):

- [AGENTS.md](AGENTS.md)
- [docs/current-architecture.md](docs/current-architecture.md)
- [docs/current-behaviour.md](docs/current-behaviour.md)
- [docs/current-worklist.md](docs/current-worklist.md)
- [docs/cartographer-contract.md](docs/cartographer-contract.md)
- [docs/plans/](docs/plans/)
- [docs/versioning.md](docs/versioning.md)
- [docs/Setup-Linux.md](docs/Setup-Linux.md)
- [docs/archive/](docs/archive/)

If you are not me, you will probably get more out of the behaviour
documentation in `docs/` than out of the personal companion app itself.
