# Worklist history

Archive of completed work from `docs/current-worklist.md`. Items here have been completed and remain in the historical record but are no longer part of the live worklist. Newest first.

The live worklist keeps the most recent ~7 days of completed work for quick "what just shipped" context. Older entries are archived here when that window grows beyond a comfortable size.

Conventions:
- Entries are date-stamped at the title line, matching the format used in the live worklist.
- Where commits are referenced, the SHA is included so git log can be cross-referenced.
- Files-changed lists are preserved verbatim from the worklist at the time of archive.

---

## 2026-05-10 — ble-single-leg-disconnect: Single-leg disconnect robustness

Root cause: only the "both legs down" path triggered auto-reconnect; a single-leg drop was not handled. Fixed across two commits (`2ba1e31` initial fix, `ff20b98` Codex hardening).

**What shipped:**
- Single-leg drop now triggers auto-reconnect (previously a no-op).
- Three Codex-review blockers fixed: false-positive reconnect trigger during initial connect, off-by-one in reconnect counter, `reconnectInFlight` flag left set after a failed attempt.
- 30-second watchdog timer added to recover from a stuck `autoConnect`.
- `forceReconnect()` now resets stale per-leg health state before attempting reconnect.

Files changed: `android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt`, `lib/ble_manager.dart`.

---

## 2026-05-09 — quicknotes-multi-list: QuickNotes multi-list categorisation

Three-category auto-classification via GPT piggyback on tidy step + keyword regex fallback. TabBar UI with move-between-categories picker. Schema migration v1→v2.

---

## 2026-05-08/09 — QuickNote via hosted transcription — v1 pipeline complete

Full right-hold → transcribed local note pipeline shipped across two sessions. All 10 tasks done; Codex peer review passed with 2 blockers fixed (ack on error paths, undo/tidy race documented) and 1 NIT resolved (tidy log tag). Persistence (0x21 baseline on restart) and auto-sync (unknown notes fetched from glasses on first press after launch) added post-review.

**Protocol discoveries:**
- Firmware does NOT stream audio unsolicited — host must send `1e 06 00 <seq> 02 <noteIndex>` to right leg after `0x21` to request the stream.
- `0x21` fires as 42 bytes on this firmware (circular buffer notes-list dump, 4 records); diff-based detection required to identify the just-recorded note.
- LC3 frame size is 200 bytes; BLE chunk payloads are 190 bytes — must concatenate then re-slice, not treat chunk boundaries as frame boundaries.
- Defensive flush on non-`0x1e` packets was too aggressive; removed. Rely on sub-code change + 500 ms watchdog instead.
- Screen-clear after pipeline: `0x50` alone does not blank the display; `0x50 + 0x18` sequence required. (Also fixes the glance-auto-clear-regression that was open at end of 2026-05-08.)
- Seq counter starting at `0x40` works; firmware does not enforce a range.

**What shipped:**
- `QuickNoteAudioBuffer.kt` — native BLE chunk accumulator
- `quick_note_capture_service.dart` — LC3 decode → WAV probe, GO/NO-GO gate PASSED
- `QuickNoteTidyService` — GPT-4.1-mini with 3-pair few-shot prompt, falls back to raw on failure
- Pipeline glue — decode → WAV → OpenAI Whisper STT → `NotesStore.insert(raw)` → async tidy → `NotesStore.updateTranscriptClean`; firmware ack (`04 01`) fires unconditionally (blocker fix); ack now sent after audio received on all paths including errors
- `note.dart` + `notes_store.dart` — sqflite schema with sort_order, status, raw/clean transcript fields; rebalance logic for precision; persisted 0x21 baseline fixes first-note-after-restart bug
- `NotesPage` UI — `ReorderableListView`, swipe-to-delete, status toggle, expand/collapse raw vs clean, empty state; auto-syncs unknown glasses notes on first press after launch
- `HomePage` notes card — active note count

Full protocol detail in `docs/FINDINGS-quicknote.md`.

---

## 2026-05-09 — Glance auto-clear regression — fixed

Root cause: `0x50` clearDisplay alone does not blank the display in all firmware states; the correct sequence is `0x50` followed by `0x18`. The regression surfaced at end of the 2026-05-08 session after the `0x18` → `0x50` migration. Fix confirmed working on device (combo restores auto-clear in Glance mode). Cross-ref `ghost-listening-screen` Done item for the original migration context.

---

## 2026-05-08 — BLE stability — Tier 1: Android native GATT lifecycle fixes

Addressed day-over-day BLE link decay ("works fine until it doesn't") by fixing Android-native GATT lifecycle bugs. Six targeted changes to `BleManager.kt` and `MainActivity.kt`:

