# Even Companion Migration Plan

This note captures the concrete migration from the old demo-oriented Even app
into a practical personal companion app for one device and one user.

## Product Direction

The project is no longer being treated as a generic Even demo app or SDK.

It is being reshaped into a mode-based companion app with these modes:

1. `Glance`
2. `Capture`
3. `Navigate`
4. `Chat`

Only the first three are in scope for implementation during this phase.
`Chat` is architecture-only for now.

## Migration Principles

- preserve the working BLE scan/connect/pairing path
- preserve the working protocol send path
- preserve the proven text rendering path
- preserve the proven Android notification listener path
- preserve the native LC3 decode path
- stop building around speculative single-tap support
- de-emphasise demo-only pages and old feature-zoo affordances

## What Stays Mostly Intact

- [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart)
  for BLE receive/send plumbing
- [lib/services/proto.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/proto.dart)
  for protocol helpers
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
  for scan/GATT/notification setup and native receive
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)
  for the Flutter/native bridge
- [android/app/src/main/cpp/liblc3.cpp](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/cpp/liblc3.cpp)
  for LC3 decode

## What Is Being Refactored

- phone UI
- event routing
- notification handling ownership
- background/persistent companion behavior
- feature ownership around mode-specific services

## What Is Quarantined

These are no longer first-class product features:

- manual BMP demo sending
- manual raw text demo sending
- manual demo notification sending
- old “Even AI” phone-first demo surfaces
- bitmap dashboard experiments as the primary glance UX

They are not fully deleted yet. They are being moved behind a legacy/debug
surface so the BLE harness remains usable during migration.

## Minimal Architecture

### App mode

- [lib/models/app_mode.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/models/app_mode.dart)

### Central controller

- [lib/services/companion_controller.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/companion_controller.dart)

Responsibilities:

- own the selected app mode
- route trusted glasses gestures into mode-specific actions
- subscribe to Android notification events
- coordinate Glance/Capture/Navigate behavior
- keep the home UI stateful but thin

### Mode services

- [lib/services/glance_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/glance_service.dart)
- [lib/services/capture_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/capture_service.dart)
- [lib/services/navigate_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/navigate_service.dart)
- [lib/services/chat_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/chat_service.dart)

### Background foundation

- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)

### Native capture recorder

- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)

## Gesture Model Used In This Phase

Only the mappings we trust enough to build on are used:

- `F5 02` -> tilt-up start
- `F5 03` -> tilt-down start
- `F5 00` -> close/home when active

Notes:

- `F5 30` and `F5 31` are treated as useful firmware dashboard state signals
  in docs/logging, but not as separate product controls
- single taps are still not treated as reliable product input

## Mode Behavior In This First Pass

### Glance

- default mode
- recent notifications are maintained in-app
- new notifications auto-pop in text form
- tilt up recalls latest / advances feed
- double tap closes

### Capture

- tilt up starts recording
- tilt up again stops and saves
- double tap while recording stops and saves
- visible recording text indicator is shown on the glasses

### Navigate

- Google Maps notifications are ingested through the same notification listener
- latest maps-derived notification becomes the current navigation card
- while Navigate mode is active, Maps notifications replace the shown card

### Chat

- mode exists in the model and phone UI
- disabled in the current UI
- future seam only in this phase

## Background/Persistent App Direction

The app now has a narrow permanent-companion foundation:

- Android foreground service with a persistent notification
- notification ingestion via `NotificationListenerService`
- mode label pushed into the ongoing Android notification
- lifecycle refresh when the app returns to foreground

This is not yet a complete production background architecture, but it is a
workable companion-app base for the S24 Ultra target.

## Tooling / Version Notes

This pass did not attempt a speculative dependency marathon.

What remains true:

- AGP and Kotlin warnings still exist
- the project currently builds and runs after the current migration pass

Pragmatic next upgrade candidates later:

- Android Gradle Plugin to `8.6.x`
- Kotlin plugin to `2.1.x`
- selected Dart package deprecations only when they become relevant to active
  features

## Expected Next Iteration

1. validate the first-pass companion behavior on device
2. confirm capture stop semantics from the glasses mic
3. refine Navigate formatting from real Google Maps notifications
4. decide whether legacy demo pages can be removed instead of just hidden
5. design the future Chat mode seam around real Android speech recognition and
   linked ChatGPT sessions
