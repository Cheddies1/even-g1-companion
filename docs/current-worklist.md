# Current Worklist

This is a short handoff note for new Codex sessions.

Use this with:
- [README.md](../README.md)
- [docs/current-behaviour.md](current-behaviour.md)
- [docs/current-architecture.md](current-architecture.md)
- [AGENTS.md](../AGENTS.md)

---

## Product Shape

Four-pillar product model (agreed 2026-05-18):

- **Glance** — ambient awareness. Includes QuickNote. QuickNote is a Glance-mode feature, not its own pillar.
- **QuickAsk / Router** — instant intent execution via the left-hold gesture.
- **Capture** — ambient audio memory (long-form recording).
- **Terminal Mode** — ambient engineering supervision (deferred; see Backlog).

Distinction: QuickNote is "remember something fast" (single note, right-hold). Capture is "record a whole meeting" (long-form, tilt-up). They are separate features with separate gestures and separate storage.

---

## Current Product State

Working well:
- Glance mode is a real daily-use feature
- Chat mode works end-to-end with OpenAI-backed STT + assistant responses, paced `0x52` streaming, host-managed scrolling
- Navigate mode boots and stays alive on the firmware `0x0a` card path (full 108-packet interleaved replay, dynamic TRIP_STATUS, 1-second SYNC poller, post-bootstrap TRIP_STATUS+SYNC updates, idle-prompt suppression)
- Quick mode switching works from app UI and persistent notification
- Right-hold QuickNote: full pipeline live (gesture → LC3 decode → WAV → Whisper STT → GPT-4.1-mini tidy → local notes store → in-app UI)
- Per-leg BLE heartbeat at 2 s cadence, independent per-leg start, parallel sends; reconnect logic exists
- Battery + wear state ingested and displayed (home screen pills, Glance HUD)
- Brightness slider + auto toggle (push side)
- Firmware settings dropdowns (head-up behaviour + double-tap action) on Settings page
- Double-tap mode switch via `F5 20`
- Notification policy (blocked / suppressed / protected / normal), Filters UI, Runtime Settings UI
- Time sync (`0x06 01`): epoch pushed to glasses on connect and every 60 s; drives navigation HUD clock and firmware dashboard
- Call HUD fallback on last-notification dismiss: dismissing the final carousel item mid-call transitions to the call HUD, not blank (`GlanceService.removeNotificationByKey`, v1.0.2+6)
- Telephony-driven call handling: `TelephonyEventService.kt` wires `PhoneStateListener` / `TelephonyCallback` to an `eventTelephony` EventChannel; `GlanceService` shows incoming-call HUD (caller name from notification metadata), active-call HUD with live timer, and auto-clears on idle; call notifications suppressed from carousel when telephony is active; outgoing call detection (IDLE→OFFHOOK) covered (v1.0.2+8)

Working, but still needs real-world observation:
- Navigate mode startup robustness on first entry / degraded-leg recovery
- Navigate mode post-bootstrap update behaviour on longer real walks
- Capture mode stop/save reliability on device — being actively addressed by Capture v2 items in Next (safer stop gesture, HUD probe)
- Protected notification handling for special ongoing items on Samsung/Android variants

---

## Now / In Flight

### 4. Navigate cleanup (composite)
- **Status**: Now
- **Context**: Navigate is functionally working on the `0x0a` structured-card path. Several cleanup tasks remain before it can shed its debug scaffolding. Eddie expects most are straightforward.
- **Acceptance** — all of the following:
  - [ ] **Startup robustness** — keep observing first-entry Navigate starts, especially cases where one leg begins degraded or reconnecting. Idle prompt is now suppressed; verify no regressions.
  - [x] **Field extraction cleanup** — fix `turnDistance` being populated with road text such as `towards Milton Rd` or `Home (36 Campbell Rd)`. Tighten the Google Maps notification parsing model.
  - [ ] **Proper EXIT / ARRIVED handling** — sessions are currently torn down via the existing exit path, but the `0x0a 05` EXIT and `0x0a 06` ARRIVED sub-commands are not used cleanly.
  - [ ] **Replay scaffolding decision** — `lib/services/nav_replay_data.dart` and the debug 108-packet replay path remain in use for PANORAMIC_MAP bootstrap and as MAP_OVERVIEW fallback. Once bootstrap and update behaviour are trusted, decide what to keep, what to relabel as production-fallback, and what to remove. Do NOT remove yet.
  - [x] **Time set (0x06 01)** — periodic epoch-time push from the app to the glasses. The glasses use this for both the navigation HUD clock and the firmware dashboard. Wire format per JohnRThomas wiki: `06 16 00 <seq> 01 <epoch32> <epoch64_ms> <weather_icon> <temp_c> <c_f_flag> <24h_flag> 00`. Start with time-only; weather fields can be zeroed initially.
  - [x] **PANORAMIC_MAP placeholder** — replace the misleading static map capture (488x136) with the smallest viable neutral placeholder image. This is option 2 from the Parked PANORAMIC_MAP decision item. The placeholder should be honest about not being a real map — single-colour fill or minimal grid.
- **Notes**: Cross-ref `docs/FINDINGS-layouts.md`, `lib/services/navigate_service.dart`, `lib/services/nav_icon_generator.dart`. See the related Parked item on PANORAMIC_MAP.

---

## Next — Prioritised

### capture-v2-hud-probe: Capture v2 — HUD render probe (gating spike)
- **Status**: Next
- **Priority**: High
- **Context**: Gating spike for all other Capture v2 work. Confirms whether pushing periodic `0x4E` text-only HUD frames during an active LC3 audio recording disturbs the inbound audio stream or triggers a firmware mode reset. Outcome decides whether HUD updates are continuous (every 5 s) or limited to tilt-up peek as fallback.
- **Timebox**: 1 hour.
- **Method**: Start a recording, push 12 dummy HUD updates spaced 5 s apart over a 60 s capture window. Verify all audio frames arrive and the WAV concatenates cleanly with no gaps or corruption.
- **Acceptance**:
  - [ ] 12 HUD pushes sent during a 60 s LC3 recording session.
  - [ ] Resulting WAV is gapless and intelligible — no corruption from HUD writes.
  - [ ] No firmware mode reset observed during the test window.
  - [ ] Decision recorded: HUD updates are continuous (every 5 s) OR limited to tilt-up peek only.
- **Notes**: If the spike fails (HUD writes corrupt audio), all Capture v2 HUD work becomes a tilt-peek-only approach. Either outcome unblocks Item 2.

### capture-v2-recording-hud: Capture v2 — Recording HUD
- **Status**: Next
- **Priority**: High
- **Blocked on**: `capture-v2-hud-probe` (spike must pass to enable continuous updates).
- **Context**: Replace the static REC indicator with a live HUD that shows recording state, elapsed time, and save confirmation.
- **HUD states** (text-only via `0x4E`, ASCII only — G1 firmware font constraint):

  Idle:
  ```
  Capture ready
  Tilt up to record
  ```

  Recording (updates every 5 s; pulse character cycles `*` → `#` → `.` → repeat):
  ```
  * REC  03:30
  ```

  Save confirmation (auto-clears after 5 s):
  ```
  Saved
  12m 34s - Capture-2026-05-18-14-32.wav
  ```

- **Acceptance**:
  - [ ] Idle state renders on mode entry.
  - [ ] Recording state shows elapsed time updating every 5 s.
  - [ ] Pulse character cycles correctly.
  - [ ] Save confirmation renders for 5 s then clears.
  - [ ] Timer is generated locally in Dart — no dependency on firmware clock.
  - [ ] HUD re-render does not restart or interrupt the capture session.
  - [ ] WAV pipeline unchanged.
