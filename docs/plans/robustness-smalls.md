# Robustness smalls: four backlog fixes and the auto-brightness probe

**Status:** DONE - 2026-11-07
**Created:** 2026-11-07   **Last updated:** 2026-11-07   **Completed:** -

## Goal
Close five worklist items in one small PR: `lc3-hot-path-crash`, `notification-listener-rebind`,
`mtu-failure-fallthrough`, `heartbeat-suspend-is-noop` and `auto-brightness-spike`. Verified on
the phone and glasses, with the brightness result recorded in
`docs/FINDINGS-battery+brightness.md`.

## Out of scope
Other robustness items on the worklist; anything needing a firmware change. If the brightness test
confirms firmware behaviour we cannot change, it goes on `firmware-mod-spike` (Parked), not here.

## Inputs and access
- Item bodies: `docs/current-worklist.md` (the five slugs above).
- Code: `android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt`
  (`Cpp.decodeLC3(lc3)!!` in `onCharacteristicChanged`; `onMtuChanged`, which ignores `status`),
  `notifications/RecentNotificationsListenerService.kt` (the `"charging"`/`"battery"` text filter
  in `shouldIgnoreNotification`; no `onListenerDisconnected`), `lib/ble_manager.dart`
  (`suspendHeartbeats`/`resumeHeartbeats`, no callers), `docs/current-architecture.md` (false
  heartbeat-pause claim), `lib/services/notification_policy.dart`.
- Device: S24 Ultra + G1, adb over Tailscale (`100.89.74.113:5555`); debug probe and BLE drop
  recipe in AGENTS.md. Phase 2 needs Eddie wearing the glasses.
- Prior brightness finding: `docs/FINDINGS-battery+brightness.md` (commit 66e6bd9) - firmware
  forces `auto_brightness` to 0 while any `0x4E` text surface is up, restores it on `0x18`.

## Phases

### [x] 1 - Code fixes on `robustness-smalls`
- **Objective:** land the four code fixes as one reviewable branch.
- **Steps:** first commit the uncommitted worklist grooming on `main` (`docs/current-worklist.md`,
  `docs/worklist-history.md`) so the branch starts clean; branch `robustness-smalls` from `main`.
  1. LC3: drop the `!!`; on a null decode, skip the frame and log, matching `decodeLc3Frames`.
  2. Listener: add `onListenerDisconnected` -> `requestRebind(ComponentName(...))`. Replace the
     text filter with a package-based exclusion (system UI / battery / device-care packages),
     chosen from the phone's real recent notifications (`getRecentNotifications` or
     `dumpsys notification`). Never log notification text.
  3. MTU: on a non-success `onMtuChanged`, treat as setup failure: close the leg and go through
     the existing per-leg reconnect (with its backoff), never on to bond/ready.
  4. Heartbeat: delete `suspendHeartbeats`/`resumeHeartbeats` and their depth counter; correct
     `docs/current-architecture.md`.
- **Deliverable:** branch `robustness-smalls` with the fixes, plus a unit test that a messaging
  app notification containing "battery" is not dropped (put the decision somewhere testable).
- **Done when:** `flutter build apk --debug` succeeds, `flutter analyze` shows no new issues
  versus `main`, and all tests pass (the pre-existing `widget_test` failure excepted).
- **Delegate:** `local-dev` for fixes 1 and 4 (mechanical); fixes 2 and 3 inline.

### [x] 2 - Device check, brightness probe, close-out
- **Objective:** prove no regressions on device and settle `auto-brightness-spike`.
- **Steps:** install over Tailscale; Eddie reconnects and wears the glasses.
  1. Capture: a short glasses recording saves and plays.
  2. Glance: a test message containing "battery" from a messaging app appears; a real
     battery/charging system notification stays hidden.
  3. BLE: `cmd bluetooth_manager disable` / `enable`; both legs reconnect cleanly.
  4. Brightness, on the dashboard (no `0x4E` surface up, since the firmware forces auto off
     under text): read state with `3f06` (and `0x29`), then test Eddie's hypothesis - manual
     brightness to 0 before auto-on, versus auto-on with a high manual value - covering the
     sensor each time. Record what the readbacks and the lens do.
- **Deliverable:** result section in `docs/FINDINGS-battery+brightness.md`; the five items moved to
  Recently Done in `docs/current-worklist.md`; PR merged to `main`.
- **Done when:** all four checks recorded, the brightness question answered (or explicitly
  handed to `firmware-mod-spike`), and `main` contains the branch.
- **Delegate:** inline (device back-and-forth).

## Decisions
- 2026-11-07 - Four fixes ship as one PR, not four items - each is small and they share one
  device check.
- 2026-11-07 - Delete the heartbeat suspend rather than wire it - its only use case (the
  108-packet nav replay) is gone, and any write within 30 s keeps the link alive.
- 2026-11-07 - Battery/system exclusion lives in Kotlin `NotificationExclusions` (package-only,
  JVM unit test), not Dart `NotificationPolicy`: `DashboardService` reads the native feed without
  the Dart policy, so filtering at the source covers every path. Packages: `android`,
  `com.android.systemui`, `com.samsung.android.lool`, `com.samsung.android.sm.devicesecurity`.
- 2026-11-07 - MTU failure closes the leg (`closeLegGatt`, flush queue, notify "disconnected");
  the retry is Dart's `_monitorLegHealth` -> `_attemptLegReconnect` with its 2-30 s backoff.
- 2026-11-07 - Auto brightness under `0x4E` text surfaces is a firmware limit; only the
  dashboard-state behaviour is tested here.

- 2026-11-07 - Brightness answered: the manual level is a floor under auto (case A 0 + auto
  ranged 0..12; case B 42 + auto held at 42). Recorded in `FINDINGS-battery+brightness.md`.
  App follow-up (send 0 on auto-on, or relabel the slider) is a separate worklist item.

## Open questions
- The package list was picked from installed packages, not a live card (none were up). Phase 2
  check 2: plug the phone in and confirm the charging card's package is in the list.
- Out of scope, flag only: `CompanionController._logNotificationPolicy` logs notification
  title/text at `info`. Candidate worklist item.

## Progress log
- 2026-11-07 - phase 2 device check - capture saves (first run HUD froze at 00:00: master R stopped acking `0x4E` and `0x25` mid-recording; second run clean, treated as a one-off); Glance shows a "battery" message and hides the charging card; BT off/on reconnects both legs (~22 s, first backoff attempt fires while BT is still off); brightness answered (floor). Seen in passing: red-screen `Cannot get renderObject of inactive element` from `HeroController` on a back press during a route transition (not this branch).
- 2026-11-07 - phase 1 - branch `robustness-smalls` (uncommitted grooming landed on `main` as 6bf2668 first); fix 1 done inline (same file as fix 3), fix 4 via local-dev - `_heartbeatPauseDepth` was never read, so suspend was always a no-op; added junit `testImplementation`; analyze 39 = 39 vs main.
