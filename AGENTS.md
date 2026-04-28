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
- `F5 17` = left long-press press-down (voice / Even AI start)
- `F5 18` = left long-press release (voice / Even AI stop)
- `F5 1E` / `30` = dashboard/state-up follow-on
- `F5 1F` / `31` = dashboard/state-down follow-on
- `F5 20` = double-tap delegates to host (fires for any host-handled
  official-app double-tap action — Transcribe / Translate / Teleprompter
  all confirmed; Dashboard is firmware-native and does not fire; None only
  fires `F5 00`. Routed in this app to a passive mode cycle in
  `CompanionController.handleDoubleTapModeSwitch`.)

Important:
- do not design around single taps — confirmed firmware-only in 2026-04-28
  capture across idle and dashboard-list states
- do not treat Python SDK labels as ground truth
- do not bring bitmap dashboard work back as the main UX
- right long-press (QuickNote) does NOT fire `F5 17` / `F5 18`; it uses the
  `0x21` family. Left and right long-press are not symmetric.
- the persisted-on-glasses settings opcodes `0x08` (head-up) and `0x26` (touch)
  and the post-quicknote-release `0x1e c8` audio-shaped stream are now mapped
  in `docs/protocol-reference.md`. Refer there rather than re-deriving from
  the snoop logs.
- three rendering protocols beyond `0x4E` text and BMP are now mapped:
  `0x52` (live streaming text with cursor), `0x0a` (navigation structured
  card with text data slots + optional bitmap chunks), `0x1e` TX (dashboard
  data slot injection), and `0x50` (display mode control). All documented
  in `docs/protocol-reference.md` and `docs/FINDINGS-layouts.md`.

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