- `gatt.close()` now called on disconnect — was leaking `BluetoothGatt` instances, the root cause of the progressive decay symptom.
- `reconnectLeg` switched to `connectGatt(autoConnect=true)` so the OS handles background reconnection when the device returns to range.
- GATT setup operations serialised through callbacks: `onServicesDiscovered` (CCCD write) → `onDescriptorWrite` (MTU request) → `onMtuChanged` (conditional bond + mark ready). Previously pipelined and racing.
- New callbacks added: `onMtuChanged`, `onDescriptorWrite`, `onCharacteristicWrite` (errors-only).
- `createBond()` guarded by `bondState != BOND_BONDED` to prevent duplicate bond attempts.
- `BroadcastReceiver` for `ACTION_BOND_STATE_CHANGED` registered; observes bonding outcome and surfaces `bond_failed` to Flutter.

Files changed: `android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt`, `android/app/src/main/kotlin/com/eddie/evencompanion/MainActivity.kt`.

Tier 2 (heartbeat cadence) and Tier 3 (reconnect tuning, connection priority) followed in later sessions.

---

## 2026-05-07 — App icon: custom adaptive icon

Custom adaptive launcher icon replacing the default Flutter blue-F. Foreground: white open-ring eyeglasses outline (bridge + temples) at 1024×1024 on a transparent PNG (`assets/icon/foreground.png`), generated via `tool/generate_app_icon.dart` (Dart/Skia Canvas + AA, run with `flutter test` — reproducible). Background: `#1F5E54`. `flutter_launcher_icons ^0.14.4` wired in `pubspec.yaml`. Mipmap PNGs and adaptive-icon XML written into `android/app/src/main/res/`. APK built clean.

---

## 2026-05-07 — Home / Settings UI polish — theme, layout, and structural fixes

Six cosmetic and structural issues resolved across Home, Settings, and Chat screens:

- **Theme accent**: replaced mint (`~#7DCFA0`) with `#1F5E54` (deep teal-green, "mallard neck"). Updated `lib/main.dart` ColorScheme — `primary`, `secondary`, `secondaryContainer` and their `on*` counterparts. `FilledButton.tonal` (Force Reconnect) derives from `secondaryContainer` so that override was required. Hard-coded greens swept from `home_page.dart` (mode button), `settings_page.dart` (Switch active thumbs — now theme-driven), and `chat_transcript_page.dart` (user bubbles).
- **Home connecting state — Stop Scan**: link removed; the 15-second `scanTimer` still provides the timeout, so no functionality lost.
- **Home connecting state — status chips**: `LayoutBuilder` forces a 2×2 grid when chip count == 4 (connecting state). Other counts (e.g. connected-state 3+2) continue through `Wrap` unaffected.
- **Home connecting state — pair list row**: `OutlinedButton` (false affordance) replaced with `InkWell` + `Row` — device name as secondary text on the left, "Pair N" action label in primary colour on the right.
- **Home (both states) — duplicate title**: card header dropped; settings cog moved to `AppBar.actions`; card lead content is now the connection status line.
- **Settings notifications page — column headers**: per-row "Now Playing"/"Mute" labels replaced with a single `_buildSwitchColumnHeaders()` widget at section top; `SizedBox(width: 56)` columns align with each row's switches. "Now Playing" abbreviated to "Playing" (would have wrapped to two lines — change confirmed acceptable).

---

## 2026-05-06 — Glance: ongoing call idle surface

