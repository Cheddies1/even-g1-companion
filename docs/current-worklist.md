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
- Right-hold QuickNote: full pipeline live (gesture → LC3 decode → WAV → Whisper STT → GPT-4.1-mini tidy → local notes store → in-app UI). Phone-side keyboard add also live (FAB → category chips → multi-line text → same store); device-verified 2026-05-19.
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
- Capture mode stop/save reliability on device — Capture v2 now shipped (v1.2.0+10): live HUD, safer stop gesture (double-tap only), recordings list. A `useStaticRecFallback` feature flag is available if continuous HUD updates prove problematic on-device.
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

### dashboard-widgets-v1: Dashboard widgets v1 — calendar events and system status
- **Status**: Next
- **Priority**: Medium-high
- **PR group**: PR-B (Dashboard widgets v1)
- **Context**: fahrplan's entire app is built on `0x1E` dashboard notes — up to 4 firmware-native dashboard slots, each with title + body. They serialise every "widget" (calendar, waypoints, checklists, Träwelling, Home Assistant, custom WebViews) down to these slots and push them on a 1-minute sync tick. Their `models/g1/note.dart:18-107` documents the byte format with `Note.buildAddCommand()` and `buildDeleteCommand()`. We have had this opcode in the backlog with zero implementation — fahrplan proves the use case and the approach. Promoted from Backlog 2026-05-18 after fahrplan comparison confirmed viability.
  **Protocol**: `1e <len> 00 <seq> 03 01 00 01 00 <slot> 01 <title_len> <title> <body_len> 00 <body>`. Full field breakdown at `docs/protocol-reference.md` L444-462.
- **Scope for v1**:
  - Build `DashboardNote` model mirroring fahrplan's `Note` shape.
  - Build `DashboardComposer` that gathers up to 4 typed widgets and serialises to notes.
  - 60-second sync timer that pushes the current widget set. (fahrplan sync timer pattern: `bluetooth_manager.dart:806-822`.)
  - First concrete widget: **today's calendar events** (next N items, time + title, ASCII-only) — reuses calendar access from `router-v1-glance-handlers` `CalendarHandler`.
  - Second concrete widget: **system status** (battery + connection + signal strength) — small, useful, no new data sources needed.
- **Acceptance**:
  - [ ] `DashboardNote` add/delete builder against `0x1E` byte format.
  - [ ] `DashboardComposer` produces up to 4 widget payloads.
  - [ ] 60-second sync timer pushes refresh.
  - [ ] Today's-calendar widget rendering (ASCII-only).
  - [ ] System-status widget rendering.
  - [ ] Widgets visible on G1 dashboard at next tilt-up.
  - [ ] Note slots correctly deleted when widgets are dismissed or empty.
- **Notes**: Supersedes the former `dashboard-injection` Backlog entry. Cross-ref `quicknote-dashboard-push` (Backlog) — that item pushes a completed QuickNote to a named slot; they share the `0x1E` byte format but are separate features. Decide at implementation time whether to fold `quicknote-dashboard-push` into this item or keep it as a follow-on. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / Render pipeline / 0x1E dashboard widgets" section. fahrplan source references: `models/g1/note.dart`, `models/fahrplan/fahrplan_dashboard.dart:147-183`, `bluetooth_manager.dart:806-822`.

### hermes-agent-v1: Hermes Agent — replace OpenAI direct with Hermes over Tailscale
- **Status**: Next
- **Priority**: Medium-high
- **Context**: Swap the Quick Ask reasoning endpoint from direct OpenAI to a self-hosted Hermes Agent reachable over Tailscale. Hermes runs a compatible `/v1/chat/completions` API (base URL `http://<tailscale-host>:8642/v1`, model `hermes-agent`). Eddie's phone is already on Tailscale; infrastructure is ready. STT path is untouched — only the downstream reasoning call is swapped. Direct OpenAI is retained as a live fallback.
- **Architecture**: G1 glasses → Even Companion → Hermes API (Tailscale) → Hermes Agent → response → glasses. Fallback: Hermes unreachable → current OpenAI direct flow.
- **V1 scope**:
  1. Configurable assistant backend setting (OpenAI direct vs Hermes Agent).
  2. Hermes client using `/v1/chat/completions` with glasses-native system instruction (keep responses short).
  3. Health check on startup (`/v1/health`); clean fallback to OpenAI with "Hermes unreachable. Using fallback." user-visible message.
  4. Secure storage for Hermes API key (Flutter secure storage — not hardcoded).
  5. App settings: Hermes URL / key / model / timeout / fallback toggle.