- **Notes**: Timer driven by periodic timer in `CaptureService`. No live transcription, no waveform, no VU meter. ASCII-only is a hard constraint — confirmed via G1 firmware font memory.

### capture-v2-safer-stop: Capture v2 — Safer stop gesture
- **Status**: Next
- **Priority**: High
- **Context**: Prevents accidental recording stops from natural head movement (e.g. tilt-up while drinking coffee mid-recording being read as a stop command). Currently, tilt-up while recording stops it — this is the bug to fix.
- **Can ship alongside**: `capture-v2-recording-hud`.
- **Gesture model**:
  - Tilt-up (`F5 02`) starts recording — unchanged.
  - Tilt-up (`F5 02`) while recording is active = no-op.
  - Double-tap (`F5 00`) while recording = stop + save + show save confirmation.
- **Rationale**: Aligns with the global gesture model — double-tap closes the active feature, and recording counts as an active feature.
- **Acceptance**:
  - [ ] Tilt-up while recording active does nothing (no accidental stop).
  - [ ] Double-tap while recording stops, saves, and triggers save confirmation HUD.
  - [ ] `F5 02` (tilt-up) during active recording is consumed as a no-op by Capture mode — does not propagate.
  - [ ] `F5 00` (double-tap) while Capture is active is owned by Capture mode — mode switch path does not steal it.
  - [ ] Existing tilt-up start behaviour unchanged (when not recording).
- **Notes**: Not in scope — tilt-hold, repeated tilt gestures, confirmation prompts. Technical touch points: `CaptureService` gesture handler, gesture routing in `CompanionController`.

### capture-v2-recordings-list: Capture v2 — Recordings list UI
- **Status**: Next
- **Priority**: Medium-high
- **Context**: New in-app screen for browsing and managing recordings. Independent of the HUD/stop items — can be built in parallel. Eddie currently re-listens to recordings to identify them before exporting to his transcription pipeline; on-glasses naming during recording is out of scope here, but rename-on-disk addresses the same pain.
- **Screen position**: Between Notes and Chat history tabs.
- **Acceptance**:
  - [ ] Screen lists all `.wav` files in the capture directory, most recent first.
  - [ ] No database — metadata derived from filename pattern + WAV header (duration).
  - [ ] Clearing the directory clears the list (filesystem reflection, no orphan db rows).
  - [ ] Per row: date/time, duration, filename, rename action, share/export action.
  - [ ] Default filename pattern: `Capture-YYYY-MM-DD-HH-mm.wav`.
  - [ ] Rename action: disk rename replacing the prefix only. Timestamp suffix is preserved. Example: `Capture-2026-05-18-14-32.wav` → `Martin-2026-05-18-14-32.wav`.
  - [ ] No naming prompts during recording flow — rename is post-hoc in the list UI.
- **Notes**: Future anchor for offline Whisper, summaries, rename-last-recording assistant action, export workflows — none of those are in scope here. Cross-ref: `capture-v2-hud-probe` and `capture-v2-safer-stop` work in the service layer; this item is UI only.

### router-v1-glance-handlers: Router v1 — `glance` trigger + Calendar, Notes, Media handlers
- **Status**: Next
- **Priority**: Medium
- **Context**: Turns the left-hold Quick Ask into a deterministic command layer, with LLM as fallback. Introduces a `glance` trigger word that routes to structured handlers before falling through to the existing OpenAI path. Acoustically distinctive; two syllables; no near-homophones. Decided 2026-05-18.
- **Routing model**:
  - Transcript normalised (lowercase, strip punctuation).
  - First token == `glance` → router claims the transcript.
  - Else → existing LLM path unchanged.
  - Router-claimed but no handler matched → fall through to LLM (e.g. `glance recipe for chicken` still works).
- **Architecture**: `QuickAsk transcript → AssistantRouter → CommandHandler → DisplayRenderer`
- **Handler keyword matching** (within router-claimed transcripts):
  - `calendar` / `meeting` / `meetings` / `today's` / `next` → `CalendarHandler`
  - `note` / `notes` / `todo` / `shopping` → `NotesHandler`
  - `playing` / `music` / `track` / `song` → `MediaHandler`
- **CalendarHandler**:
  - Fetch next N events from Android calendar provider.
  - Render (auto-clears after 5 s):
    ```
    15:00 Product Sync
    16:30 Jan 1:1
    ```
  - Requires Android calendar runtime permission — handle first-time permission UX.
- **NotesHandler**:
  - Pull top N active items from existing local SQLite `NotesStore`, grouped by category.
  - Render (auto-clears after 5 s):
    ```
    TODO
    - BP notes
    - Renew cert
    - Email Victor
    ```
- **MediaHandler** (notification-mirror only):
  - Reuse existing media notification state — do not capture live audio.
  - Render current track in full (this can use full text width; glance mode crops by default).
  - Shazam-style live audio fingerprinting is explicitly OUT of scope here — see `router-v1-shazam` in Backlog.
- **Acceptance**:
  - [ ] `glance calendar` (and synonyms) shows next N events from Android calendar.
  - [ ] `glance notes` (and synonyms) shows top N items from `NotesStore`.
  - [ ] `glance music` (and synonyms) shows current media notification state.
  - [ ] `glance <anything unmatched>` falls through to LLM.
  - [ ] Non-`glance` transcripts continue to reach LLM path unchanged.
  - [ ] Calendar permission flow works on first-time use.
  - [ ] All HUD output is ASCII-only, text-only via `0x4E`.
- **Notes**: `MediaHandler` reuses existing notification state — the `now-playing-mediasession` Backlog item (Audible MediaSession metadata fix) is complementary: fixing that would improve what `MediaHandler` can render for Audible and similar apps. Cross-ref that item when implementing. Independent of Capture v2 stream.

### router-v1-chat-logging: Router v1 — Chat history logging (single feed, origin tag)
- **Status**: Next
- **Priority**: Medium
- **Context**: Log both question and response from Quick Ask invocations — both router-claimed and LLM-fallback — into Chat history. Keeps the history complete and searchable. Pair with `router-v1-glance-handlers`.
- **UI model**: Single feed with origin tag — small `Chat` / `Ask` label per entry. Same copy mechanism, format, etc. as existing Chat entries. Decided against sub-tabs to keep unification simple.
- **Acceptance**:
  - [ ] All Quick Ask invocations (router-claimed and LLM-fallback) produce an entry in Chat history.
  - [ ] Entry shows the question and the response.
  - [ ] Origin tag (`Chat` / `Ask`) is visible per entry.
  - [ ] Existing Chat entries unaffected.
- **Notes**: Rationale for single-feed approach: avoids splitting history into sub-tabs while preserving the distinction between conversational Chat turns and intent-driven Ask turns. Pair with `router-v1-glance-handlers`.

### quicknote-classifier-tuning: Keyword fallback too broad on "to do" phrases
- **Status**: Next
- **Priority**: Low
- **Context**: The keyword classifier fires on "to do" broadly, so phrases like "make a note to X" get tagged as todo before GPT runs. GPT classification is generally correct; the keyword fallback (which sets the initial category) catches too widely.
- **Acceptance**:
  - [ ] Either tighten keyword patterns to exclude constructions like "make a note to …" from the todo trigger, or suppress the keyword-derived category until GPT confirms/overrides it.
  - [ ] "Make a note to X" phrases consistently land in the Notes category, not Todo.
  - [ ] Existing unambiguous todo phrases ("remind me to", "I need to") still classified correctly.
- **Notes**: Polish item — the feature works well overall. No protocol changes; purely a classifier adjustment in the categorisation logic. Needs more variety of note types tested before acting on this. Not ready yet.

