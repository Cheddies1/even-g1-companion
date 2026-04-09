# Even Companion App - Agent Context

## What this is
This project started as an Even G1 demo/harness app and is being reshaped into a personal companion app for Even G1 smart glasses.

It is not being treated as a general-purpose SDK or polished consumer product.

Primary target device:
- Samsung Galaxy S24 Ultra
- Current Android version

## Product direction
The app is moving toward a mode-based companion:
- `glance`
- `capture`
- `navigate`
- `chat`

Current phase:
- `glance` implemented and actively used
- `capture` scaffolded / partially implemented
- `navigate` scaffolded
- `chat` architecture seam only, not end-to-end

## Current architecture
Minimal mode-based structure:
- [lib/models/app_mode.dart](lib/models/app_mode.dart)
- [lib/services/companion_controller.dart](lib/services/companion_controller.dart)
- [lib/services/glance_service.dart](lib/services/glance_service.dart)
- [lib/services/capture_service.dart](lib/services/capture_service.dart)
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart)
- [lib/services/chat_service.dart](lib/services/chat_service.dart)

Phone UI:
- [lib/views/home_page.dart](lib/views/home_page.dart)
- [lib/main.dart](lib/main.dart)

BLE/event entry point:
- [lib/ble_manager.dart](lib/ble_manager.dart)

Android/native bridge:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)

## Background/permanent companion foundation
This app is intended to function as a permanent companion app, not just while the activity is open.

Current background foundation:
- Android foreground service:
  - [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)
- Manifest/service registration:
  - [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml)

The foreground notification should reflect the current mode.

## Trusted gesture / event mappings
Build only on mappings that have been confirmed enough to trust:

- `F5 00` = close active feature / home
- `F5 02` = tilt-up / dashboard-open start
- `F5 03` = tilt-down / dashboard-close start
- `F5 1E` / event `30` = dashboard/state-up confirm or follow-on
- `F5 1F` / event `31` = dashboard/state-down confirm or follow-on

Notes:
- Single taps are not reliable app-visible input in the tested flows.
- Do not design core UX around single taps.
- Right-hold QuickNote exists in firmware but is not part of the current app plan.
- `0x22` appears to be a dashboard-related packet family and is logged for diagnostics only.

## Glance mode
Glance is the most mature implemented mode.

Behavior:
- Android notifications can auto-pop into the glasses using text rendering
- deliberate tilt-up recalls latest notification
- repeated tilt-up cycles through recent notifications
- `F5 00` closes
- short timeout clears the view

Text format:
```text
14:32
--
AppName
Notification body
```

Important implementation details:
- uses text rendering, not BMP/bitmap dashboard
- notification ingestion is native Android -> Flutter feed
- deliberate cycling dismisses phone notifications
- proactive auto-pop does not dismiss on phone

Current Glance caveats/fixes:
- dismissed notifications must also be removed from the local in-app queue
- overlapping auto-pop while a notification is already visible can desync left/right rendering
- current mitigation in [lib/services/glance_service.dart](lib/services/glance_service.dart):
  - dismissed items are removed from local queue
  - renders are serialized
  - new auto-pop notifications are queued into the feed but do not interrupt the currently visible item

## Notification ingestion
Native notification listener:
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt](android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt)

Flutter model:
- [lib/models/companion_notification.dart](lib/models/companion_notification.dart)

Current behavior:
- recent notifications are cached natively and hydrated into Flutter
- notification listener can push posted/removed events into Flutter
- phone notifications can be dismissed by notification key

Current filtering:
- noisy `System UI` / charging / battery notifications are filtered out at ingestion time

## Capture mode
Goal:
- start recording from glasses mic
- save WAV locally on the phone
- no transcription in-app yet

Flutter service:
- [lib/services/capture_service.dart](lib/services/capture_service.dart)

Native recorder:
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)

BLE/native audio path:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)

Important technical assumption:
- the app already receives mic audio from the glasses and decodes LC3 to PCM natively
- decoded PCM is appended into a WAV recorder

Important caveat:
- mic start is proven
- clean stop semantics still need real device validation
- do not assume capture is fully production-stable yet

## Navigate mode
Navigate is intentionally lean and notification-driven.

Current idea:
- user enables Navigate mode on phone
- app consumes Google Maps notifications
- glasses show concise turn guidance text

Current implementation seam:
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart)

This is still a v1 scaffold. Keep it simple and text-only.

## Chat mode
Chat is future work in this phase.

Do not implement full ChatGPT integration casually.

Current seam:
- [lib/services/chat_service.dart](lib/services/chat_service.dart)

Future Chat mode is intended to support:
- hold-left ask/listen flow
- speech recognition
- session continuity for a single active chat session
- short response rendering in glasses
- linkage to the user's own ChatGPT/OpenAI identity/session

## BLE / rendering paths to preserve
Do not rewrite these unless there is a clear blocker:
- BLE scan/connect and left/right pairing
- native transport and protocol framing
- existing text rendering path
- existing method/event channel bridge

The app depends on proven transport more than elegant architecture.

## Demo code status
This is no longer being treated as a feature-zoo demo app.

Preferred direction:
- keep legacy/demo surfaces isolated or de-emphasized
- keep useful debugging hooks
- avoid reviving BMP dashboard work as the primary UX

BMP dashboard experiments happened earlier, but Glance mode deliberately uses text because it is much faster and better for real use.

## Python SDK relationship
There is a sibling repo used only as a reference:
- `../eveng1_python_sdk`

Treat it as:
- a hypothesis source
- a secondary protocol reference

Do not assume all of its event labels are correct.

Currently strong alignment:
- dashboard-related `F5 02 / 03 / 1E / 1F`

Still speculative elsewhere:
- many battery / state labels
- single-tap assumptions

Important:
- this Flutter investigation is ahead of the Python SDK on the `R21` QuickNote path.

## Current docs worth reading first
- [docs/companion-app-migration-plan.md](docs/companion-app-migration-plan.md)
- [docs/companion-app-first-pass.md](docs/companion-app-first-pass.md)
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md)
- [docs/even-demo-app-investigation-notes.md](docs/even-demo-app-investigation-notes.md)
- [docs/python-sdk-comparison-notes.md](docs/python-sdk-comparison-notes.md)

## How to run
```powershell
flutter run
```

Build check:
```powershell
flutter build apk --debug
```

## What matters most
- BLE stability and not breaking known-good transport
- keeping left/right glasses output synchronized
- Glance mode responsiveness and correctness
- background/foreground service lifecycle
- notification ingestion quality
- capture reliability

## What to avoid
- large BLE rewrites
- designing around unproven single-tap input
- reintroducing bitmap dashboard as the main interaction path
- over-engineering frameworks around a practical personal app
- blindly trusting the Python SDK over real device behavior
