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
- `capture`: implemented for practical on-device use, still needs ongoing validation
- `navigate`: implemented and working for walking navigation, still open to incremental tuning
- `chat`: implemented as a practical v1 voice loop

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
- active-display-state decision making
- interpretation of trusted glasses events
- routing into mode-specific services
- notification event subscription
- background-mode synchronization with the Android foreground service

Supporting model:
- [lib/models/app_mode.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/models/app_mode.dart)

Current mode vs active display:
- `current mode` means which service should own the next interaction
- `active display` means whether something is currently being shown on the glasses right now
- quick mode switching depends on `active display`, not only on `current mode`

Current active-display sources:
- visible Glance item
- active Capture display
- visible Navigate card
- visible Chat content

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
- [lib/services/navigate_bitmap_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/navigate_bitmap_service.dart)

Owns:
- latest maps-derived guidance model
- text fallback for startup / waiting states
- Navigate-only BMP card rendering for real Google Maps guidance
- suppression / prioritization rules relative to Glance

### Chat
- [lib/services/chat_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/chat_service.dart)
- [lib/services/chat_backend.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/chat_backend.dart)
- [lib/services/openai_chat_backend.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/openai_chat_backend.dart)
- [lib/services/openai_transcription_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/openai_transcription_service.dart)

Owns:
- Chat mode session lifecycle
- in-memory turn history while Chat mode remains active
- start / stop / submit flow driven by trusted gestures
- STT handoff
- backend request / response handling
- concise text-state rendering back to the glasses

Current backend seam:
- `ChatService` depends on the `ChatBackend` abstraction, not a controller-level hardcoded backend
- the current v1 implementation uses an OpenAI-compatible backend and OpenAI transcription API
- the backend can be replaced later without rewriting mode ownership

## Quick mode switching

Quick switching is routed centrally through:
- [lib/services/companion_controller.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/companion_controller.dart)

Input paths:
- Android foreground notification action buttons
- phone UI mode selector

Notification path:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)
- [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart)

Current behavior:
- notification actions request a passive mode switch
- the controller performs the actual switch
- the foreground notification is updated to reflect the new mode
- tapping the notification body opens the main app screen

Phone UI path:
- the home screen mode buttons route through the same central controller `setMode(...)` path
- mode selection is immediate and does not depend on a temporary title-card overlay

Glasses close path:
- `F5 00` has one trusted meaning only:
  - if something is active on the glasses, close it
  - if the display is idle, do nothing

Current request shaping:
- the OpenAI-compatible backend applies a glasses-specific system prompt
- request output is bounded with a max completion token limit
- response text is also capped locally before being rendered to the glasses

Current session-history behaviour:
- the full in-memory Chat turn list is tracked while Chat mode stays active
- requests currently send only the most recent history window when the conversation grows beyond a light cap
- there is no summarisation in this phase
- the cap is intentionally light-touch so useful follow-up context is preserved for normal conversations

Current mode-entry idle displays:
- `capture`: `*`
- `chat`: `Chat ready` / `Tilt up to talk`
- `navigate`: `Open Google Maps` / `to start navigation` unless a live instruction is already available
- `glance`: no separate idle title card; content appears only when a Glance item is actually shown

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

Maps payload dump logging:
- the Android notification listener still contains a deep Google Maps payload dump path for investigation
- it is now gated behind the native log tag `MapsNotificationDump` and is off by default

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

Chat mode reuse:
- Chat reuses the same native LC3 decode and PCM buffering path
- for Chat, a narrow native method returns a temporary local WAV file instead of publishing to MediaStore
- that temp WAV is used for speech transcription, then deleted

This keeps Capture and Chat on the same proven recorder foundation while allowing different stop/output behavior.

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

Chat mode is intentionally wired into the same simple mode selector. There is no settings UI for backend configuration in this phase; Chat backend configuration is done at build time with `dart-define`.

## Logging posture

The app now uses a split logging posture:
- concise operational lifecycle/error logs remain enabled by default
- verbose investigation logs are gated behind:
  - Flutter build-time define: `COMPANION_VERBOSE_LOGS=true`
  - Android log tag enablement for Maps payload dumps: `MapsNotificationDump`

This keeps day-to-day release builds quieter while preserving useful diagnosis paths when needed.

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