---

## Backlog — Unprioritised

### router-v1-shazam: Router v1 — Shazam-style "what song is this"
- **Status**: Backlog
- **Priority**: Low
- **Context**: Live audio fingerprinting to identify songs playing in the environment. Acoustically separate from the notification-mirror `MediaHandler` in `router-v1-glance-handlers` — this requires capturing audio from the mic, calling a fingerprinting API (ShazamKit / ACRCloud / AudD), and handling a longer wait + possible failure mode. Different scope, cost, and UX from the rest of Router v1. Deliberately decoupled.
- **Acceptance**: `glance what song is this` (or similar) captures ambient audio, calls fingerprinting API, and renders track name + artist on the glasses.
- **Notes**: API budget and latency considerations need evaluating before implementation. Do not bundle with `router-v1-glance-handlers`.

### terminal-mode-crypto-spike: Terminal Mode — Happy crypto spike (gating spike, deferred)
- **Status**: Backlog
- **Priority**: Low
- **Context**: Gating spike for Terminal Mode v1. Deferred — Happy integration is larger than initially scoped. Eddie has decided not to undertake Terminal Mode immediately. Keep on the backlog so it is not lost.
- **Timebox**: 1 day.
- **Spike tasks**:
  - Implement libsodium NaCl `secretbox` + AES-256-GCM decryption in Dart using `cryptography` or `flutter_sodium`.
  - Verify against known test vectors from Happy's reference implementation at `packages/happy-cli/src/api/encryption.ts`.
  - Confirm Socket.IO Dart client connects to `wss://api.happy.engineering/v1/updates` with bearer-token auth.
- **Acceptance**: Dart crypto path verified against reference test vectors. Socket.IO connection to Happy's endpoint established.
- **Notes**: If spike succeeds → proceed to `terminal-mode-v1`. If not → re-evaluate Terminal Mode viability. Protocol reference: https://happy.engineering/docs/ and the `slopus/happy` GitHub repo `docs/` folder (`protocol.md`, `session-protocol.md`, `encryption.md`, `api.md`). The marketing site does not document the protocol — GitHub is canonical.

### terminal-mode-v1: Terminal Mode v1 (deferred — depends on terminal-mode-crypto-spike)
- **Status**: Backlog
- **Priority**: Low
- **Context**: Replace the underused Chat mode with an ambient engineering supervision surface. Slot 4 becomes a settings toggle between "Chat" and "Code" — Chat is preserved, not removed. Deferred behind Capture v2 and Router v1. Estimated scope: 1–2 weeks for the protocol layer alone, before any rendering work.
- **Integration**: Happy direct subscription — companion app pairs as a first-class Happy client (own keypair, QR-pair with mobile app), subscribes to Socket.IO `/v1/updates` (session-scoped or user-scoped).
- **Event mapping to glasses display**:
  - `text` (non-thinking) → streamed update via existing `0x52` paced queue.
  - `tool-call-start` → short progress line (e.g. "Running tests…", "Edited 3 files").
  - `turn-end` with `status=completed` and no follow-up → "Claude waiting".
  - `ephemeral activity { thinking: true }` → thinking indicator.
- **Reply path** (v1.1, explicitly deferred): tilt-up while "waiting" → STT → emit `message` event back via the same socket.
- **Acceptance**: Not defined until crypto spike is complete and Terminal Mode is promoted out of Backlog.
- **Notes**: Constraints — short bursts only; do NOT stream raw token output continuously; surface transitions, not raw stream. Reuse existing `0x52` streaming renderer + paced queue infrastructure. Depends on `terminal-mode-crypto-spike` passing. Protocol refs above also apply here.

### dashboard-injection: Dashboard content injection
- **Status**: Backlog
- **Priority**: Low
- **Context**: `0x1e` TX can push titled content into the firmware's dashboard grid layout — useful for summaries, reminders, or status info.
- **Acceptance**: Demonstrable injection of titled content into a dashboard slot, with a real use case identified.
- **Notes**: Eddie's view: "Probably less useful than QuickNote unless you have a clear use case." Open question: what would actually go in the slot? Demoted from Next — lacks a concrete use case. Revisit when a clear scenario emerges.

### quicknote-dashboard-push: QuickNote v2 — push transcribed note to glasses dashboard via 0x1e TX
- **Status**: Backlog
- **Priority**: Low
- **Context**: QuickNote v1 ends at "transcribed note saved to phone app". The natural v2 follow-on is pushing that note text back to the glasses firmware dashboard using the `0x1e` TX opcode. Surfaced during v1 planning (2026-05-08) and captured immediately to avoid losing the protocol shape while it is fresh. Deliberately deferred — v1 scope is kept tight.
- **Protocol**: `1e <len> 00 <seq> 03 01 00 01 00 <slot> 01 <title_len> <title> <body_len> 00 <body>`. Full field breakdown at `docs/protocol-reference.md` L444-462.
- **Acceptance**: A completed QuickNote transcription is pushed to a named dashboard slot and readable on the glasses within a few seconds of the right-hold gesture completing.
- **Notes**: Depends on QuickNote v1 (shipped 2026-05-09 — see Recently Done) being stable in the field. Cross-ref `dashboard-injection` (general `0x1e` injection backlog item) — this is the concrete use case that item was waiting for.

### now-playing-mediasession: Now Playing: extract MediaSession metadata for apps with empty notification fields
- **Status**: Backlog
- **Priority**: Unprioritised
- **Context**: Some media apps (confirmed: Audible / `com.audible.application`) send `MediaStyle` notifications with `category=transport` but leave all content fields (`title`, `text`, `subText`) as empty strings. The actual track/chapter/artist metadata lives in the `MediaSession.metadata` object, not in the notification's `extras` bundle. `RecentNotificationsListenerService.kt` only extracts standard notification text fields — it does not read `MediaSession` metadata.
- **Evidence (2026-05-06 logs)**:
  - Flutter side: `title="" text="" subText="" category=transport media=true template="android.app.Notification$MediaStyle"` — all content fields empty
  - System UI side: `metaData=The Wee Free Men, Chapter 7: First Sight and Second Thoughts, Terry Pratchett` — full metadata available in the `MediaSession`
- **Proposed fix**: Enhance `RecentNotificationsListenerService.kt` to detect `MediaStyle` notifications and, when standard title/text fields are empty, fall back to extracting `MediaMetadata.METADATA_KEY_TITLE` and `MediaMetadata.METADATA_KEY_ARTIST` from the notification's associated `MediaSession`. The `MediaSession.Token` is available in notification extras under `android.mediaSession`.
- **Acceptance**: Audible (and similarly-behaving apps) produce a non-empty title/text pair that the Now Playing feature can display on the glasses. Apps that already populate standard notification fields (Spotify, YouTube Music, Podcast Addict) are unaffected.
- **Notes**: Low urgency — the feature works correctly for the three most common music/podcast apps. Audible is the only confirmed failure case. Cross-ref `router-v1-glance-handlers` — fixing this would improve what the Router v1 `MediaHandler` can render for Audible and similar apps.

#### BLE stability — deferred tiers

