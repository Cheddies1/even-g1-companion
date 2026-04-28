# Even G1 Companion - Agent Context

## What this is
Personal companion app for Even G1 smart glasses, evolved from the old Flutter demo/harness.

Primary target:
- Samsung Galaxy S24 Ultra
- current Android version

This is not a generic SDK or polished cross-device release.

## Product direction
Active app modes:
- `glance`
- `capture`
- `navigate`
- `chat`


## Trusted behaviour
Only build on event meanings we trust from live testing:
- `F5 00` = close active feature / home
- `F5 02` = tilt-up / dashboard-open start
- `F5 03` = tilt-down / dashboard-close start
- `F5 1E` / `30` = dashboard/state-up follow-on
- `F5 1F` / `31` = dashboard/state-down follow-on

Important:
- do not design around single taps
- do not treat Python SDK labels as ground truth
- do not bring bitmap dashboard work back as the main UX

## Key files
- [lib/ble_manager.dart](lib/ble_manager.dart)
- [lib/services/companion_controller.dart](lib/services/companion_controller.dart)
- [lib/services/glance_service.dart](lib/services/glance_service.dart)
- [lib/services/capture_service.dart](lib/services/capture_service.dart)
- [lib/services/navigate_service.dart](lib/services/navigate_service.dart)
- [lib/services/chat_service.dart](lib/services/chat_service.dart)
- [lib/services/device_status_service.dart](lib/services/device_status_service.dart)
- [lib/services/app_log.dart](lib/services/app_log.dart)
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/CompanionForegroundService.kt)
- [android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt](android/app/src/main/kotlin/com/example/demo_ai_even/service/GlassesCaptureRecorder.kt)

## Architectural guardrails
- mode ownership must stay in CompanionController
- do not route gesture behaviour directly inside feature services
- prefer adding narrow hooks over duplicating control flow
- use `AppLog` for all Flutter-side logging; do not reintroduce raw `print()` in `lib/`
  - `AppLog.info` / `AppLog.error` are always on (lifecycle, state changes, error paths)
  - `AppLog.debug` is gated behind `COMPANION_VERBOSE_LOGS=true` (per-event chatter, probes, render traces)
  - always pass a `tag:` matching the subsystem (e.g. `BLE`, `Glance`, `Chat`, `Navigate`, `Companion`)

## Constraints
- preserve working BLE scan/connect/pairing and protocol framing
- prefer narrow changes over broad rewrites
- keep text rendering as the primary UX path
- treat the Android notification listener and foreground service as core app foundations
- Glance has no special live-score idle surface; pinned/live score notifications stay in the normal protected notification flow


## Read first
- [README.md](README.md)
- [docs/current-architecture.md](docs/current-architecture.md)
- [docs/current-behaviour.md](docs/current-behaviour.md)
- [docs/even-g1-event-mapping.md](docs/even-g1-event-mapping.md)
- [docs/protocol-reference.md](docs/protocol-reference.md)