When a phone call is active and the Glance carousel display times out, the glasses now show a call HUD rather than going blank. Two lines are shown: `Ongoing call: <name>` and `Call time: M:SS` (switching to `H:MM:SS` once the call exceeds an hour). Duration is computed locally in Dart from the call connect timestamp (`notification.when`, confirmed to be set by Samsung's in-call UI to the answer time — NOT the notification post time) via a 1 Hz `Timer.periodic`. Tilt-up opens the normal notification carousel as before; tilt-down or carousel timeout returns to the call HUD. When the call ends the notification is removed, `clearCall` stops the timer, and the idle surface tears down via `Proto.exit()`. The previously-stub `showIdleSurfaceIfAvailable()` in `GlanceService` is now the live entry point for this path. New `NotificationDisposition.callAbsorbed` added to `notification_policy.dart`; call notifications bypass the existing ongoing-suppressed rule and are excluded from the Glance carousel. Detection: `com.samsung.android.incallui`, `isOngoing == true`, `isCall` getter on `CompanionNotification`. 5 files changed: `notification_policy.dart`, `companion_controller.dart`, `glance_service.dart`, `companion_notification.dart`, Kotlin listener + feed store. Note: superseded later by telephony-driven call handling (2026-05-18).

---

## 2026-05-06 — BLE connection stability and auto-reconnection

Three capabilities implemented across 5 files (`app_settings_store.dart`, `device_status_service.dart`, `ble_manager.dart`, `companion_controller.dart`, `home_page.dart`). (1) Post-disconnect auto-reconnect with exponential backoff: immediate → 30 s → 60 s → 120 s → give up. (2) Cradle-aware smart disconnect: skips reconnect when last persisted wear state was "in cradle" (`F5 08` / `F5 0B`). (3) Auto-connect on app launch using persisted `ble.last_channel_number`. Also fixed a critical bug: `_onGlassesDisconnected()` was dead code — disconnect timer cleanup never ran; fixed via `wasConnected && !isConnected` transition detection in `_applyConnectionPayload()`. New persisted settings: `ble.last_channel_number`, `ble.last_wear_state`. UI shows "Reconnecting..." during backoff attempts.

---

## 2026-05-06 — Glance: tilt-down display stuck bug fixed

The tilt-down handler (case 3, `F5 03`) in `companion_controller.dart` had an early `break` when cancelling a pending tilt-up intent, which skipped calling `GlanceService.startLookDownTimeout()`. If the display was already visible from a previous confirmed intent or notification auto-pop, the clear timer never started and the display stayed on the glasses indefinitely. Fix: `startLookDownTimeout()` is now called unconditionally on every tilt-down in Glance mode. The method's own `if (!_isVisible) return;` guard makes it a safe no-op when the display is not visible. One case block changed; no new fields or methods.

---

## 2026-05-06 — Glance: "Now Playing" media integration

Media notifications from streaming apps are now absorbed into Glance line 1 instead of cycling through the notification carousel. Line 1 shows `12:41  |  100%  |  ▶ Green Day - Dookie` when playback is active; reverts to `12:41  |  100%` when stopped. New `NotificationDisposition.mediaAbsorbed` classification. Two-tier detection: auto-detect (`isMediaStyle && category == transport`) plus per-app "Now Playing" toggle in Settings. Track text truncated with `...` at 43-char display width. DB migrated v1 → v2 (`media_override` column). Settings UI gains two toggles per app: "Now Playing" and "Mute". 6 files changed: `notification_policy.dart`, `notification_settings_store.dart`, `notification_package_preference.dart`, `glance_service.dart`, `companion_controller.dart`, `settings_page.dart`.

---

## 2026-05-04 — Glance: notification display reworked to 3-line format

`lib/services/glance_service.dart` (`_buildDisplayText`). The Glance notification HUD is now a compact 3-line layout: line 1 shows `HH:MM  |  <battery>` (pipe separator between time and battery); line 2 shows `<source>  ·  HH:MM` (mid-dot separator between source and posted time); line 3 is the message content, wrapping naturally via TextService. Earlier in the day the posted time was added as a fourth line; this follow-up merged source and posted time onto one line and dropped the count to three. No model or protocol change — `CompanionNotification.postedAt` was already populated. The "No notifications" idle branch is unchanged. Build green; no new analysis issues.

---

## 2026-05-01 — Authoritative settings reconcile — brightness, auto, head-up, double-tap

Device testing confirmed complete. Settings persist across cold launches; slider loads its last position from `AppSettingsStore` on startup. All four firmware settings (brightness level, auto-brightness, head-up behaviour, double-tap action) re-assert on every BLE reconnect — even when the official Even Realities app has written different values in between.

---

## 2026-05-01 — Brightness readback investigation

Empirical testing pinned `0x29` as the brightness GET path (level only; the wiki's claim that byte 3 carries the auto flag was not reproduced). Identified triggers for `0x6e` (TX `23 74`), `0x3e` (TX `3e`), and `0x2c` (host poll, not unsolicited firmware push). Confirmed the right-temple ambient light sensor location. Confirmed `F5 12` already fires unprompted ~15 s after connect with the current level. Decision: pivot to authoritative settings model rather than firmware readback — companion app re-pushes all four settings on every BLE reconnect (see authoritative settings entry above). Full protocol detail in `docs/FINDINGS-battery+brightness.md`.

---

## 2026-05-01 — Chat `0x52` streaming (Confirmed)

Paced streaming via `StreamingRenderQueue` is fully implemented in Chat. Backend chunks are decoupled from display: the queue drains 2 words every 200 ms (~450 WPM effective with BLE overhead), wraps at 43-char word boundaries, and keeps only the last 3 lines — matching the firmware's 3 visible rows. The firmware does NOT auto-scroll; the host manages scrolling. Line 1 carries a `\n` marker; line 2 carries all visible text. Follow-up turns do `Proto.exit()` only when a prior `0x52` session is active. Full reference detail is in `AGENTS.md` and `docs/FINDINGS-layouts.md`.

---

## 2026-04-13 — glance-heads-up-timings: Adaptive tilt-up intent delay in Glance mode

Idle→active state transition for tilt-up intent delay: full delay from idle, zero delay mid-carousel, delay restored when carousel clears. Shipped in commit `c18ce37`.

**Acceptance checklist:**
- [x] **From idle**: tilt-up retains the existing intent delay before triggering.
- [x] **Mid-carousel**: tilt-up triggers immediately with zero delay.
- [x] **Back to idle**: the full intent delay is restored before the next tilt-up fires.
- [x] No accidental triggers from casual head movements while idle.

*Discovered already shipped during 2026-05-11 backlog review.*