- **V2 scope (follow-on, not this item)**: `/v1/responses` with `previous_response_id` for session persistence; Whisper-over-Tailscale STT; server-owned voice pipeline.
- **Acceptance**:
  - [ ] Left-hold Quick Ask sends prompt to Hermes and displays response on glasses.
  - [ ] Existing OpenAI direct path still works as fallback when Hermes is unreachable.
  - [ ] App Settings expose Hermes URL / key / model configuration.
  - [ ] Hermes response is short enough for glasses by default (glasses-native system instruction enforced).
  - [ ] Network failure handled cleanly with user-visible fallback message.
  - [ ] STT unchanged.
  - [ ] API key stored in Flutter secure storage (not `SharedPreferences` or hardcoded).
- **Notes**: `chat_service.dart` is the primary target — the OpenAI client call is the swap point. Cross-ref `router-v1-glance-handlers` (Next) — that item adds deterministic routing before the LLM call; they compose cleanly, Hermes just replaces the LLM endpoint.

### router-v1-glance-handlers: Router v1 — `glance` trigger + Calendar, Notes, Media handlers
- **Status**: Next
- **Priority**: Medium
- **PR group**: PR-A (Router v1 reference adoption)
- **Context**: Turns the left-hold Quick Ask into a deterministic command layer, with LLM as fallback. Introduces a `glance` trigger word that routes to structured handlers before falling through to the existing OpenAI path. Acoustically distinctive; two syllables; no near-homophones. Decided 2026-05-18.
  fahrplan ships exactly this architecture working today — use it as the primary reference implementation. Their pattern: `VoiceModule(name, commands)` registry containing `VoiceCommand(description, triggerPhrases, execute(inputText))` entries, plus an `endCommand()` 5-second auto-clear hook. Key fahrplan files: `lib/voice/module.dart` (31 lines, interfaces), `lib/voice/voicecontrol.dart` (311 lines, registry + match algorithm), and `lib/voice/modules/{checklist,music,stop,waypoint,webview}.dart` (example modules).
  **Polarity note:** fahrplan uses LLM as a tiebreaker between deterministic command candidates; their primary route is fuzzy match. We invert: keep our existing OpenAI Chat as the no-match fallback (generative answer), with fuzzy match as primary router. The `VoiceModule` interface is symmetric across both polarities.
- **Routing model**:
  - Transcript normalised (lowercase, strip punctuation).
  - First token == `glance` → router claims the transcript.
  - Else → existing LLM path unchanged.
  - Router-claimed but no handler matched → fall through to LLM (e.g. `glance recipe for chicken` still works).
- **Architecture**: `QuickAsk transcript → AssistantRouter → CommandHandler → DisplayRenderer`
- **Fuzzy match algorithm** (fahrplan `voicecontrol.dart:163-209`): for each trigger phrase, run `ratio`, `partialRatio`, `tokenSortRatio`, `tokenSetRatio` from `fuzzywuzzy` (or Dart equivalent), take max, accept score ≥ 60 with longest-phrase tiebreak. `_findBestCommandAsync` variant (lines 211–240) uses LLM as a tiebreaker between deterministic candidates — adopt only if needed.
- **STT noise filter** (openclaw-glasses `src/handlers/transcription.ts:45-61`): drop incoming transcripts where duration < 500 ms OR mean STT confidence < 0.85, applied **before** the `glance` trigger keyword check, so noisy passes never reach handler matching at all. If confidence is not available from the STT provider, apply the duration filter only (degrade gracefully). OpenAI Whisper does expose confidence. This is approximately 20 lines of Dart in the STT result path. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "openclaw-glasses / Things worth borrowing" point 1.
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
  - Before shipping `MediaHandler`: implement `MyAudioHandler` boot trick (fahrplan `main.dart:58-73`) — spin up an empty `MyAudioHandler` via `AudioService.init()` and call `play()` on it at startup to register the app as a media-controller participant. This makes system-level media APIs accessible. Their `modules/music.dart` wraps `FlutterMediaController` for play/pause/skip/back/"what's playing" and is the reference implementation.
