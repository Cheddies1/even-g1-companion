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
- `Chat` (architected, not fully implemented yet)

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

### Capture
Capture mode is intended for practical meeting / voice capture from the glasses mic.

Current direction:
- start recording from a trusted glasses gesture
- stop and save a WAV file on the phone
- show simple status / save confirmation in the glasses

The WAV save path is scaffolded and partially implemented, but still needs focused device validation.

### Navigate
Navigate mode is a lightweight notification-driven navigation surface.

Current direction:
- consume Google Maps navigation notifications
- show concise turn guidance in the glasses
- suppress or deprioritize ordinary Glance notifications while navigating

This is currently scaffolded rather than fully polished.

### Chat
Chat mode is future-facing in this phase.

It is intended to support:
- hold-to-ask
- speech recognition
- short response rendering in the glasses
- one active conversation session while Chat mode is selected

Chat is not yet implemented end-to-end, and there is no current OpenAI / ChatGPT account linking in this repo.

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

## Project Structure

Important Flutter files:
- [lib/ble_manager.dart](lib/ble_manager.dart)
- [lib/models/app_mode.dart](lib/models/app_mode.dart)
- [lib/services/companion_controller.dart](lib/services/companion_controller.dart)
- [lib/services/glance_service.dart](lib/services/glance_service.dart)
- [lib/services/capture_service.dart](lib/services/capture_service.dart)
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart)
- [lib/services/chat_service.dart](lib/services/chat_service.dart)
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

This project is primarily being developed and tested on:
- Samsung Galaxy S24 Ultra

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

## Running The App

Run in development:

```powershell
flutter run
```

Build a debug APK:

```powershell
flutter build apk --debug
```

## Current Status

### Working Well
- BLE scan/connect to both glasses arms
- text rendering to the glasses
- notification ingestion from Android
- Glance mode notification display and cycling
- deliberate Glance dismissal on phone while cycling
- foreground companion-service foundation

### In Progress / Needs More Device Validation
- Capture mode end-to-end recording reliability
- Navigate mode real-world Google Maps behavior
- background behavior polish
- left/right render synchronization under heavy notification churn

## What This Repo Is Not

This repo is not currently:
- a full Even protocol reference
- a general-purpose Even SDK
- a polished cross-device Android release
- a finished ChatGPT client

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
