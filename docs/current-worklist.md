# Current Worklist

This is a short handoff note for new Codex sessions.

Use this with:
- [README.md](/c:/Users/EddieJohnson/projects/EvenDemoApp/README.md)
- [docs/current-behaviour.md](/c:/Users/EddieJohnson/projects/EvenDemoApp/docs/current-behaviour.md)
- [docs/current-architecture.md](/c:/Users/EddieJohnson/projects/EvenDemoApp/docs/current-architecture.md)
- [AGENTS.md](/c:/Users/EddieJohnson/projects/EvenDemoApp/AGENTS.md)

## Current Product State

Working well:
- Glance mode is a real daily-use feature
- Chat mode works end-to-end with OpenAI-backed STT + assistant responses
- Navigate mode works with Google Maps notification-driven BMP cards
- Quick mode switching works from app UI and persistent notification
- Right-hold QuickNote POC exists for idle-only mode switching
- Per-leg BLE health and reconnect logic exists

Working, but still needs real-world observation:
- Navigate left/right BMP synchronisation under stress
- Capture mode stop/save reliability on device
- Protected notification handling for special ongoing items on Samsung/Android variants

## Current Priority Areas

1. Navigate BMP reliability
- True 1bpp BMP generation is confirmed
- Real issue is per-leg transport integrity during bulk BMP send
- Split-eye divergence happens when one leg commits a frame and the other fails CRC
- Navigate scheduler already keeps:
  - one frame in flight per leg
  - one latest pending frame per leg
  - stale pending frames overwritten
- A recovery pass was added:
  - per-leg Navigate transport degraded state
  - out-of-sync detection
  - targeted resync to failed leg
  - modest per-leg pacing/coalescing
- This still needs more device validation

2. Notification quality
- Notification policy now supports:
  - `blocked`
  - `suppressed`
  - `protected`
  - `normal`
- Ongoing notifications are generally not ordinary Glance items
- YouTube / media protection is behaving correctly in recent logs
- pinned/live score notifications now flow through the ordinary Glance queue as `protected`
- Notification Filters UI exists for package suppression
- Runtime Settings UI now owns API key, backend overrides, notification filters, and permission shortcuts

## Recent Confirmed Findings

Battery and wear state:
- HCI snoop of the official Even Realities Android app (firmware 1.6.6)
  resolved the previously-unknown `F5` sub-codes for battery and wear:
  - `F5 06` worn, `F5 08` cradle open, `F5 0B` cradle closed
  - `F5 0A <pct>` glasses battery percentage push
  - `F5 0F <pct>` case (cradle) battery percentage push
- Now ingested by `lib/services/device_status_service.dart`
- Glasses % renders next to the Glance time line; home screen shows
  glasses %, case %, and a `Worn` / `In cradle` pill
- Source data and parser are in `logs/bluetooth/`

Brightness (open follow-up):
- TX `0x01 <level> <auto>` continues to be the brightness command
- The glasses push `F5 12 <level>` whenever the level actually changes,
  giving a confirmation channel
- Sending brightness commands from this app is not yet implemented

Pinned score:
- `com.samsung.android.app.aodservice` is definitely observed
- In probe logs it exposed:
  - `title=Premier League`
  - `channelId=google_sports_nowbar_ongoing_channel`
  - `android.ongoingActivityNoti.secondaryInfo=ambientData:sportsScore:/g/...`
- `com.google.android.googlequicksearchbox` is also observed as a pinned live score source:
  - `channelId=XBLEND_BUBBLE_PERSISTENT_NOTIFICATION`
  - `text=Pinned live score`
  - no usable team/score/status payload was exposed in notification extras
- Live-score as an app-owned feature is parked as unviable for now
- No pinned-score probe logging should remain in the codebase

YouTube / media:
- `com.google.android.youtube` is a real package variant on this phone
- Media notifications can be `MediaStyle` with `category=transport`
- Recent policy logs showed these classifying as `protected`, not `normal`

Navigate:
- Logs captured real per-leg CRC failures and native write anomalies like `writeResult=201`
- Current diagnosis is transport-level BMP commit failure on one leg, not bitmap format error

## Useful Log Filters

Navigate BMP transport:

```powershell
adb logcat -d | Select-String "NavigateBmpTrace|NavigateBmpTraceNative"
```

Navigate bitmap generation check:

```powershell
adb logcat -d | Select-String "Navigate BMP: render complete"
```

Notification classification and routing:

```powershell
adb logcat -d | Select-String "NotificationPolicy:"
```

Google Maps payload dump:

```powershell
adb shell setprop log.tag.MapsNotificationDump DEBUG
adb logcat -d -s MapsNotificationDump
```

## Current Guardrails

Do not casually change:
- trusted gesture meanings in `AGENTS.md`
- Chat mode backend shape unless the task is Chat-specific
- general BLE framing / pairing flow
- Java/Kotlin target versions unless there is an explicit Android toolchain pass

Prefer narrow changes in:
- `lib/services/notification_policy.dart`
- `lib/services/glance_service.dart`
- `lib/services/navigate_service.dart`
- `lib/services/features_services.dart`
- `lib/controllers/bmp_update_manager.dart`

## What To Tell A Fresh Session

Good first prompt pattern:
- say which single area is being worked on now
- mention whether the issue is:
  - notification policy
  - Navigate BMP transport
  - Capture validation
- point the agent to:
  - `AGENTS.md`
  - `README.md`
  - `docs/current-behaviour.md`
  - `docs/current-architecture.md`
  - this file

## Files Most Likely Relevant Next

- [lib/services/notification_policy.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/notification_policy.dart)
- [lib/services/glance_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/glance_service.dart)
- [lib/services/companion_controller.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/companion_controller.dart)
- [lib/services/navigate_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/navigate_service.dart)
- [lib/services/features_services.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/features_services.dart)
- [lib/controllers/bmp_update_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/controllers/bmp_update_manager.dart)
- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)