### ble-stability-tier3: Reconnect tuning and connection priority
- **Status**: Backlog
- **Priority**: Low
- **Context**: Tier 3 of the BLE stability plan. Current auto-reconnect schedule `[0, 30, 60, 120]` gives up at ~3.5 minutes — a UX cliff for overnight or "glasses in pocket" scenarios. Also covers per-session connection priority management and tightening degraded-leg detection once Tier 2's 2 s cadence is in place.
- **Acceptance**:
  - [ ] Auto-reconnect schedule widened to an exponential-like curve with a long-tail floor that never permanently gives up while the foreground service is alive.
  - [ ] Degraded-leg detection thresholds tightened: warning age 20 s → 6 s, consecutive-miss threshold 2 → 3 (only safe once Tier 2's 2 s cadence is confirmed stable).
  - [ ] `requestConnectionPriority(HIGH)` added during nav-card replay and `0x52` streaming sessions; returns to `BALANCED` when done.
- **Notes**: Much less urgent now that tier-2 heartbeats have significantly improved stability. Touches `lib/ble_manager.dart` (Flutter side) and `BleManager.kt` (native side for connection priority). Depends on Tier 2 being in place before adjusting detection thresholds.

#### Protocol research and hardening

### protocol-0x22: Reverse-engineer 0x22 dashboard/status family
- **Status**: Backlog
- **Priority**: High
- **Context**: `0x22` is known to exist and appears tied to dashboard state. Payload semantics remain mostly unresolved — a protocol blind spot.
- **Acceptance**: Field structure decoded. Payloads correlated against dashboard visibility, pagination, unread counts, widget selection, notification state. Determination made on whether `0x22` supports firmware UI awareness, dashboard sync, or richer glance integration.
- **Notes**: Understanding firmware-side dashboard state may reduce future UI conflicts and reduce the need for speculative sequencing hacks.

### navigate-cleanup: Navigation protocol cleanup and de-replay work
- **Status**: Backlog
- **Priority**: Medium
- **Context**: `0x0a` navigation path works but remains partially dependent on replay-derived scaffolding and captured assets. Navigate is operational but not yet fully "owned" at the protocol level.
- **Acceptance**: Remaining captured/replayed dependencies removed. Static PANORAMIC_MAP replaced with a generated or optional implementation. Startup robustness, reconnect behaviour, exit semantics, and route update handling improved. Icon generation, card generation, and lifecycle fully owned.
- **Notes**: The PANORAMIC_MAP sub-issue may remain Parked even while other parts of this item progress. Cross-ref the Parked `PANORAMIC_MAP decision` item, and the existing Now item `Navigate cleanup (composite)` — that covers immediate tactical fixes (turnDistance, EXIT/ARRIVED); this item covers broader protocol ownership and de-replay work.

### protocol-audit: Protocol confidence audit
- **Status**: Backlog
- **Priority**: Low
- **Context**: Some protocol sections are marked "Confirmed" based on behavioural success rather than structural certainty. Accidental overconfidence in docs risks future architectural mistakes built on assumptions that merely "worked once".
- **Acceptance**: All confidence labels in `docs/protocol-reference.md` and `docs/even-g1-event-mapping.md` reviewed. Observed behaviour, inferred semantics, and protocol certainty cleanly separated. Overconfident labels corrected.

### docs-hardening: Documentation structure hardening
- **Status**: Backlog
- **Priority**: Low
- **Context**: Protocol truth, implementation choices, and hypotheses are partially intermixed across the documentation. The docs are now substantial enough to act as a real protocol reference, and structural clarity matters more as the corpus grows.
- **Acceptance**: Protocol-level truth, observed behaviour, firmware hypotheses, and app implementation choices cleanly separated across the doc set. Docs are suitable as: a public reverse-engineering reference, a future SDK basis, and contributor onboarding material.
- **Notes**: Documentation meta-task, not a code task. Likely involves `docs/protocol-reference.md`, `docs/even-g1-event-mapping.md`, `docs/current-architecture.md`, `docs/current-behaviour.md`, and the FINDINGS files.

---

## Parked

### PANORAMIC_MAP decision
- **Status**: Parked — decision pending
- **Context**: The 488×136 PANORAMIC_MAP region is shown in the glasses' "look up" mode and is a large piece of screen real estate. Currently the app sends a static capture taken from the official app during a previous route — meaning it looks like a map and feels like a map but is NOT active to the user's actual location. Eddie considers this misleading.
- **Why parked**: Eddie cannot currently think of anything genuinely useful to do with it. The ideal would be a real-time map of the user's current surroundings (a few hundred metres around current location, NOT tied to the active route) rendered as a line drawing — but that requires maps-service integration, current-location handling, and an image pipeline to render the map as 488×136 monochrome. Eddie's words: "feels like a big lift for a nice-to-have".
- **Three options on the table**:
  1. Keep static forever (current behaviour — but misleading)
  2. Generate a neutral placeholder (decorative, honest about not being a map)
  3. Build the real local-surroundings line-drawing path (significant lift, maps-service dependency)
- **Constraint**: Do NOT attempt to render the user's actual route geometry — Google Maps notifications do not expose the geometry, and that path is described as "tiny cartography hell".
- **Cross-ref**: Option 2 (neutral placeholder) is being actioned as part of the Navigate cleanup composite (Now #4). This item remains Parked for option 3 only — the "real map" path. If the placeholder lands cleanly in the Navigate cleanup session, this item can be narrowed to option 3 exclusively.
- **Revival trigger**: Revisit option 3 if a clear use case emerges, or if the placeholder proves insufficient.

---

## Recently Done

### quicknote-polish: QuickNote diagnostic log revert (2026-05-18, commit e1182dd)
Diagnostic log promotions from QuickNote v1 development reverted: `BleRx`, `R21Probe`, and `QuickNoteProbe` info promotions reverted to `AppLog.debug`; capture service probe/decode/tidy logs demoted; class doc updated.

### call-state-telephony-upgrade + incoming-call-hud: Telephony-driven call handling (2026-05-18, commit dc9d959, v1.1.0+9)
Full call-lifecycle coverage on the glasses, sourced from `TelephonyManager` rather than the notification listener. **Device-verified 2026-05-18** — incoming call displayed correctly on glasses, caller name resolved, timer ticked, auto-cleared on hang-up.

- `READ_PHONE_STATE` permission added to `AndroidManifest.xml` with runtime request flow.
- `TelephonyEventService.kt`: dual-path implementation — `PhoneStateListener` (pre-API 31) and `TelephonyCallback` (API 31+). Publishes `RINGING` / `OFFHOOK` / `IDLE` states to Dart via a new `eventTelephony` `EventChannel`.
- `GlanceService`: incoming-ring path shows `"Incoming Call\n<caller name>"` on the glasses immediately on `RINGING`; active-call HUD with live timer on `OFFHOOK`; display clears automatically on `IDLE`.
- Caller identity sourced from notification metadata (the `com.samsung.android.incallui` notification carries the caller name) — `READ_CONTACTS` was deliberately not added.
- Call notifications suppressed from the Glance carousel while telephony is active (identity fed from notification metadata to the telephony-driven HUD).
- Outgoing call detection: `IDLE→OFFHOOK` without a preceding `RINGING` is treated as an outgoing call.
- Notification-based detection retained as fallback for the permission-denied case.

Files changed: `AndroidManifest.xml`, `TelephonyEventService.kt` (new), `lib/services/glance_service.dart`, `lib/services/companion_controller.dart`, `pubspec.yaml`.

### call-idle-dismiss-fallback: Call HUD restored when last carousel notification dismissed (2026-05-18, commit d4f0f0e, v1.0.2+6)
`GlanceService.removeNotificationByKey()` now checks `_currentCall != null` before calling `Proto.exit()`; when the last carousel notification is dismissed during an active call it transitions to the call HUD instead of clearing the display. No protocol changes — targeted fix to the notification-removal logic only.

Files changed: `lib/services/glance_service.dart`.

### ble-stability-tier2: Heartbeat cadence shifted to first-connect rate, faster than official app steady state (2026-05-18, commit 280bb32)
Tier 2 of the three-tier BLE stability plan. Closed four cadence-related divergences identified in HCI capture analysis. **Note (2026-05-18): rationale clarified after re-examining the full HCI log set across multiple capture sessions — see "Heartbeat regime split" below.**

- **Cadence**: reduced from 8 s to 2 s per leg.
- **Parallelism**: heartbeats now sent to both legs in parallel, not sequentially.
- **Per-leg start**: heartbeat starts on individual leg connect rather than being gated on "both connected" — half-connections now receive keepalives.
- **Nav-replay pause removed**: heartbeat continues during nav-replay.

**Heartbeat regime split — what the HCI logs actually show:**

Cross-log analysis (`logs/bluetooth/heartbeat_cadence.py`, `heartbeat_timeline.py`) across four official-app HCI captures revealed two distinct heartbeat regimes in the official app, not one:

- **First-connect / pairing window (~first ~60 s after fresh pair):** opcode `0x1f` at 2 s cadence, with rotating sub-types (`0x12`, `0x01`, `0x0c`) and an incrementing counter. Only observed in the `btsnoop_hci_baseline.log` capture (which spans 11:04:39–11:05:32 — exactly the just-paired window). Zero `0x25` writes in this capture. p50 = 1992 ms, p95 = 2023 ms.
- **Steady state (minutes-to-hours into an established session):** opcode `0x25` at 8 s cadence. Observed in `btsnoop_hci_settings.log` (24 min, 364 heartbeats) and `btsnoop_hci_taps.log` (34 min, 508 heartbeats). Both contain zero `0x1f` writes. p50 = 8000 ms across both.

**The original commit message rationale ("matching official app p50 = 1.98 s") read only the baseline capture in isolation and conflated the pairing-window cadence with the steady-state cadence.** The official app's steady-state heartbeat is `0x25` at 8 s — which is exactly what the EvenDemoApp had before the tweak.

**Why this change still stands:** the permanent 2 s cadence is **faster than the official app's steady state, by design.** Eddie observed noticeably better single-leg reconnect stability at 2 s. Plausible mechanism: single-leg recovery looks like a fresh-pair event from the firmware's perspective, and benefits from the same fast-ping cadence the official app uses during pairing. The degrade threshold was widened from 2 missed pings to 8 to keep the overall miss-window at ~16 s, so detection latency on full-leg-loss is unchanged. Battery cost has been a non-issue in practice (88% at 15:22 after all-day wear, reported 2026-05-18).

**Opcode decision (unchanged):** retained `0x25` rather than switching to `0x1f`. The `0x1f` ACK format (`04 01` responses?) is unverified on-device; `0x25` continues to function. Switching is low-risk but deferred. Note that running `0x25` at 2 s is a combination that the official app does not use — official app uses `0x1f`@2s OR `0x25`@8s, never `0x25`@2s.

Files changed: `lib/services/proto.dart`, `lib/ble_manager.dart`. Analysis tooling: `logs/bluetooth/heartbeat_cadence.py`, `logs/bluetooth/heartbeat_timeline.py`.

### mode-title-cards: Glance and Navigate mode entry title cards, plus Connected/Reconnected clear (2026-05-13, v1.0.2+3)
All three sub-items field-verified on device by Eddie.

- **Glance title card**: flashes "Glance" for ~500 ms on mode entry, then clears. Confirmed not intrusive.
- **Navigate title card**: flashes "Navigate" for ~500 ms on mode entry, **only when no active nav instruction is held** (`!NavigateService.hasInstruction`). The hard constraint (Navigate card mid-bootstrap cancels session) was respected by awaiting the flash inside `_restoreModeEntryState`, so the trailing `0x50+0x18` clear cannot land mid-bootstrap from a concurrent Maps notification handler.
- **Connected/Reconnected force-clear**: replaces the previous "resync visible content" semantics in `CompanionController.handleTransportRecovered`. On any real reconnect (skipped on the very first connect of the session, gated by new `_hasEverConnectedThisSession` flag), the path flashes "Reconnected" for ~1 s, force-clears via the `0x50 + 0x18` combo, then conditionally resumes: REC if recording active, nav refresh if nav visible+hasInstruction, call HUD if active call, otherwise blank. Old `resendLastText`/`resendLastBmpData` calls dropped by design — stale glance content is wrong because the glasses' display state after a disconnect is unknown. Field test confirmed: Glance notification visible + Bluetooth off/on → "Reconnected" flashed and screen actually cleared (the motivating stuck-screen bug).

**What shipped:**
- New `Proto.showTitleCard(text, {duration})` helper — sends text via `0x4E`, holds, then `0x50+0x18` clear.
- New `GlanceService.handleTransportLost()` — resets `_isVisible`/`_isIdleSurfaceActive`/timers; wired into both drop paths in `BleManager` (`_onGlassesDisconnected` and the `anyLegDropped` block in `_applyConnectionPayload`). Without this, post-reconnect notifications would not auto-pop because `_isVisible` survived the drop.
- `CompanionController.handleTransportRecovered` rewritten with first-connect-this-session suppression and QuickNote-capture guard.

Files changed: `lib/services/proto.dart`, `lib/services/companion_controller.dart`, `lib/services/glance_service.dart`, `lib/ble_manager.dart`, `pubspec.yaml`.

### ble-mic-on-reconnect-ghost: "Mic start failed" ghost notification on single-leg reconnect (2026-05-13)
Field-verified absent on v1.0.1+2. Not seen since the fix was installed. Three interacting causes addressed: (1) voice guard armed too late on `onServicesDiscovered` — fixed by arming before any F5 events from the newly-up leg can land; (2) stale `_isListening`/`_isThinking`/`_isRecording` flags blocking `_scheduleClear` — cleared by new flag-only `handleTransportLost()` called from both full-drop and single-leg-drop paths; (3) missing voice guard coverage on `_handleChatGesture` case 2 and `_handleCaptureGesture` case 2. Committed in `4b0fc3f` ("Connectivity fix, Mic Start Failed bug"). Flag-only teardown via `handleTransportLost()` confirmed as the correct long-term approach — no IO/non-IO split of `reset()` needed (see `glance-assistant-reset-on-reconnect`, also closed 2026-05-13).

Files changed: `lib/ble_manager.dart`, `lib/services/glance_assistant_service.dart`, `lib/services/chat_service.dart`, `lib/services/capture_service.dart`.

### ble-reconnect-pacing: BLE reconnect storm — per-leg cooldown and exponential backoff (2026-05-13)
Field-verified on v1.0.1+2. Consistent reconnects observed after single-leg drops; no `GATT_NO_RESOURCES` storm (previously 4488 per ~120 s) and app log lines remain readable in logcat. Root cause was an unpaced `STATE_DISCONNECTED → _attemptLegReconnect → connectGatt` loop amplified by bare `connected=true` resets every 6 ms. Fix: per-leg cooldown gate via `_lastReconnectAttemptAt` map, exponential backoff 2/4/8/16/30 s, and counter reset moved to `_recordLegAck`/`_recordHeartbeatSuccess` only (proof of end-to-end link). Committed in `4b0fc3f` ("Connectivity fix, Mic Start Failed bug"). Kotlin in-flight guard refinement deliberately deferred — see `ble-fast-flap-investigation` in Backlog.

Files changed: `lib/ble_manager.dart`.

### glance-heads-up-timings: Adaptive tilt-up intent delay in Glance mode (2026-04-13)
Idle→active state transition for tilt-up intent delay: full delay from idle, zero delay mid-carousel, delay restored when carousel clears. Shipped in commit `c18ce37`.

**Acceptance checklist:**
- [x] **From idle**: tilt-up retains the existing intent delay before triggering.
- [x] **Mid-carousel**: tilt-up triggers immediately with zero delay.
- [x] **Back to idle**: the full intent delay is restored before the next tilt-up fires.
- [x] No accidental triggers from casual head movements while idle.

*Discovered already shipped during 2026-05-11 backlog review.*

### package-rename: Package rename com.example.demo_ai_even → com.eddie.evencompanion (2026-05-11)
Full cross-language rename across Android + Dart. 13 Kotlin files moved (`git mv`) and package/import declarations updated; JNI C++ symbol names in `liblc3.cpp` updated (4 functions); `build.gradle` `applicationId` + `namespace` updated; `pubspec.yaml` `name:` updated to `even_companion`; 45 Dart files updated from `package:demo_ai_even/` to `package:even_companion/`; docs updated. No `com.example` strings remain in source, config, or docs.

**Acceptance checklist:**
- [x] `applicationId` and `namespace` are `com.eddie.evencompanion` in `build.gradle`.
- [x] All Kotlin files carry `package com.eddie.evencompanion[.subpackage]`; no `com.example` strings remain in source or config.
- [x] JNI C++ symbol names updated (`Java_com_eddie_evencompanion_cpp_Cpp_*`).
- [x] `pubspec.yaml` `name: even_companion`; all Dart imports use `package:even_companion/`.
- [x] Doc file-path references updated in `current-architecture.md`, `current-worklist.md`, `protocol-reference.md`.
- [x] App installs and runs on device after manual uninstall of the old package.
- [x] All BLE functionality works post-reinstall (re-pairing may be required and is accepted).

Files changed: `android/app/build.gradle`, `android/app/src/main/cpp/liblc3.cpp`, 13 Kotlin files (moved + updated), `pubspec.yaml`, 45 Dart files, 3 doc files.

### ble-single-leg-disconnect: Single-leg disconnect robustness (2026-05-10)
Root cause: only the "both legs down" path triggered auto-reconnect; a single-leg drop was not handled. Fixed across two commits (`2ba1e31` initial fix, `ff20b98` Codex hardening).

**What shipped:**
- Single-leg drop now triggers auto-reconnect (previously a no-op).
- Three Codex-review blockers fixed: false-positive reconnect trigger during initial connect, off-by-one in reconnect counter, `reconnectInFlight` flag left set after a failed attempt.
- 30-second watchdog timer added to recover from a stuck `autoConnect`.
- `forceReconnect()` now resets stale per-leg health state before attempting reconnect.

Files changed: `android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt`, `lib/ble_manager.dart`.

### quicknotes-multi-list: QuickNotes multi-list categorisation (2026-05-09)
Three-category auto-classification via GPT piggyback on tidy step + keyword regex fallback. TabBar UI with move-between-categories picker. Schema migration v1→v2.

### QuickNote via hosted transcription — v1 pipeline complete (2026-05-08/09)
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

**Polish remaining**: diagnostic log revert — tracked as Next #4.

Full protocol detail in `docs/FINDINGS-quicknote.md`.

### Glance auto-clear regression — fixed (2026-05-09)
Root cause: `0x50` clearDisplay alone does not blank the display in all firmware states; the correct sequence is `0x50` followed by `0x18`. The regression surfaced at end of the 2026-05-08 session after the `0x18` → `0x50` migration. Fix confirmed working on device (combo restores auto-clear in Glance mode). Cross-ref `ghost-listening-screen` Done item for the original migration context.

### BLE stability — Tier 1: Android native GATT lifecycle fixes (2026-05-08)
Addressed day-over-day BLE link decay ("works fine until it doesn't") by fixing Android-native GATT lifecycle bugs. Six targeted changes to `BleManager.kt` and `MainActivity.kt`:

- `gatt.close()` now called on disconnect — was leaking `BluetoothGatt` instances, the root cause of the progressive decay symptom.
- `reconnectLeg` switched to `connectGatt(autoConnect=true)` so the OS handles background reconnection when the device returns to range.
- GATT setup operations serialised through callbacks: `onServicesDiscovered` (CCCD write) → `onDescriptorWrite` (MTU request) → `onMtuChanged` (conditional bond + mark ready). Previously pipelined and racing.
- New callbacks added: `onMtuChanged`, `onDescriptorWrite`, `onCharacteristicWrite` (errors-only).
- `createBond()` guarded by `bondState != BOND_BONDED` to prevent duplicate bond attempts.
- `BroadcastReceiver` for `ACTION_BOND_STATE_CHANGED` registered; observes bonding outcome and surfaces `bond_failed` to Flutter.

Files changed: `android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt`, `android/app/src/main/kotlin/com/eddie/evencompanion/MainActivity.kt`.

**Build clean. Awaiting on-device validation** — this entry will be updated once hardware testing is confirmed.

Tier 2 (heartbeat cadence) and Tier 3 (reconnect tuning, connection priority) are deferred — tracked in Backlog below.

### App icon — custom adaptive icon (2026-05-07)
Custom adaptive launcher icon replacing the default Flutter blue-F. Foreground: white open-ring eyeglasses outline (bridge + temples) at 1024×1024 on a transparent PNG (`assets/icon/foreground.png`), generated via `tool/generate_app_icon.dart` (Dart/Skia Canvas + AA, run with `flutter test` — reproducible). Background: `#1F5E54`. `flutter_launcher_icons ^0.14.4` wired in `pubspec.yaml`. Mipmap PNGs and adaptive-icon XML written into `android/app/src/main/res/`. APK built clean.

### Home / Settings UI polish — theme, layout, and structural fixes (2026-05-07)
Six cosmetic and structural issues resolved across Home, Settings, and Chat screens:

- **Theme accent**: replaced mint (`~#7DCFA0`) with `#1F5E54` (deep teal-green, "mallard neck"). Updated `lib/main.dart` ColorScheme — `primary`, `secondary`, `secondaryContainer` and their `on*` counterparts. `FilledButton.tonal` (Force Reconnect) derives from `secondaryContainer` so that override was required. Hard-coded greens swept from `home_page.dart` (mode button), `settings_page.dart` (Switch active thumbs — now theme-driven), and `chat_transcript_page.dart` (user bubbles).
- **Home connecting state — Stop Scan**: link removed; the 15-second `scanTimer` still provides the timeout, so no functionality lost.
- **Home connecting state — status chips**: `LayoutBuilder` forces a 2×2 grid when chip count == 4 (connecting state). Other counts (e.g. connected-state 3+2) continue through `Wrap` unaffected.
- **Home connecting state — pair list row**: `OutlinedButton` (false affordance) replaced with `InkWell` + `Row` — device name as secondary text on the left, "Pair N" action label in primary colour on the right.
- **Home (both states) — duplicate title**: card header dropped; settings cog moved to `AppBar.actions`; card lead content is now the connection status line.
- **Settings notifications page — column headers**: per-row "Now Playing"/"Mute" labels replaced with a single `_buildSwitchColumnHeaders()` widget at section top; `SizedBox(width: 56)` columns align with each row's switches. "Now Playing" abbreviated to "Playing" (would have wrapped to two lines — change confirmed acceptable).

### Glance: ongoing call idle surface (2026-05-06)
When a phone call is active and the Glance carousel display times out, the glasses now show a call HUD rather than going blank. Two lines are shown: `Ongoing call: <name>` and `Call time: M:SS` (switching to `H:MM:SS` once the call exceeds an hour). Duration is computed locally in Dart from the call connect timestamp (`notification.when`, confirmed to be set by Samsung's in-call UI to the answer time — NOT the notification post time) via a 1 Hz `Timer.periodic`. Tilt-up opens the normal notification carousel as before; tilt-down or carousel timeout returns to the call HUD. When the call ends the notification is removed, `clearCall` stops the timer, and the idle surface tears down via `Proto.exit()`. The previously-stub `showIdleSurfaceIfAvailable()` in `GlanceService` is now the live entry point for this path. New `NotificationDisposition.callAbsorbed` added to `notification_policy.dart`; call notifications bypass the existing ongoing-suppressed rule and are excluded from the Glance carousel. Detection: `com.samsung.android.incallui`, `isOngoing == true`, `isCall` getter on `CompanionNotification`. 5 files changed: `notification_policy.dart`, `companion_controller.dart`, `glance_service.dart`, `companion_notification.dart`, Kotlin listener + feed store. Known gap: if the user dismisses the last carousel notification mid-call, `removeNotificationByKey` still calls `Proto.exit()` rather than falling back to the HUD — tracked in Backlog (`call-idle-dismiss-fallback`).

**Pending on-device verification:** caller name displays correctly, duration ticks at 1 Hz, tilt-up returns to carousel, tilt-down/timeout returns to HUD, call-end clears the HUD.

### BLE connection stability and auto-reconnection (2026-05-06)
Three capabilities implemented across 5 files (`app_settings_store.dart`, `device_status_service.dart`, `ble_manager.dart`, `companion_controller.dart`, `home_page.dart`). (1) Post-disconnect auto-reconnect with exponential backoff: immediate → 30 s → 60 s → 120 s → give up. (2) Cradle-aware smart disconnect: skips reconnect when last persisted wear state was "in cradle" (`F5 08` / `F5 0B`). (3) Auto-connect on app launch using persisted `ble.last_channel_number`. Also fixed a critical bug: `_onGlassesDisconnected()` was dead code — disconnect timer cleanup never ran; fixed via `wasConnected && !isConnected` transition detection in `_applyConnectionPayload()`. New persisted settings: `ble.last_channel_number`, `ble.last_wear_state`. UI shows "Reconnecting..." during backoff attempts.

### Glance: tilt-down display stuck bug fixed (2026-05-06)
The tilt-down handler (case 3, `F5 03`) in `companion_controller.dart` had an early `break` when cancelling a pending tilt-up intent, which skipped calling `GlanceService.startLookDownTimeout()`. If the display was already visible from a previous confirmed intent or notification auto-pop, the clear timer never started and the display stayed on the glasses indefinitely. Fix: `startLookDownTimeout()` is now called unconditionally on every tilt-down in Glance mode. The method's own `if (!_isVisible) return;` guard makes it a safe no-op when the display is not visible. One case block changed; no new fields or methods.

### Glance: "Now Playing" media integration (2026-05-06)
Media notifications from streaming apps are now absorbed into Glance line 1 instead of cycling through the notification carousel. Line 1 shows `12:41  |  100%  |  ▶ Green Day - Dookie` when playback is active; reverts to `12:41  |  100%` when stopped. New `NotificationDisposition.mediaAbsorbed` classification. Two-tier detection: auto-detect (`isMediaStyle && category == transport`) plus per-app "Now Playing" toggle in Settings. Track text truncated with `...` at 43-char display width. DB migrated v1 → v2 (`media_override` column). Settings UI gains two toggles per app: "Now Playing" and "Mute". 6 files changed: `notification_policy.dart`, `notification_settings_store.dart`, `notification_package_preference.dart`, `glance_service.dart`, `companion_controller.dart`, `settings_page.dart`.

### Glance: notification display reworked to 3-line format (2026-05-04)
`lib/services/glance_service.dart` (`_buildDisplayText`). The Glance notification HUD is now a compact 3-line layout: line 1 shows `HH:MM  |  <battery>` (pipe separator between time and battery); line 2 shows `<source>  ·  HH:MM` (mid-dot separator between source and posted time); line 3 is the message content, wrapping naturally via TextService. Earlier in the day the posted time was added as a fourth line; this follow-up merged source and posted time onto one line and dropped the count to three. No model or protocol change — `CompanionNotification.postedAt` was already populated. The "No notifications" idle branch is unchanged. Build green; no new analysis issues.

### Authoritative settings reconcile — brightness, auto, head-up, double-tap (2026-05-01)
Device testing confirmed complete. Settings persist across cold launches; slider loads its last position from `AppSettingsStore` on startup. All four firmware settings (brightness level, auto-brightness, head-up behaviour, double-tap action) re-assert on every BLE reconnect — even when the official Even Realities app has written different values in between.

### Brightness readback investigation (2026-05-01)
Empirical testing pinned `0x29` as the brightness GET path (level only; the wiki's claim that byte 3 carries the auto flag was not reproduced). Identified triggers for `0x6e` (TX `23 74`), `0x3e` (TX `3e`), and `0x2c` (host poll, not unsolicited firmware push). Confirmed the right-temple ambient light sensor location. Confirmed `F5 12` already fires unprompted ~15 s after connect with the current level. Decision: pivot to authoritative settings model rather than firmware readback — companion app re-pushes all four settings on every BLE reconnect (see 2026-05-01 authoritative settings entry above). Full protocol detail in `docs/FINDINGS-battery+brightness.md`.

### Chat `0x52` streaming (Confirmed, 2026-05-01)
Paced streaming via `StreamingRenderQueue` is fully implemented in Chat. Backend chunks are decoupled from display: the queue drains 2 words every 200 ms (~450 WPM effective with BLE overhead), wraps at 43-char word boundaries, and keeps only the last 3 lines — matching the firmware's 3 visible rows. The firmware does NOT auto-scroll; the host manages scrolling. Line 1 carries a `\n` marker; line 2 carries all visible text. Follow-up turns do `Proto.exit()` only when a prior `0x52` session is active. Full reference detail is in `AGENTS.md` and `docs/FINDINGS-layouts.md`.

### Battery + wear state
`F5 06/08/0B/0A/0F` ingestion wired into `DeviceStatusService`. Glasses battery % displays next to the Glance time line; home screen shows glasses %, case %, and a Worn / In cradle pill.

### Brightness slider + auto toggle (push side)
`0x01 <level> <auto>` set wired via `Proto.setBrightness`. `F5 12 <level>` echo handled by `DeviceStatusService`. Home screen Display section has a brightness slider (commits on release) and an auto-brightness switch.

### Firmware settings dropdowns (push side)
Head-up behaviour (`0x08`) and double-tap action (`0x26`) wired as dropdowns on the Settings page. Choices persisted in `AppSettingsStore`; companion app does not re-send on reconnect (non-invasive — superseded by authoritative model, see 2026-05-01 entry above).

### Double-tap host-action mode switch
`F5 20` wired to `CompanionController.handleDoubleTapModeSwitch`. Cycles companion app modes when the official app's double-tap action is set to a host-handled type (Transcribe / Translate / Teleprompter).

### Navigate `0x0a` lifecycle proven
Full 108-packet interleaved replay renders on the glasses. Dynamic TRIP_STATUS injection from live Google Maps fields is working. MAP_OVERVIEW direction icon is dynamically generated from the Google Maps notification PNG (decoded to 136×136 monochrome, RLE-encoded), with geometric arrow fallback via `ManoeuvreType` enum. 1-second SYNC poller keeps the session alive. Post-bootstrap updates use TRIP_STATUS+SYNC. Idle-prompt suppression prevents first-load race conditions.

---

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
- Full write-up in `FINDINGS-battery+brightness.md`

Brightness:
- TX `0x01 <level> <auto>` is the brightness command (level 0..42, auto 0/1)
- The glasses push `F5 12 <level>` whenever the level actually changes,
  giving a confirmation channel
- Now wired in this app: a Display section on the home screen has a
  brightness slider (commits on release) and an auto-brightness switch.
  `Proto.setBrightness` is the wire-level send; `DeviceStatusService` owns
  the locally-tracked auto flag and the echoed level.
- `0x29` is the brightness GET path (level only); the auto flag is NOT
  readable back — the wiki's byte-3 auto claim was not reproduced in testing
- `0x2c` is a host-poll opcode (the host sends it; not an unsolicited push from
  the firmware). Do not treat it as a proactive status broadcast.
- The ambient light sensor used for auto-brightness is physically located in
  the right temple of the glasses

Persisted-on-glasses settings (head-up + double-tap):
- 2026-04-28 settings capture (`FINDINGS-settings.md`)
  pinned the wire formats for both:
  - Head-up: TX `08 06 00 00 03 <value>` — `0x00` = firmware dashboard,
    `0x02` = no firmware overlay (companion app drives any visible
    response).
  - Double-tap: TX `26 06 00 <seq> 05 <value>` — `0x00` none, `0x02`
    translate, `0x03` teleprompter, `0x04` dashboard, `0x05` transcribe.
- Wired into the Settings page as a "Firmware Settings" section between
  Notification Filters and Permissions. Two dropdowns: Tilt-up behaviour
  and Double-tap behaviour. Choices are persisted in `AppSettingsStore`
  so they survive app restarts; the companion app does **not** re-send
  on connect (non-invasive — superseded by authoritative model, see 2026-05-01 Recently Done). The settings themselves persist on the
  glasses' firmware regardless.

Quicknote post-release stream (Confirmed, 2026-05-09):
- `0x21` fires 42 bytes — circular buffer notes-list dump (4 records); diff-based detection identifies the just-recorded note.
- Host must send `1e 06 00 <seq> 02 <noteIndex>` to right leg to trigger audio stream — firmware does NOT stream unsolicited.
- LC3 codec confirmed at 200-byte frames; BLE chunks are 190 bytes — concatenate then re-slice.
- `0x1e c8 ...` chunked stream fully decoded, audio intelligible. Full pipeline shipped (see Recently Done).
- Ack sequence: host sends `1e 06 00 <seq> 04 01`; glasses respond `1e 06 00 <seq> 04 00`.
- Full write-up in `docs/FINDINGS-quicknote.md`.

Note-management family `0x06`:
- Three-step transaction with an 8-byte note UID, used by the official
  app for delete / reorder. UID shape matches the trailing block in
  `R21` payloads. Out of scope for the current app.

Rendering protocols (layouts capture):
- 2026-04-28 layouts capture (`FINDINGS-layouts.md`) discovered three new
  rendering paths the official app uses beyond `0x4E` text and BMP:
  - **`0x52` live streaming text** — word-by-word with cursor, `0x53`
    keepalive every 5 s. **Fully implemented in Chat** (`Confirmed`,
    2026-05-01) via paced `StreamingRenderQueue` with host-managed
    scrolling: 43 chars/row, 3 visible rows, 2 words/tick at 200 ms.
    The firmware does NOT auto-scroll; the host wraps at word boundaries
    and trims to the last 3 lines.
  - **`0x0a` navigation card** — structured text data slots in one ~48-byte
    packet (ETA, distance, road, turn distance) plus optional icon/map
    bitmap chunks. The current Navigate implementation uses:
    - full 108-packet interleaved replay for bootstrap
    - dynamic live `TRIP_STATUS` replacement inside that replay
    - 1-second `SYNC` keepalive while the session is active
    - post-bootstrap `TRIP_STATUS + SYNC` updates as the current experiment
  - **`0x1e` TX dashboard data slots** — pushes titled content into the
    firmware's grid layout. Enables companion-app quicknote and dashboard
    injection features.
  - **`0x50` display mode control** — primes the display before entering
    streaming text or navigation card mode.
- `0x52` and `0x0a` are both now implemented in the companion app (Chat and
  Navigate respectively). `0x1e` dashboard injection remains a future
  protocol-driven area.

Tap and long-press mapping:
- 2026-04-28 capture (`FINDINGS-taps.md`) hardened the
  understanding of the touch family:
  - **single taps (left or right) are not surfaced over BLE in any tested
    state** (idle, dashboard with notes, dashboard with notifications). The
    firmware visibly responds on the glasses but no BLE event fires.
  - `F5 17` / `F5 18` is left long-press press-down / release (Confirmed)
  - right long-press (QuickNote) does not fire `F5 17` / `F5 18`; it fires
    `0x21` only, currently length `15` (the historical `len == 42` may have
    been a different family member or earlier firmware)
  - `F5 04` / `F5 05` triple-tap silent toggle (now Confirmed)
  - **`F5 20` is new**: fires when a double-tap triggers the official Even
    app's configured double-tap action (currently observed only with that
    action set to "transcribe")
- `F5 20` is now wired into the companion app as a passive mode-cycle hook
  via `CompanionController.handleDoubleTapModeSwitch`.
- Live testing across configurations of the official app's double-tap
  setting confirmed `F5 20` is generic to "host-handled action":
  Transcribe / Translate / Teleprompter all fire `F5 20` and the mode
  cycle works. Dashboard is firmware-native (no `F5 20`); None only fires
  `F5 00` and only when there is something to close.

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

---

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

---

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

---

## What To Tell A Fresh Session

Good first prompt pattern:
- say which single area is being worked on now
- mention whether the issue is:
  - Navigate `0x0a` cleanup (`navigate_service.dart`, `nav_icon_generator.dart`) — **Now #4 (in flight)**; startup robustness, EXIT/ARRIVED handling, replay scaffolding decision remain open; field extraction / time set / PANORAMIC_MAP placeholder done
  - Capture v2 gating spike (`capture-v2-hud-probe`) — top of Next; 1-hour timebox to verify HUD writes don't corrupt LC3 audio
  - Capture v2 HUD + safer stop (`capture-v2-recording-hud`, `capture-v2-safer-stop`) — blocked on spike result
  - Router v1 (`router-v1-glance-handlers`, `router-v1-chat-logging`) — independent stream; medium priority
  - QuickNote classifier tuning — Next (bottom); not ready yet; needs more variety tested first
- point the agent to:
  - `AGENTS.md`
  - `README.md`
  - `docs/current-behaviour.md`
  - `docs/current-architecture.md`
  - this file

---

## Files Most Likely Relevant Next

- [lib/services/chat_service.dart](../lib/services/chat_service.dart)
- [lib/services/streaming_render_queue.dart](../lib/services/streaming_render_queue.dart)
- [lib/services/notification_policy.dart](../lib/services/notification_policy.dart)
- [lib/services/glance_service.dart](../lib/services/glance_service.dart)
- [lib/services/device_status_service.dart](../lib/services/device_status_service.dart)
- [lib/services/companion_controller.dart](../lib/services/companion_controller.dart)
- [lib/services/navigate_service.dart](../lib/services/navigate_service.dart)
- [lib/services/features_services.dart](../lib/services/features_services.dart)
- [lib/controllers/bmp_update_manager.dart](../lib/controllers/bmp_update_manager.dart)
- [android/app/src/main/kotlin/com/eddie/evencompanion/notifications/RecentNotificationsListenerService.kt](../android/app/src/main/kotlin/com/eddie/evencompanion/notifications/RecentNotificationsListenerService.kt)
- [android/app/src/main/kotlin/com/eddie/evencompanion/TelephonyEventService.kt](../android/app/src/main/kotlin/com/eddie/evencompanion/TelephonyEventService.kt)