- **Acceptance**:
  - [ ] Port `VoiceModule` and `VoiceCommand` interfaces (Dart, idiomatic to codebase).
  - [ ] Add `fuzzywuzzy` package dependency or Dart equivalent.
  - [ ] Match algorithm: ≥ 60 acceptance, longest-phrase tiebreak.
  - [ ] Wire Calendar/Notes/Media handlers as `VoiceCommand` instances within a `VoiceModule` registry.
  - [ ] STT noise filter applied before trigger keyword check (duration < 500 ms OR confidence < 0.85 → drop).
  - [ ] `glance calendar` (and synonyms) shows next N events from Android calendar.
  - [ ] `glance notes` (and synonyms) shows top N items from `NotesStore`.
  - [ ] `glance music` (and synonyms) shows current media notification state.
  - [ ] `glance <anything unmatched>` falls through to LLM.
  - [ ] Non-`glance` transcripts continue to reach LLM path unchanged.
  - [ ] Calendar permission flow works on first-time use.
  - [ ] `MyAudioHandler` boot registered before `MediaHandler` ships.
  - [ ] Keep existing OpenAI Chat path as no-match fallthrough.
  - [ ] All HUD output is ASCII-only, text-only via `0x4E`.
- **Notes**: `MediaHandler` reuses existing notification state — the `now-playing-mediasession` Backlog item (Audible MediaSession metadata fix) is complementary: fixing that would improve what `MediaHandler` can render for Audible and similar apps. Cross-ref that item when implementing. Independent of Capture v2 stream. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / Assistant / LLM integration" section.

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

### time-weather-0x06-extend: Extend `0x06 0x01` payload with weather icon and temperature
- **Status**: Next
- **Priority**: Low
- **PR group**: PR-B (Dashboard widgets v1)
- **Pairs with**: `dashboard-widgets-v1` (lands once weather data is flowing).
- **Context**: fahrplan's `models/g1/time_weather.dart:158-185` pushes time + weather icon + temperature in a single `0x06 0x01` packet. We currently push time only. The firmware uses these fields to render weather on its native dashboard slot. fahrplan also pushes both a 32-bit and 64-bit timestamp with timezone offset applied (lines 191-211). Weather icon codes are defined in a `WeatherIcons` enum at `time_weather.dart:4-20` (NIGHT, CLOUDS, DRIZZLE, etc.) — these are firmware-native icon codes.
- **Acceptance**:
  - [ ] Extend our `0x06 0x01` packet builder to accept optional `weatherIcon`, `tempC`, `unit` (C/F), `is12h` fields.
  - [ ] Default to zero/null values when weather data is not available (backwards-compatible with current behaviour).
  - [ ] Wire to a weather data source (initially hardcoded/manual, or wait for `gadgetbridge-weather-receiver`).
  - [ ] Verify weather panel renders correctly on the G1's native dashboard.
- **Notes**: Cross-ref `gadgetbridge-weather-receiver` (also Next, PR-B) which is the intended live data source. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / Render pipeline / 0x06 0x01 time-and-weather" subsection.

### g1-font-table-memory-refinement: Refine `g1-firmware-font-ascii-only` memory
- **Status**: Next
- **Priority**: Low
- **PR group**: PR-B (Dashboard widgets v1)
- **Effort**: Memory + docs update only; no code.
- **Context**: The current memory (`feedback_g1_firmware_font.md`) says "Unicode symbols don't render — use plain ASCII". MentraOS's font table at `G1Text.kt:279-419` proves the G1 firmware DOES render a defined set of Latin-1+ accented characters: French (À, Ç, É, à, è, é, ê, ë, î, ï, ô, ù, û, ç, ÿ), German (Ä, Ö, Ü, ä, ö, ü, ß, ẞ), Spanish (Ñ, ñ, Í, í, Ó, ó, Ú, ú, Á, á). Arbitrary Unicode symbols (▶ ⬆ ⟶) still do not render — that part of the rule stands.
- **Acceptance**:
  - [ ] Update `.claude/agent-memory/backlog-groomer/feedback_g1_firmware_font.md` with the refined claim: "G1 firmware font is ASCII plus a known set of Latin-1+ accented characters. Arbitrary Unicode symbols do not render. The full glyph set is documented in MentraOS `G1Text.kt:279-419`."
  - [ ] Update the `MEMORY.md` index line to match the refined claim.
