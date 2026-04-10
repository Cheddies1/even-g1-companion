# Even G1 Companion

Personal companion app for Even G1 smart glasses.

This project started from the vendor-style Flutter demo app, but it is now being reshaped into a practical personal companion app built around the BLE, rendering, and notification paths that have already been proven on real hardware.

It is not being treated as a generic SDK or polished public consumer app.

Primary target:
- Samsung Galaxy S24 Ultra
- Current Android version

## What The App Does

The app currently supports a mode-based companion model:
- `Glance`
- `Capture`
- `Navigate`
- `Chat`

Quick mode switching is available through:
- actions on the persistent Android notification
- the app UI mode selector

### Glance
Glance is the most complete mode today.

It provides:
- Android notification ingestion
- lightweight text rendering to the glasses
- proactive notification auto-pop into the glasses
- deliberate notification recall/cycling with head tilt
- double-tap close

Typical display format:

```text
14:32
--
WhatsApp
Running 5 late
```

Glance notification policy:
- the companion app's own notifications are blocked from Glance
- YouTube and Google Maps notifications are protected, so they can be shown but are not dismissed by Glance gestures

### Capture
Capture mode is intended for practical meeting / voice capture from the glasses mic.

Current direction:
- start recording from a trusted glasses gesture
- stop and save a WAV file on the phone
- show simple status / save confirmation in the glasses

On the current Android target, saved WAV files are published into the public recordings collection so they appear in normal phone storage under:
- `Internal storage/Recordings/Even Companion`

The save target is now user-visible, but Capture mode still needs focused device validation for end-to-end stop/save reliability.

### Navigate
Navigate mode is a lightweight notification-driven navigation surface.

Current direction:
- consume Google Maps navigation notifications
- show concise turn guidance in the glasses
- suppress or deprioritize ordinary Glance notifications while navigating

This is now implemented as a Navigate-only visual card path:
- startup / waiting states stay text-rendered
- real Google Maps nav cards use the Maps-provided maneuver icon bitmap
- distance, road/context text, and route metadata are composed into a custom BMP card

Navigate is working, but still needs longer real-world walking validation for timing and stability.

### Chat
Chat mode is now implemented as a practical v1 voice loop.

Current flow:
- enter `Chat` mode
- tilt up to start listening from the glasses mic
- tilt down to stop capture and submit
- speech is transcribed to text
- the app briefly confirms what was heard
- the app shows `Thinking...`
- the assistant reply is rendered in the glasses using the existing text path
- follow-up turns stay in the same in-memory session while Chat mode remains active
- leaving Chat mode resets the session

This is not tied to a ChatGPT consumer/web session. Chat v1 uses an API-backed backend seam so the transport can be swapped later without rewriting the mode.

## Quick Mode Switching

The companion app now supports fast mode changes without opening the full phone UI.

Available paths:
- persistent Android notification actions:
  - `Glance`
  - `Capture`
  - `Navigate`
  - `Chat`
- app UI mode selector

Glasses rule:
- if something is actively shown on the glasses, double tap closes it
- if nothing is currently active on the glasses, double tap does nothing

Quick switching is passive:
- it changes the current mode
- it does not auto-start recording
- it does not auto-start listening
- it does not auto-open navigation content
- it does not force a Glance render

Mode-entry displays:
- `Capture` shows `*` when idle and ready
- `Chat` shows `Chat ready` / `Tilt up to talk`
- `Navigate` shows `Open Google Maps` / `to start navigation` until a live navigation instruction is available
- `Glance` remains notification-driven and does not show a separate idle title card

Response shaping:
- Chat responses are explicitly shaped for smart glasses
- the backend prompt biases toward concise, practical, small-display answers
- short sentences and compact chunks are preferred over long paragraphs
- actionable next steps are prioritised over background explanation

## Trusted Glasses Interaction Model

The app is built only on interactions we trust from live testing.

Currently trusted:
- `F5 02` = tilt-up / dashboard-open start
- `F5 03` = tilt-down / dashboard-close start
- `F5 00` = close active feature / home
- `F5 1E` = dashboard/state-up follow-on
- `F5 1F` = dashboard/state-down follow-on

Important:
- single taps are **not** treated as a reliable core input in this app
- this repo does **not** assume `0xF5 0x01` is a trustworthy single-tap event for production behavior
- right-hold QuickNote exists in firmware, but is not part of the current app feature set

## Technical Shape

This app keeps the proven vendor/demo transport path and refactors around it rather than replacing it.

Key parts:
- Flutter mode/controller layer
- native dual-BLE Even G1 connection handling
- existing text rendering path
- Android notification listener
- Android foreground companion service
- native glasses-mic audio decode path
- Chat STT + backend request seam

## Project Structure

