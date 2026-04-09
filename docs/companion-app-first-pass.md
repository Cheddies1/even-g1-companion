# Even Companion First Pass

This note describes the first implementation pass from the old demo app toward a
permanent multi-mode companion app.

## What Was Implemented

### 1. Central mode-based app control

Added:

- [lib/models/app_mode.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/models/app_mode.dart)
- [lib/services/companion_controller.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/companion_controller.dart)

This introduces:

- `glance`
- `capture`
- `navigate`
- `chat`

Only one mode is active at a time.

### 2. Phone UI reshaped into a companion control surface

Updated:

- [lib/main.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/main.dart)
- [lib/views/home_page.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/views/home_page.dart)

The home UI now focuses on:

- connection status
- current mode
- mode selector buttons
- notification permission access
- scan/reconnect
- small status/debug readout

Old demo pages are no longer primary UI. They are reachable through a
`Legacy / Debug` section.

### 3. Glance mode

Added:

- [lib/models/companion_notification.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/models/companion_notification.dart)
- [lib/services/glance_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/glance_service.dart)

Behavior in this pass:

- recent notifications are stored as a rolling local feed
- new notifications can auto-pop into vision in text form
- tilt up shows latest / next notification
- double tap closes the glance item
- deliberate tilt-driven recall attempts to dismiss the current phone
  notification through the Android notification listener if practical

Display format is intentionally text-only and compact.

### 4. Navigate mode scaffold with real notification ingestion

Added:

- [lib/services/navigate_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/navigate_service.dart)

Behavior in this pass:

- Google Maps notifications are detected from the existing notification listener
- the latest Maps notification becomes the current navigation instruction
- tilt up in Navigate mode renders the latest instruction using the existing
  text path

This is a narrow v1 based on notification ingestion, not a full Maps SDK
integration.

### 5. Capture mode scaffold with native WAV saving

Added:

- [lib/services/capture_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/capture_service.dart)
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)

Updated:

- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)

Technical path:

- existing native BLE code already receives `VoiceChunk`
- existing native code already decodes LC3 to PCM
- this pass appends decoded PCM into a native recorder
- on stop, the recorder writes a WAV file into the app’s files area

Current capture location:

- app external files or app internal files fallback
- subfolder: `captures`

### 6. Background / permanent companion foundation

Added:

- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)

Updated:

- [android/app/src/main/AndroidManifest.xml](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/AndroidManifest.xml)
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)

Behavior:

- starts a persistent Android foreground service notification
- foreground notification shows current mode label
- notification ingestion remains available through the listener service

### 7. Notification event push from Android to Flutter

Updated:

- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt)

The app now has:

- snapshot pull for recent notifications
- pushed `posted` / `removed` notification events into Flutter
- notification key/package/source/message metadata
- ability to open notification-access settings from Flutter
- best-effort phone-side dismissal by notification key

## What Is Scaffold Only

### Chat mode

Added:

- [lib/services/chat_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/chat_service.dart)

Current state:

- mode exists
- future session seam exists
- button is disabled in the phone UI
- no speech recognition
- no ChatGPT/OpenAI integration
- no linked account/session behavior yet

### Navigate formatting

Navigate currently uses the existing notification text body directly.

That means:

- it is viable for v1 if Google Maps notifications are readable enough
- it is not yet reduced into a polished instruction/distance/ETA model

## Capture Technical Notes

### What is reused

- BLE mic packet receive path
- LC3 decode path in native code
- existing `Proto.micOn(...)`

### What is new

- decoded PCM is now optionally buffered into a recorder
- stopping the recorder writes a valid mono `16 kHz / 16-bit` WAV

### Important limitation

This pass does **not** prove that the glasses mic/session is fully stopped at
the firmware level when the app saves the WAV.

Reason:

- the codebase has a proven `micOn`
- but there is not yet a separately confirmed `micOff` command in the current
  app path

So Capture is technically implemented as far as the current path safely allows,
but needs device validation for stop behavior.

## Navigate Viability For v1

Current assessment:

- probably viable
- but depends on the exact shape of Google Maps notifications on-device

Why it is viable enough for a first pass:

- Android notification ingestion already works
- notification source/package metadata already reaches Flutter
- this avoids a heavy Maps SDK integration up front

What needs real-device confirmation:

- whether Maps notifications consistently expose concise turn text
- whether distance/ETA fields are reliably available in notification text

## Demo Code Cleanup In This Pass

What changed:

- old demo pages are no longer the main UX
- the app title and home UI now present as `Even Companion`
- legacy demo pages are hidden behind a `Legacy / Debug` section

What was not removed yet:

- legacy feature pages
- old dashboard/bitmap experiment files
- old EvenAI-specific classes

Reason:

- the first pass prioritised a safe migration over aggressive deletion
- these can be removed later once the companion modes are validated

## Manual Device Testing Still Needed

### Glance mode

- verify auto-pop on new notifications while app is backgrounded
- verify tilt-up recall/advance behavior in Glance mode
- verify double-tap close
- verify best-effort notification dismissal on deliberate recall

### Capture mode

- verify tilt-up starts recording from glasses mic
- verify second tilt-up stops and saves
- verify double tap stops and saves
- verify WAV files are valid and audible
- verify whether glasses mic streaming actually stops cleanly after save

### Navigate mode

- start real Google Maps navigation
- verify maps notifications reach the app while Navigate mode is active
- verify glasses text is concise enough to be usable
- verify ordinary Glance notifications are effectively deprioritised

### Background foundation

- verify the foreground companion notification persists as expected
- verify mode label updates in the Android notification
- verify notification listener still feeds events with app backgrounded

## Build / Verification Notes

- the project build returned green again after a stale `DashboardService`
  reference in [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart)
  was removed
- a full analyzer run was unreliable in the VS Code runner environment and
  timed out there
- subsequent validation should be done primarily by direct CLI build/run and
  real device testing on the S24 Ultra