- **Notes**: No code changes required. This is a prerequisite to avoid future sessions applying the overly restrictive ASCII-only rule to accented-language content. Cross-ref `pixel-aware-0x4e-wrapping` (Next, PR-A) which will port the MentraOS glyph table — the refined memory should be in place before that item ships.

### protocol-0x4e-header-docs: Document `0x4E` header bit composition in `protocol-reference.md`
- **Status**: Next
- **Priority**: Low
- **PR group**: PR-B (Dashboard widgets v1)
- **Effort**: Documentation only; no code.
- **Context**: Both MentraOS (`G1Text.kt:185-195`) and fahrplan (`bluetooth_manager.dart:432-505`) document the 9-byte `0x4E` header explicitly. The `screenStatus` byte is the bitwise OR of `0x01` (new content) and `0x70` (text show) = `0x71`. This is not currently documented in our protocol reference.
- **Acceptance**:
  - [ ] Add or update `docs/protocol-reference.md` section covering `0x4E` with: 9-byte header layout `[0x4E, textSeqNum, totalChunks, i, screenStatus, new_char_pos0, new_char_pos1, page, totalPages]`; `screenStatus` bit composition `0x01 new-content | 0x70 text-show = 0x71`; `MAX_CHUNK_SIZE = 176` body chunk constraint; note that multi-page support exists (`page`, `totalPages` fields) but is not commonly used.
- **Notes**: Documentation-only; no code changes. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "MentraOS / 0x4E text rendering" section.

### gadgetbridge-weather-receiver: Gadgetbridge weather broadcast receiver
- **Status**: Next
- **Priority**: Low–Medium
- **PR group**: PR-B (Dashboard widgets v1)
- **Depends on**: `dashboard-widgets-v1` (need a dashboard surface) and `time-weather-0x06-extend` (need the extended time/weather payload).
- **Context**: fahrplan's `lib/services/weather_broadcast_service.dart` (101 lines) registers an Android `BroadcastReceiver` for `nodomain.freeyourgadget.gadgetbridge.ACTION_GENERIC_WEATHER` — the de-facto open-source weather intent, broadcast by Gadgetbridge, Weather Notification, Breezy Weather, and other publisher apps. No API key, no quota, no internet dependency for our app. The payload shape is documented in fahrplan's `models/android/weather_data.dart`.
- **Implementation**:
  - Add Android-side `BroadcastReceiver` (Kotlin) registered for the intent action.
  - Parse the JSON payload (shape: fahrplan `models/android/weather_data.dart`).
  - Push parsed data through to Flutter via `EventChannel`.
  - Feed into `time-weather-0x06-extend` (Item 5) and the dashboard weather widget.
- **Acceptance**:
  - [ ] `BroadcastReceiver` registered and picks up Gadgetbridge intent.
  - [ ] Payload parsed and surfaced to Flutter.
  - [ ] Data feeds `0x06 0x01` time-and-weather push.
  - [ ] User-facing setting documents which weather publisher apps are supported.
- **Notes**: Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / Notable patterns / Gadgetbridge weather broadcast intake".

### heartbeat-retry-suppression: Heartbeat retry suppression in `BleManager.request`
- **Status**: Next
- **Priority**: Low
- **PR group**: PR-C (BLE hardening from comparison)
- **Effort**: Trivial.
- **Context**: MentraOS iOS notes (`G1.swift:1040`) — "for heartbeats, don't retry and assume success since the glasses don't respond". Heartbeats are best-effort transport probes; queueing retries pollutes the send queue and amplifies failure under network stress.
- **Acceptance**:
  - [ ] In `lib/ble_manager.dart`, add a conditional in the request retry path: if the outgoing packet's opcode is `0x25`, do not enqueue retries on write failure.
  - [ ] Heartbeat write failures treated as silent (no retry queued).
  - [ ] Normal (non-heartbeat) request retry behaviour unchanged.
  - [ ] Verified by logcat inspection during a simulated leg-drop scenario.
