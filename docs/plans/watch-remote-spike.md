# Spike: Galaxy Watch 6 as a remote for the companion

Status: slices 1-3 built and device-verified, 2026-11-09. Bezel paging dropped (virtual bezel only).

## Answer

It works, and it does not need much. A small Wear OS app (Kotlin + Compose for
Wear OS, its own Gradle project under `wear/`) talks to the phone app over the
Google Wearable Data Layer. The phone gets one `WearableListenerService`, a
platform channel into Dart, and a handful of public intent methods on
`CompanionController`. faceclaw (jimrandomh/faceclaw, `wear/` +
`FaceclawWearBridge.kt`) has already proved this exact shape against a Galaxy-class
Wear OS watch. Use it as a reference, not a source: it is GPLv3.

Rough size: phone side 300-400 lines (Kotlin bridge + Dart dispatcher), watch
side 800-1200 lines for a first useful version. Two to three focused sessions,
no protocol work on the glasses.

## The watch

SM-R940 is the Galaxy Watch6 44 mm (Bluetooth). It has the touch bezel, not the
rotating one (that is the Classic, R950/R960). The touch bezel still arrives as
rotary scroll events, so `onRotaryScrollEvent` in Compose works. Confirmed over
adb on 2026-11-09: Android 16 / API 36 (Wear OS 6, One UI 8 Watch), build
`R940XXS2CZF5`, Google Play services 26.43.30, so the Data Layer is available. The S24 Ultra
pairing through Galaxy Wearable is a normal Wear OS pairing for this purpose.

Hardware keys: Back is usable inside the app; Home is not interceptable.
"Double press Home" can be mapped to launch our watch app, which is the
fastest physical entry point.

## How faceclaw does it

- Transport: Wearable Data Layer. `MessageClient` for watch -> phone commands,
  `DataClient` item (`/faceclaw/state`, urgent) for phone -> watch state,
  `CapabilityClient` to find each other (`faceclaw_phone` / `faceclaw_watch`
  in `res/values/wear.xml`).
- Both APKs share the application id and signing key. The Data Layer silently
  drops traffic between apps that do not match. Debug builds on the same
  machine share `~/.android/debug.keystore`, so it just works.
- Every command carries a `seq`; the phone acks `{seq, ok, jsReady, message}`.
  `jsReady:false` covers "Play services woke the process, but the app UI layer
  is not running", and the watch tells the user to open the phone app.
  Commands are never queued for replay, only idempotent state requests, so a
  stale "next" cannot fire 30 seconds later on whatever is on screen by then.
- State is a single JSON blob, re-published on change and at least every 30 s,
  deduplicated, published off the main thread.
- A watch-side `WearableListenerService` answers battery polls while the watch
  app is closed.
- Watch input is gesture-level (tap, swipe, crown) because faceclaw's glasses
  UI is a generic launcher.

## What differs for us

Use intents, not synthetic gestures. Our F5 meanings are mode-relative and
gated (tilt-up intent delay, self-close window, post-connect voice guard,
tap-surface rules). Replaying fake `F5 xx` events from the watch would inherit
all of that for no benefit. A watch press is already deliberate, so it should
call the action directly:

| Watch command | Controller call |
| --- | --- |
| `mode.set {mode}` | `setMode(mode, source: 'watch')` |
| `capture.start` / `capture.stop` | switch to Capture if needed, then `CaptureService.startRecording()` / `stopAndSave()`, skipping the tilt gate |
| `glance.next` / `glance.prev` / `glance.close` | `GlanceService.showNext()` / `showPrevious()` / `close()` |
| `ask.start` / `ask.stop` | `GlanceAssistantService.startListening()` / `stopListeningAndSubmit()` (same path as the F5 17/18 hold) |
| `nav.stop` | `stopWalkTrip()` |
| `state.request` | re-publish state |

These go in as new public methods on `CompanionController`, so mode ownership
stays there (guardrail) and the watch bridge is a thin router. The single-mic
check already lives in `CaptureService.startRecording` and
`PhoneCaptureService.startRecording`; watch-triggered capture and Quick Ask
reuse those paths, so no new mic consumer appears.

Quick Ask from the watch, in order of cost:

1. Hold a button on the watch = hold the glasses long-press. Glasses mic,
   Speaches STT, existing Quick Ask session logging. Recommended for v1.
2. Watch keyboard or voice input (`RemoteInputIntentHelper`) sends text and
   skips STT. Cheap, but voice goes through Samsung or Google STT, which
   bypasses the self-hosted choice. Typed input is fine.
3. Watch mic audio streamed over `ChannelClient` to the phone, then Speaches.
   Most work, and it adds a mic consumer to the exclusivity check. Not worth
   it while the glasses mic works.

State the phone publishes (one JSON item): connected L/R, active mode, display
owner, recording flag + start time + file name, glance index/count + current
title, assistant phase (listening / thinking / answer text, truncated), walk
trip active + next instruction, glasses and case battery.

## Watch app shape (v1)