Important Flutter files:
- [lib/ble_manager.dart](lib/ble_manager.dart)
- [lib/models/app_mode.dart](lib/models/app_mode.dart)
- [lib/services/companion_controller.dart](lib/services/companion_controller.dart)
- [lib/services/glance_service.dart](lib/services/glance_service.dart)
- [lib/services/capture_service.dart](lib/services/capture_service.dart)
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart)
- [lib/services/chat_service.dart](lib/services/chat_service.dart)
- [lib/services/chat_backend.dart](lib/services/chat_backend.dart)
- [lib/services/openai_chat_backend.dart](lib/services/openai_chat_backend.dart)
- [lib/services/openai_transcription_service.dart](lib/services/openai_transcription_service.dart)
- [lib/views/home_page.dart](lib/views/home_page.dart)

Important Android/native files:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt](android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)

## Prerequisites

You need:
- Flutter SDK installed
- Android SDK / platform tools installed
- a paired or pairable Even G1 glasses set
- an Android phone with notification access enabled for the app
- an OpenAI API key if you want Chat mode to work end-to-end

This project is primarily being developed and tested on:
- Samsung Galaxy S24 Ultra

## Android Build Baseline

Current known-good Android toolchain baseline:
- AGP `8.6.1`
- Gradle wrapper `8.7`
- Kotlin Gradle plugin `2.1.10`

## Permissions / Setup

The app depends on a few Android capabilities to be useful:

### Notification Access
Required for:
- Glance mode
- Navigate mode

Enable in Android Settings:
- `Settings > Notification access`
- then enable access for the app

### Bluetooth
Required for:
- scanning
- pairing
- connection to both glasses arms

### Foreground Service
Used so the app can behave like a permanent companion app and continue functioning while backgrounded.

### Chat backend configuration
Required for:
- Chat mode transcription
- Chat mode assistant responses

Current v1 backend:
- OpenAI API

Required build-time define:

```powershell
--dart-define="OPENAI_API_KEY=sk-..."
```

Important:
- pass the raw key value
- do not include square brackets around the key

Optional build-time defines:

```powershell
--dart-define="CHAT_API_BASE_URL=https://api.openai.com/v1"
--dart-define="CHAT_MODEL=gpt-4.1-mini"
--dart-define="CHAT_TRANSCRIPTION_MODEL=gpt-4o-mini-transcribe"
--dart-define="CHAT_TRANSCRIPTION_LANGUAGE=en"
--dart-define="CHAT_MAX_OUTPUT_TOKENS=220"
--dart-define="CHAT_MAX_RESPONSE_CHARS=900"
--dart-define="CHAT_MAX_HISTORY_MESSAGES=16"
--dart-define="COMPANION_VERBOSE_LOGS=true"
```

Debug logging:
- verbose Flutter-side investigation logs are off by default
- enable them with:

```powershell
--dart-define="COMPANION_VERBOSE_LOGS=true"
```

- verbose native Google Maps payload dumps are also off by default
- enable them on a connected device with:

```powershell
adb shell setprop log.tag.MapsNotificationDump DEBUG
adb logcat -s MapsNotificationDump
```

## Running The App

Run in development:

```powershell
flutter run
```

Run in development with Chat mode enabled:

```powershell
flutter run --dart-define="OPENAI_API_KEY=sk-..."
```

Build a debug APK:

```powershell
flutter build apk --debug
```

Build a release APK with Chat mode enabled:

```powershell
flutter build apk --release --dart-define="OPENAI_API_KEY=sk-..."
```

Known-good local validation commands:

```powershell
flutter analyze
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Release validation note:
- `flutter run` is useful for iteration, but it is not sufficient as final validation
- final Android validation requires testing an installed release APK on device

Codex workflow note:
- use Codex for edits and narrow checks
- use a local Windows shell for full build and release validation

## Current Status

### Working Well
- BLE scan/connect to both glasses arms
- text rendering to the glasses
- notification ingestion from Android
- Glance mode notification display and cycling
- Chat mode end-to-end voice loop on device
- deliberate Glance dismissal on phone while cycling
- foreground companion-service foundation

### In Progress / Needs More Device Validation
- Capture mode end-to-end recording reliability
- Navigate mode longer real-world Google Maps walking behavior
- background behavior polish
- left/right render synchronization under heavy notification churn

## What This Repo Is Not

This repo is not currently:
- a full Even protocol reference
- a general-purpose Even SDK
- a polished cross-device Android release
- a consumer ChatGPT account-linked client

It is a practical personal companion app built on the parts of the Even G1 behavior that have been confirmed enough to trust.

## Documentation

Start here:
- [AGENTS.md](AGENTS.md)
- [docs/current-architecture.md](docs/current-architecture.md)
- [docs/current-behaviour.md](docs/current-behaviour.md)
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md)
- [docs/protocol-reference.md](docs/protocol-reference.md)

Additional reference:
- [docs/investigation-notes.md](docs/investigation-notes.md)
- [docs/python-sdk-comparison-notes.md](docs/python-sdk-comparison-notes.md)
- [docs/archive/](docs/archive/)