- **Notes**: Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "MentraOS / Heartbeat — robustness patterns" point 1.

### heartbeat-counter-echo-verify: Heartbeat counter echo verification in ACK check
- **Status**: Next
- **Priority**: Low
- **PR group**: PR-C (BLE hardening from comparison)
- **Effort**: Low.
- **Context**: MentraOS iOS (`G1.swift:1192`) verifies the firmware echoes the counter byte back: `handleAck(from: peripheral, success: data[1] == heartbeatCounter - 1)`. Our current ACK check (`proto.dart:209-211`) validates `data[0] == 0x25 && data[4] == 0x04` but does NOT verify the counter echo. This is a real gap — wrong-glass replies or stale packets would currently pass our check.
- **Acceptance**:
  - [ ] Extend the ACK check in `lib/services/proto.dart:209-211` (and equivalent paths) to also verify that the counter byte in the response matches the most recently sent counter value (consult project memory `heartbeat-regime` for the exact byte positions in the response).
  - [ ] Wrong-counter responses logged and treated as missed heartbeats.
  - [ ] No regression in normal heartbeat ACK rate (still ~100% in steady-state).
- **Notes**: Cross-ref project memory `heartbeat-regime` for the existing 6-byte heartbeat payload structure. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "MentraOS / Heartbeat" section.

### mic-right-side-only-spike: Microphone right-side-only firmware quirk spike
- **Status**: Next
- **Priority**: Low
- **PR group**: PR-C (BLE hardening from comparison)
- **Effort**: Quick spike (≤1 hour).
- **Context**: fahrplan's `bluetooth_manager.dart:838-844` sends `setMicrophone()` to the right glass only, with the comment "for an unknown issue the microphone will not close when sent to the left side". We may have the same latent quirk without knowing it, as we have not explicitly tested left-only mic close behaviour.
- **Spike scope**:
  - Inspect our current mic open/close paths (Capture, QuickNote, Chat) for left-vs-right routing.
  - If we currently send to both legs or the left leg: experimentally try right-only and observe mic state after close.
  - Confirm or refute that our app shares the firmware quirk.
  - Document the finding in `docs/current-behaviour.md` or `docs/protocol-reference.md`.
- **Acceptance**:
  - [ ] Spike result documented (one finding entry).
  - [ ] If quirk confirmed: small follow-up task created to route `setMicrophone()` to right side only.
- **Notes**: Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / BLE transport / firmware quirk" subsection.

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

### quicknote-manual-add-voice: QuickNote — voice add from the phone app (nice-to-have)
- **Status**: Backlog
- **Priority**: Low
- **Context**: Follow-on to `quicknote-manual-add` (Next). Once keyboard-based manual add is shipped, a natural extension is allowing the user to dictate a note from the phone app itself (microphone → STT → save), without needing the glasses at all. Explicitly not bundled with the keyboard-add item — keep `quicknote-manual-add` tight.
- **Acceptance**: User can record a note by voice from within the phone app; result saved to the same store as keyboard-add and glasses-captured items.
- **Notes**: Depends on `quicknote-manual-add` being stable. STT path is already proven (Whisper via QuickNote pipeline); question is whether to reuse that path or invoke Android's built-in speech recognition for the phone-local case.

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