- Main screen: current mode as a header, four mode chips, then a mode-specific
  action area: Capture = big Record/Stop with elapsed timer; Glance = prev/next
  (bezel also pages) and the current notification title; Navigate = next
  instruction + Stop; Chat/Ask = hold-to-talk.
- Ongoing Activity while recording, so the timer and a Stop tap sit on the
  watch face without opening the app.
- A Tile with Record/Stop and Ask. Tile clicks use `LoadAction`; the
  `TileService` reads `lastClickableId` and sends the message, so no activity
  launch is needed.
- Haptic on ack, a different one on failure.
- Later: a complication showing mode + recording dot.

## Phone side changes

- `play-services-wearable` dependency in `android/app/build.gradle`.
- `res/values/wear.xml` advertising `evencompanion_phone`.
- `WatchListenerService` (manifest, `MESSAGE_RECEIVED` + `CAPABILITY_CHANGED`,
  path prefix `/evencompanion`) handing off to a `WatchBridge` singleton.
- `WatchBridge.kt`: capability tracking, acks, state publish via `DataClient`.
  Hands messages to Dart over a new channel when the engine is alive, else acks
  `engineAlive:false`. `BleChannelHelper.engineAlive` already exists for this.
- `lib/services/watch_remote_service.dart`: decodes commands and calls the
  controller; listens to controller changes and publishes state (debounced).
- Debug: an adb broadcast that injects a watch command, so the Dart side can be
  tested without the watch (same pattern as the existing PROBE receiver).

Precedent: `CompanionForegroundService` already forwards notification
mode-button taps into Flutter (`ACTION_SET_MODE` -> `forwardModeSwitchToFlutter`).
The watch bridge is the same idea from a different source.

## Risks and gaps

- Engine lifetime is the real limit. The Flutter engine lives with
  `MainActivity`; after a swipe from recents or a process kill, BLE and the
  controller are gone, and a watch command can only get "open the app on your
  phone". Backgrounded-but-alive is fine. A service-owned engine would fix
  this, and auto-reconnect with it, but it is a separate, larger change. Do the
  watch v1 without it and see how often it bites.
- Background activity launch is blocked on Android 14+, so the watch cannot
  start the phone app on its own. Best case is a phone notification the user
  taps.
- Signing: the phone build uses debug signing for release too
  (`android/app/build.gradle`), so building both on deepthought matches. Any
  change to phone signing has to be mirrored in `wear/`.
- Install path: Wi-Fi wireless debugging from deepthought over the home LAN,
  no Tailscale. Paired on 2026-11-09. The watch uses a randomised Wi-Fi MAC
  and its connect port changes after a reboot or Wi-Fi drop, so find it with
  `adb mdns services` (`_adb-tls-connect`) and re-run `adb connect`. Watch
  Wi-Fi is system-managed on One UI 8 Watch, with no "always on" setting: it
  stops while Bluetooth to the phone is up, and comes back when the watch is
  charging, disconnected, or an app needs it. Put the watch on its charger for
  install sessions. Bluetooth has to stay on for end-to-end tests, because
  that is the Data Layer's route to the phone.
- Concurrency with glasses gestures: a watch `capture.stop` and a glasses
  double-tap can race. Both go through the controller, so serialise watch
  commands there and make start/stop idempotent.
- Data Layer latency is typically 100-300 ms over Bluetooth. That is fine for
  commands, but not good enough for gesture streaming (we are not doing that).
- Out of scope: the watch's own sensors (faceclaw's finger-tap detector,
  on-body monitor) and watch battery on the glasses HUD. Both are nice, both
  can wait.

## Suggested first slice

1. Phone bridge + Dart dispatcher + the debug inject broadcast. Prove
   `mode.set`, `capture.start/stop` and `glance.next/prev` from adb.
   Built on branch `watch-remote` (2026-11-09): `watch/WatchBridge.kt`,
   `WatchListenerService.kt`, `lib/services/watch/`, controller
   `remoteCommand`. Every command routes and acks correctly from adb with the
   glasses disconnected. Still to check with the glasses on: a real recording
   start/stop, refusing a mode switch mid-recording, Quick Ask.
2. A minimal watch app with mode chips, Record/Stop and prev/next. Install,
   confirm Data Layer routing and acks on the SM-R940.
   Watch app built 2026-11-09 (`wear/`, Kotlin + Compose for Wear,
   release build for smooth scrolling): mode chips, Record/Stop with timer,
   Glance prev/close/next, hold-to-ask. Device-verified on the SM-R940,
   including a spoken Quick Ask, after fixing the silent-mic trap (see
   `docs/protocol-reference.md`, `0x0E`).
3. State mirror + Ongoing Activity for recording.
   Done 2026-11-09: `record.start`/`record.stop` let the phone pick the mic
   (glasses when connected and out of the case, else the phone mic, which
   starts fine from the background because the companion FGS is running).
   The watch shows a recording timer on the watch face (ongoing activity,
   posted by a background `StateListenerService`) and has a Record tile.
4. Hold-to-ask, then the Tile.

## Not covered here

T3 Code updates on the glasses: parked. Getting T3 Code to push to the phone
reliably comes first, and that problem is on the T3 Code side, not in this app.
