# Current Architecture

This file describes the current stable architecture of the app as it exists now.

It is the architecture view for the current companion app, not the old demo framing.

## Document map
- [current-behaviour.md](current-behaviour.md): user-visible behavior and caveats
- [even-g1-event-mapping.md](even-g1-event-mapping.md): current trusted event meanings
- [protocol-reference.md](protocol-reference.md): raw vendor/demo protocol reference with annotations
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
- `capture`: scaffolded / partially implemented
- `navigate`: scaffolded
- `chat`: architecture seam only

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

## Core controller

Mode ownership is centralized in:
- [lib/services/companion_controller.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/companion_controller.dart)

The controller owns:
- active mode
- interpretation of trusted glasses events
- routing into mode-specific services
- notification event subscription
- background-mode synchronization with the Android foreground service

Supporting model:
- [lib/models/app_mode.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/models/app_mode.dart)

## Main services

### Glance
- [lib/services/glance_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/glance_service.dart)

Owns:
- recent notification feed
- text rendering for Glance items
- auto-pop / deliberate recall timing
- phone-side dismissal of deliberately viewed notifications

### Capture
- [lib/services/capture_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/capture_service.dart)

Owns:
- capture session state
- start / stop / cancel flow
- recording indicator / save confirmation rendering
- bridge calls into native WAV recording

### Navigate
- [lib/services/navigate_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/navigate_service.dart)

Owns:
- latest maps-derived guidance model
- text rendering for navigation cards
- suppression / prioritization rules relative to Glance

### Chat
- [lib/services/chat_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/chat_service.dart)

Current role:
- future seam only
- place for future speech recognition, chat session continuity, and ChatGPT request/response handling

## BLE and protocol path

The app intentionally preserves the working BLE and protocol foundation from the old demo app.

Flutter entry:
- [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart)

Key protocol helper:
- [lib/services/proto.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/proto.dart)

Native BLE manager:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)

Key preserved behaviors:
- dual-leg scan/connect
- left/right pairing by channel
- native GATT notification setup
- existing text rendering send path
- existing LC3 decode path

## Trusted event routing

The app only routes trusted gesture/state events into product behavior:
- `F5 00`
- `F5 02`
- `F5 03`

The broader mapping is documented in:
- [even-g1-event-mapping.md](even-g1-event-mapping.md)

The app does not rely on single taps as a core input.

## Notification ingestion

Native Android listener:
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)

Native rolling store:
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt)

Flutter model:
- [lib/models/companion_notification.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/models/companion_notification.dart)

Bridge methods/events:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)

This listener path is a core foundation for both Glance and Navigate.

Notification policy:
- [lib/services/notification_policy.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/notification_policy.dart)

Current responsibility:
- central classification of notifications as `blocked`, `protected`, or `normal`
- one place for package-based Glance suppression and dismissal protection rules

Current built-in rules:
- block the companion app's own notifications from entering Glance
- protect Google Maps and YouTube notifications from Glance-driven dismissal side effects

## Background / permanent companion foundation

The app is designed to keep functioning as a companion app while backgrounded.

Foreground service:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)

Manifest/service registration:
- [android/app/src/main/AndroidManifest.xml](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/AndroidManifest.xml)

Current role:
- persistent Android notification
- mode label in the notification
- foundation for ongoing companion behavior

This is intentionally minimal, but it is part of the current architecture rather than a future bolt-on.

Foreground service note:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt) uses `specialUse`
- `connectedDevice` was the wrong foreground service type for app startup behavior on the target Android environment

## Capture audio path

Native recorder:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)

Decode path:
- [android/app/src/main/cpp/liblc3.cpp](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/cpp/liblc3.cpp)

Current technical model:
- glasses mic packets arrive natively
- LC3 is decoded to PCM natively
- decoded PCM is buffered privately, then the final WAV is published via Android's public recordings media collection

Capture mode depends on this existing path rather than inventing a new one.

## Phone UI

Current phone control surface:
- [lib/main.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/main.dart)
- [lib/views/home_page.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/views/home_page.dart)

The UI is intentionally simple:
- connection status
- mode selector
- permission/setup affordances
- scan/reconnect
- small debug/status section
- legacy/demo area separated from the main UX

## Legacy / demo code posture

The project is no longer treated as a feature-zoo demo app.

Current stance:
- preserve proven BLE/protocol/rendering code
- de-emphasize or quarantine legacy demo surfaces
- avoid broad deletion while the companion behaviors are still being validated

Old demo material remains useful mainly as:
- protocol harness code
- debug hooks
- historical reference