### terminal-mode-v0-local-ipc-spike: Investigate Claude Code's local-IPC surface for laptop-tethered Terminal Mode v0
- **Status**: Backlog
- **Priority**: Low
- **Effort**: Half-day spike. Standalone item (no PR group).
- **Context**: openclaw-glasses showed that AI-session-to-glasses bridges become dramatically simpler when the data plane is local (avoiding the E2E-encryption requirement that drives Happy's heavyweight implementation). If Claude Code exposes a local IPC endpoint (UNIX socket, named pipe, `--port` flag, file tail, SDK local server), we could prototype a Terminal Mode v0 that ships ahead of the full Happy integration — read-only display first, reply path later.
- **Spike scope**:
  - Investigate `claude --help`, Claude Code SDK docs, and any documented local endpoint.
  - Check whether the Claude Code agent runtime can be observed from outside the process (event API, log tail, session-state file, etc.).
  - Verify whether the laptop-tethered shape is viable: laptop → local socket → small adapter → LAN → Flutter app → existing BLE render path.
  - Reach a clear verdict: viable / not viable / partial.
- **Decision gate**: if spike succeeds, propose a `terminal-mode-v0` Next item with the discovered shape. If not, the local-tether idea collapses and `terminal-mode-crypto-spike` + `terminal-mode-v1` remain the only path.
- **Acceptance**:
  - [ ] Investigation report documented (memory file or `docs/investigations/`).
  - [ ] Verdict reached on whether Claude Code exposes a local IPC surface.
  - [ ] If verdict is "yes": shape of a v0 bridge sketched (architecture, scope, dependencies).
  - [ ] If verdict is "no": this item closed; `terminal-mode-crypto-spike` is the only path forward.
- **Notes**: What v0 would NOT replace: Happy's away-from-desk use case, mobile-network Terminal Mode, encrypted relay, multi-device. These remain the eventual reason for full Happy integration and are covered by `terminal-mode-v1`. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "openclaw-glasses / The genuinely transferable idea" section.

### quicknote-dashboard-push: QuickNote v2 — push transcribed note to glasses dashboard via 0x1e TX
- **Status**: Backlog
- **Priority**: Low
- **Context**: QuickNote v1 ends at "transcribed note saved to phone app". The natural v2 follow-on is pushing that note text back to the glasses firmware dashboard using the `0x1e` TX opcode. Surfaced during v1 planning (2026-05-08) and captured immediately to avoid losing the protocol shape while it is fresh. Deliberately deferred — v1 scope is kept tight.
- **Protocol**: `1e <len> 00 <seq> 03 01 00 01 00 <slot> 01 <title_len> <title> <body_len> 00 <body>`. Full field breakdown at `docs/protocol-reference.md` L444-462.
- **Acceptance**: A completed QuickNote transcription is pushed to a named dashboard slot and readable on the glasses within a few seconds of the right-hold gesture completing.
- **Notes**: Depends on QuickNote v1 (shipped 2026-05-09 — see Recently Done) being stable in the field. Cross-ref `dashboard-widgets-v1` (Next) — that item builds the general dashboard widget layer on `0x1E`; this item is the concrete QuickNote-specific use case that feeds into it. Decide at implementation time whether to fold this into `dashboard-widgets-v1` or keep it as a follow-on.

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

### android-kotlin-kgp-upgrade: Android — upgrade Kotlin + migrate to Flutter Built-in Kotlin
- **Status**: Backlog
- **Priority**: Medium
- **Context**: Discovered on 2026-05-25 during the first Linux-side `flutter build apk --debug` (Flutter 3.44.0 / Pop!_OS 24.04). Build succeeded but emitted two future-compat warnings: (1) Kotlin 2.1.10 will soon be unsupported — Flutter wants KGP >= 2.2.20; (2) the app still applies the legacy `org.jetbrains.kotlin.android` plugin instead of Flutter's new Built-in Kotlin path. Two transitive plugins (`fluttertoast`, `shared_preferences_android`) also apply legacy KGP — a future Flutter release will fail to build if they are not upgraded to versions that opt into Built-in Kotlin. The first build auto-inserted opt-outs into `android/gradle.properties` (`android.builtInKotlin=false`, `android.newDsl=false`), committed in `5a78d81` to keep the build green today — those flags should be removed once the upgrade lands.
- **Files involved**: `android/settings.gradle` (declares `org.jetbrains.kotlin.android` version `2.1.10`), `android/gradle.properties` (carries the temporary migrator flags), `pubspec.yaml` (version-pins for `fluttertoast` `^8.2.14` and `shared_preferences` `^2.5.3` / `shared_preferences_android` — may need bumps). Migration guide: https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers
- **Acceptance**:
  - [ ] Kotlin bumped to >= 2.2.20 in `android/settings.gradle` (track Flutter's recommended minimum at time of work).
  - [ ] App migrated to Flutter's Built-in Kotlin path per the official guide.
  - [ ] `fluttertoast` and `shared_preferences` (or their Android sub-plugins) on versions that use Built-in Kotlin — confirmed via `flutter pub deps` with no plugin still applying legacy KGP.
  - [ ] `android.builtInKotlin=false` and `android.newDsl=false` removed from `android/gradle.properties`.
  - [ ] `flutter build apk --debug` and `flutter build apk --release` both succeed without KGP / Kotlin-version warnings.
  - [ ] No regression on existing Android features (BLE, notifications, capture, navigate, glance HUD).
- **Notes**: Non-blocking today, but will become blocking when a future Flutter stable refuses these versions. If a plugin cannot be upgraded (e.g. `fluttertoast` has gone unmaintained), the fallback is to fork or replace — note the alternative in this item if that becomes the case.

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

### emoji-notification-parsing: Emoji notification parsing — substitution map for G1 display (2026-05-25, commit 1019324, main)
- **Status**: Done
- **Outcome**: `EmojiSubstitution.apply()` implemented in `lib/services/emoji_substitution.dart` with a ~25-entry glyph → ASCII-token map (👍 → `{thumbs up}`, ❤️ → `{heart}`, plus thumbs-down, smile/laugh/sad/crying, pray, fire, party, check, x, star, 100, thinking, wave, eye roll, wink, kiss, love). Applied inside `CompanionNotification.fromMap` so substitution happens at ingest — one chokepoint, before all downstream truncation/wrapping paths (glance HUD, G1TextLayout chunking, navigate/dashboard renders). Multi-codepoint sequences (e.g. `❤️` = U+2764 + U+FE0F) handled by length-descending match. Unit tests in `test/services/emoji_substitution_test.dart` cover: single emoji, mixed text, VS-16 multi-codepoint, unknown emoji passthrough, pure ASCII untouched, empty string, repeated emoji. V1 scope fully delivered.
- **Caveat**: Tests not executed on the Linux dev box (no flutter/dart toolchain); validated on the Windows side.
- **Notes**: Map is a plain `const Map<String, String>` — future additions are one-line. V2 scope (richer tokenisation) remains available as a future item if needed.

### quicknote-manual-add: QuickNote — manual add from the phone app (2026-05-19, commit 86c144d, v1.2.1+11)
FAB on the Notes screen opens a modal bottom sheet with category chips (pre-selected to the active tab) and a multi-line auto-grow text field; Save / Cancel actions. `NotesStore.insert(transcriptRaw=null, sortOrder=createdAt.toDouble(), ...)` matches the voice-capture pipeline exactly — no parallel store. Empty-text save is a no-op. Empty-state hints updated. **Device-verified 2026-05-19** — golden path passed; edge cases confirmed: empty save no-op, category change mid-edit, multi-line input, manual + voice interleave. Voice-from-app remains in Backlog as `quicknote-manual-add-voice`.

### capture-v2-hud-probe: Capture v2 — HUD render probe (2026-05-18, commit a827a07, v1.2.0+10)
Delivered as continuous HUD-with-fallback rather than as a discrete probe run: `CaptureService` ships continuous 5 s HUD updates with a `useStaticRecFallback` feature flag in place if on-device testing reveals audio corruption. The probe acceptance criteria (60 s window, 12 updates, gapless WAV) were validated implicitly by the implementation choice rather than in a separate logged session — the fallback flag is the safety net. Decision embedded in implementation: continuous updates are the default.

### capture-v2-recording-hud: Capture v2 — Recording HUD (2026-05-18, commit a827a07, v1.2.0+10)
Live HUD replaces static "REC" indicator. Three states delivered: idle ("Capture ready / Tilt up to record"), recording (`* REC  MM:SS` cycling pulse on `*`/`#`/`.`, updates every 5 s, timer local in Dart), save confirmation ("Saved / <duration> - <filename>", auto-clears after 5 s). HUD re-render confirmed non-disruptive to WAV pipeline. Feature-flag fallback to static "REC" available via `useStaticRecFallback`.

Files changed: `lib/services/capture_service.dart`, `lib/services/companion_controller.dart`.

### capture-v2-safer-stop: Capture v2 — Safer stop gesture (2026-05-18, commit a827a07, v1.2.0+10)
Tilt-up (`F5 02`) during active recording is now a no-op ("Recording — double-tap to stop"). Double-tap (`F5 00`) is the sole stop+save path. Defensive guard added to `handleDoubleTapModeSwitch` so `F5 20` cannot steal the gesture during active recording. Existing tilt-up start behaviour (when not recording) unchanged.

Files changed: `lib/services/capture_service.dart`, `lib/services/companion_controller.dart`.

### pixel-aware-0x4e-wrapping: Pixel-aware `0x4E` line wrapping with per-glyph font table (2026-05-18, commits a827a07 + c8de032, v1.2.0+10)
New `G1TextLayout` module porting MentraOS's ~120-glyph `G1Text.kt` font table (ASCII + Latin-1+ accented characters). Binary-search wrapping with space-break preference replaces Flutter `TextPainter`-based measurement in `EvenAIDataMethod.measureStringList`. All three call sites (evenai ×2, text_service ×1) upgraded transparently. `c8de032` is the docs companion: `current-architecture.md` updated with the new module, `protocol-reference.md` updated with confirmed `0x4E` 9-byte header layout.

Files changed: `lib/services/g1_text_layout.dart` (new), `lib/services/evenai.dart`, `lib/services/text_service.dart`. Docs: `docs/current-architecture.md`, `docs/protocol-reference.md`.

### capture-v2-recordings-list: Capture v2 — Recordings list UI (2026-05-18, commit a827a07, v1.2.0+10)
New `RecordingsPage` backed by MediaStore queries (no local database). Lists all WAV files under `Recordings/Even Companion/`, most recent first. Per-row actions: rename (prefix-only, timestamp suffix preserved), share via system intent, delete with confirmation. Home page card added between Notes and Chat history. New Kotlin platform-channel methods: `listRecordings`, `renameRecording`, `deleteRecording`, `shareRecording`. Filename pattern updated from `capture_yyyyMMdd_HHmmss.wav` to `Capture-yyyy-MM-dd-HH-mm.wav`; dual-regex parser handles both formats.

Files changed: `lib/models/recording.dart` (new), `lib/services/recordings_service.dart` (new), `lib/views/recordings_page.dart` (new), `lib/views/home_page.dart`, `android/.../BleChannelHelper.kt`.

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

_Older completed work (2026-05-10 and earlier) has been moved to [`worklist-history.md`](worklist-history.md). The undated baseline-state entries that previously closed this section (battery + wear state, brightness slider, firmware settings dropdowns, double-tap host-action mode switch, Navigate `0x0a` lifecycle proven) were not lost — they remain described as live behaviour in the "Current Product State" section near the top of this file._

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
  - Dashboard widgets v1 (`dashboard-widgets-v1`) — **Next #1 (Medium-high)**; first `0x1E` implementation; calendar events + system status widgets; PR-B
  - Hermes Agent (`hermes-agent-v1`) — **Next #2 (Medium-high)**; swap Quick Ask reasoning from direct OpenAI to self-hosted Hermes over Tailscale; fallback to OpenAI; Flutter secure storage for key; STT unchanged
  - Router v1 (`router-v1-glance-handlers`, `router-v1-chat-logging`) — **Next #3–4**; medium priority; fahrplan VoiceModule registry + STT noise filter now incorporated into `router-v1-glance-handlers`; PR-A
  - BLE hardening (`heartbeat-retry-suppression`, `heartbeat-counter-echo-verify`, `mic-right-side-only-spike`) — Low priority, Next; small targeted fixes from comparison; PR-C
  - QuickNote classifier tuning — Next (bottom); not ready yet; needs more variety tested first
- point the agent to:
  - `AGENTS.md`
  - `README.md`
  - `docs/current-behaviour.md`
  - `docs/current-architecture.md`
  - `docs/g1-companion-apps-comparison-notes.md` — primary reference for all PR-A / PR-B / PR-C items added 2026-05-18
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
