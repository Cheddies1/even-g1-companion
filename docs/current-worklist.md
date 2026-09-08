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
- **Capture** — ambient audio memory (long-form recording). Primarily glasses-triggered (tilt-up gesture), but since 2026-09-07 also available as a phone-only recording button on the home screen (no glasses required) - same pipeline, same storage, phone's own mic only for now; Bluetooth headsets and external mics are a later question.
- **Terminal Mode** — ambient engineering supervision (removed from active consideration; direction killed 2026-06-20).

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
- Direct-OpenAI Chat/Quick Ask device pass - `hermes-dewire-chat` (Done 2026-09-07) removed the Hermes backend and its plumbing entirely. `flutter analyze`, `flutter test` and the debug APK build are clean, but a device pass confirming Chat and left-hold Quick Ask still work end-to-end over the direct OpenAI route, including a clean network failure, has not yet been run.
- Phone-local recording on device - `phone-local-capture` (Done 2026-09-07) shipped a home-screen Record/Stop button using the phone's own mic, with a dedicated `microphone`-typed foreground service. Device-verified 2026-09-07: record/stop/save, the locked-screen and app-backgrounded case (13 minutes, 99.7% non-zero samples, no 30-second window below -55 dBFS), MediaStore indexing with correct duration, the first-run `RECORD_AUDIO` prompt starting on a single tap, the glasses HUD mirror in Capture mode, and both directions of the mic exclusion (phone-then-glasses refuses the tilt-up; glasses-then-phone greys the Record button out until the glasses recording ends). Still outstanding: the notification's "Stop and save" action tapped for real, and a long (hour-plus) screen-off recording against Samsung's battery optimiser.

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
- **Firmware-decomp input (2026-09-07)** — `docs/firmware-decomp-notes.md`. Three things land on this item:
  - **TRIP_STATUS field model was wrong.** `y` is a `uint16` (offsets 8-9), not a byte plus a null separator, and the first string starts at offset 10. Our captured prefix `01 03 c8 00 12 00` re-reads as direction=Right, x=200, y=18. Corrected in `docs/protocol-reference.md` and `docs/FINDINGS-layouts.md`. Check `navigate_service.dart` against the corrected table before any further dynamic-field work.
  - **Field size caps are hard.** 24 / 24 / 64 / 24 / 24 bytes for `time_remaining` / `remaining_kilometers` / `road_name_info` / `remaining_distance_info` / `current_speed`. Exceeding one **aborts the whole packet** rather than truncating — a plausible cause of any "renders nothing" case with a long road name. Same for bytes 1-2: if the declared length does not match the actual packet length, the firmware drops it silently.
  - **`spec_ble_command_hook.c` is an on-device nav simulator.** The firmware can synthesise `BLE_REQ_PUT_NAVIGATION_INFO` payloads from cJSON with no phone attached. If it is reachable over a normal BLE session (unknown), it is a much better way to isolate rendering bugs than replaying 108 packets. Worth 30 minutes before the replay-scaffolding decision.
- **Notes**: Cross-ref `docs/FINDINGS-layouts.md`, `docs/firmware-decomp-notes.md`, `lib/services/navigate_service.dart`, `lib/services/nav_icon_generator.dart`. See the related Parked item on PANORAMIC_MAP.

### navigate-osm-research: Navigate mode — architecture decision and spike plan
- **Status**: Now
- **Research** — decision reached 2026-06-20; now gating child spikes
- **Context**: The dashboard layout and HUD structure work well. The problem is data quality. The current approach — pulling turn instructions from Google Maps notifications — does not surface the next turn instruction reliably, breaks with the screen off, and provides no map geometry for the panoramic-map or mini-map regions.
- **Hard constraints** (any viable approach must satisfy all four):
  1. **Next turn displayed reliably** — the current Google Maps notification approach does not surface the next instruction dependably; the replacement must.
  2. **Map line-drawing** — renders a line-drawing of the map into the panoramic-map region (488×136) of the HUD; mini-map (136×136) shows the derived maneuver direction icon.
  3. **Walking / pedestrian directions** — this is a walking use case; routing quality for pedestrians is a first-class criterion.
  4. **Screen-off operation** — the current notification approach degrades or breaks when the phone screen is off; the replacement must work reliably with the screen off.
- **Architecture decision (2026-06-20, revised 2026-06-20 after Codex peer review): thin phone + thick Deepthought — vector scene graph**
  - **`cartographer` (Deepthought) — route compiler:** Tailscale-reachable, *not part of Hermes* (Hermes owns agent/assistant concerns; cartographer owns GIS/route/raster — clean separation). At trip start, receives origin + destination and returns:
    ```
    { polyline, maneuvers, scene_graph }
    ```
    `scene_graph` is a tiny simplified vector description — route line + ~2–3 cross streets + junction markers. Everything else suppressed via brutal cartographic generalisation appropriate for a 488×136 monochrome HUD. Stack: PostGIS + `osm2pgsql` (OSM extract), Valhalla or GraphHopper (walking-profile routing, TBD by Spike 2).
  - **Phone — live navigator with on-device renderer:** receives the scene graph once per trip (one network round-trip; cache locally). During the walk, the phone has real responsibilities:
    - **Map-matching:** projects GPS onto the route polyline to compute `routeProgressMeters` (distance-along-route), not "nearest tape frame by GPS".
    - **Renderer:** primitive line-segment + dot rasteriser into 488×136 monochrome. Heading-up / route-forward centring; dynamic zoom (zoom in near turns). No antialiasing.
    - **Off-route detection:** conservative — distance from polyline + heading disagreement + sustained duration. A single bad fix must not trigger a reroute.
    - **Reroute call:** only when genuinely off-route; hits `cartographer` once per trip start plus occasional reroutes.
  - **Mini-map (136×136):** keeps the existing direction icon, derived from the maneuver list rather than extracted from Maps notifications.
  - **Panoramic strip (488×136):** rendered on-device from the scene graph by the phone's primitive rasteriser.
  - **Google Maps notification path:** stays as a fallback for users without location grant; not built upon further.
  - **Philosophy:** this is a personal hobbyist project — owning a dedicated server module on Deepthought is fine, even encouraged. Optimise for "coolest possible for one user", not "deployable to many".
  - **Why vector scene graph over pre-rasterised bitmap tape:** heading-up rotation, route-forward centring, and drift-aware zoom all come for free without storing opaque frames. A tiny line-segment rasteriser on the phone is also likely less work than building a frame-tape index pipeline.
- **How the architecture satisfies the four constraints**:
  1. Turn instructions come from the routing engine's maneuver list (Valhalla/GraphHopper), not Maps notifications — reliable.
  2. Line-drawn map is rendered on-device from the scene graph; no large pre-rasterised tape required.
  3. Walking profile is a first-class routing-engine configuration.
  4. Screen-off is handled by the foreground service with `FOREGROUND_SERVICE_TYPE_LOCATION`; no notification-listening dependency.
- **Known design questions to resolve before/during implementation:**
  - **BLE bandwidth budget:** 488×136 raw = 8,296 bytes pre-RLE. Need to size bytes per panoramic update, packets per leg, update frequency, and whether both lenses must receive each update. Favour clean 1-bit geometry; no antialiasing.
  - **Orientation model:** heading-up / route-forward, not north-up. North-up is cognitively expensive on a 136 px-tall HUD.
  - **Destination entry:** architecture currently ignores how the user starts navigation. Options: share-destination intent from Google Maps, voice destination via existing assistant/quick-ask path, recent/favourites. Worth a follow-on sub-spike once core nav works.
  - **Map-match corridor width and off-route hysteresis:** tunables to be set during the routing-engine spike; default to generous (>15 m corridor, >10 s sustained off-route) until walking data says otherwise.
- **Child spikes** (cross-ref entries in Next):
  - `cartographer-frame-prototype` — Spike 1: visual feasibility — render pathological scenes, ship to glasses (parallel feasibility gate)
  - `navigate-foreground-service` — Spike 3: phone-side GPS endurance (parallel feasibility gate — either can kill the project)
  - `cartographer-routing-engine` — Spike 2: routing + scene-graph emission (gated on Spike 1 passing)
- **Resolution of `PANORAMIC_MAP decision` Parked item**: this architecture implements option 3 from that item ("build real local-surroundings line-drawing"), with the rendering lift offloaded to Deepthought. See updated Parked item.
- **Notes**: Google Maps notification path stays as fallback only. `cartographer` is a new Deepthought service, separate from Hermes. Keep separate from `navigate-cleanup` (tactical protocol cleanup, also in Now) — they remain deliberately parallel.

---

## Next — Prioritised

### cartographer-frame-prototype: Spike 1 — rendering feasibility: three pathological scenes
- **Status**: Next
- **Priority**: High — parallel feasibility gate; either this or `navigate-foreground-service` can kill the project
- **Effort**: ~1 day
- **Cross-ref**: `navigate-osm-research` (Now) — this is child spike 1; runs in parallel with `navigate-foreground-service`
- **Context**: Before building a routing engine, prove that the on-device primitive renderer can produce 488×136 monochrome frames that a human eye can parse in ~400 ms while walking — in real outdoor brightness conditions. The killer risk is not "can a rasteriser draw a line"; it is "can a stripped-back scene graph remain legible at this resolution, bit depth, and viewing angle". If it cannot, the vector scene-graph architecture is dead.
- **Spike scope**:
  - Author three small **vector scene-graph JSON files by hand** (dogfooding the cartographer output format before building the cartographer). Each represents a pathological scene:
    1. **Simple suburban turn** — one route line, one side-street, one junction dot.
    2. **Dense city junction** — route line, 4–6 cross streets, multiple junction markers; brutal suppression of everything else required.
    3. **Awkward walking path / alley / cut-through** — non-grid geometry, tight bend, possibly no named cross-streets.
  - Implement a primitive on-device line-segment + dot rasteriser (can be a standalone script or a throwaway Flutter widget) that reads the scene-graph JSON and emits a 488×136 monochrome bitmap. Heading-up / route-forward layout; no antialiasing.
  - Send all three frames to the glasses via the existing `PANORAMIC_MAP` (`0x0a`) opcode.
  - View **outdoors, in motion, in real brightness conditions.** The test is eye-parsing speed while walking, not pixel-perfect inspection on a monitor.
- **Acceptance**:
  - [ ] Three scene-graph JSON files authored for the three pathological scenes.
  - [ ] Primitive rasteriser converts each scene graph to a 488×136 monochrome PNG.
  - [ ] All three frames sent to glasses and viewed outdoors in real conditions.
  - [ ] Qualitative verdict per scene: legible / marginal / dead (with notes — what breaks, what reads well).
  - [ ] Overall verdict recorded: proceed to `cartographer-routing-engine` (Spike 2) if at least the simple scene reads; park the architecture if dense scenes are unreadable even with aggressive suppression.
- **Notes**: No OSM extract, PostGIS, or routing engine needed for this spike. The scene-graph JSON is hand-authored. This dogfoods the cartographer output format — the schema agreed here becomes the contract for Spike 2's scene-graph emission work. Rasteriser can be Cairo, Pillow, or a trivial custom implementation; the requirement is monochrome 1-bit output, no antialiasing.

### navigate-foreground-service: Spike 3 — phone-side GPS foreground service endurance
- **Status**: Next
- **Priority**: High — parallel feasibility gate; runs alongside `cartographer-frame-prototype`; either can kill the project
- **Effort**: ~1 day
- **Parallel with**: `cartographer-frame-prototype` (Spike 1) — both are feasibility gates; start this as early as Spike 1. `cartographer-routing-engine` (Spike 2) is separately gated on Spike 1.
- **Cross-ref**: `navigate-osm-research` (Now) — this is child spike 3
- **Context**: If Android won't give 1Hz-ish GPS for 30–60 minutes screen-off on real hardware, the whole navigate architecture is dead — and we want to know that as early as the rendering question. This is a structural platform constraint, not a nice-to-have. No routing, no glasses, no rendering — just prove the OS constraint is solvable.
- **Spike scope**:
  - Implement a foreground service with `FOREGROUND_SERVICE_TYPE_LOCATION` and a persistent notification.
  - Poll GPS at 1 Hz and log positions to disk (timestamp, lat, lon, accuracy).
  - Walk for 30+ minutes with the phone screen off and pocketed on real hardware (S24 Ultra).
  - Inspect the log for gaps, freezes, or service death.
- **Acceptance**:
  - [ ] Foreground service with `FOREGROUND_SERVICE_TYPE_LOCATION` implemented and declared in `AndroidManifest.xml`.
  - [ ] 1 Hz GPS polling active and writing to a local log file (timestamp, lat, lon, accuracy).
  - [ ] 30+ minute screen-off walk on S24 Ultra completed, phone pocketed throughout.
  - [ ] Log inspected; verdict recorded: continuous / intermittent / killed (with OS version, One UI version, and gap details).
  - [ ] If killed or severely intermittent: alternative mitigations noted (e.g. `WorkManager`, wakelock, partial wakelock, different service type declaration).
- **Notes**: No BLE, no glasses, no routing in this spike — the question is purely "can we hold ~1 Hz GPS for 30–60 min screen-off?" Android 12+ tightened `FOREGROUND_SERVICE_TYPE_LOCATION` constraints; Samsung One UI adds its own battery optimisation layer. Both must be satisfied. Do not bundle any other spike's work here.

### cartographer-routing-engine: Spike 2 — routing engine + scene-graph emission on Deepthought
- **Status**: Next
- **Priority**: High — gated on `cartographer-frame-prototype` (Spike 1) passing
- **Effort**: ~1–2 days
- **Blocked on**: `cartographer-frame-prototype` (Spike 1) passing — do not start until visual feasibility is confirmed
- **Cross-ref**: `navigate-osm-research` (Now) — this is child spike 2
- **Context**: Stand up a walking-profile routing engine on Deepthought, prove the maneuver data is good enough to replace Google Maps notifications, and add scene-graph emission — turning route + nearby PostGIS query into the simplified vector description the phone renderer consumes.
- **Spike scope**:
  - Install **both** Valhalla and GraphHopper on Deepthought as Docker images (cheap; both at once). Spike a real walk on each. Compare: maneuver quality (instruction text, advance distance), polyline shape, walking-specific weirdness (pedestrian-only paths, alley routing, stairways), and response payload size. Lean is Valhalla first (stronger narrative model for maneuvers), but **decide from your own routes, not docs**.
  - Expose an HTTP endpoint that accepts origin + destination and returns `{ polyline, maneuvers, scene_graph }` — the full cartographer response contract established by Spike 1.
  - **Scene-graph emission:** whichever engine wins, add the PostGIS step: query nearby OSM ways along the route corridor, apply brutal cartographic generalisation (keep route line + ~2–3 cross streets + junction markers, suppress everything else), and emit the simplified scene graph matching the Spike 1 schema.
  - Wire the phone app to call this endpoint at trip start: bind maneuver list to existing `0x0a` TRIP_STATUS fields; hand the scene graph to the on-device renderer (from Spike 1) to produce live panoramic frames.
- **Acceptance**:
  - [ ] Valhalla and GraphHopper both running on Deepthought via Docker.
  - [ ] Both engines spiked on the same real walk; comparison written up (maneuver quality, polyline, walking weirdness, payload size).
  - [ ] Engine choice recorded with rationale.
  - [ ] HTTP endpoint returning `{ polyline, maneuvers, scene_graph }` for a walking origin/destination pair.
  - [ ] Scene graph matches the schema agreed in Spike 1.
  - [ ] Phone binds maneuver list to `0x0a` TRIP_STATUS and advances through list during a short test walk.
  - [ ] Turn instruction visible and accurate on the glasses during the test walk.
  - [ ] Scene graph fed to Spike 1 renderer; panoramic frame visible in HUD during walk.
- **Notes**: `cartographer` is a Tailscale-reachable service, not part of Hermes. The HTTP endpoint from this spike becomes the backbone of the full `cartographer` service. Map-match corridor width and off-route hysteresis tunables (see `navigate-osm-research` design questions) are set during this spike — start generous.

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
- **Open decision from the firmware decomp (2026-09-07)** — read before starting. See `docs/firmware-decomp-notes.md` § "`0x06` has native structured widget types".
  - The firmware calls `0x1E` records **quick notes**, not dashboard slots. fahrplan's widget approach is a repurposing of the note store, and our packet reading of it is confirmed correct.
  - But `0x06` carries **firmware-native structured record types** that fahrplan does not use: `0x03` schedule/calendar (`schedule title` / `time` / `location` / `schedule_validity`, with record counts and multi-packet assembly), `0x04` stocks, `0x05` news, `0x07` citywalk. Calendar events are a first-class firmware record with a firmware-rendered layout.
  - **Our app already sends `0x06 0x03` on every connect** — with zero records. `Proto.setTimeAndWeather()`'s third frame (`06 0c 00 <seq> 03 01 00 01 00 00 00 01`) is an empty schedule push that we had mislabelled as a transaction "finalise" step. So the channel is already open.
  - **Decision needed**: does the today's-calendar widget go through `0x06 0x03` (firmware-native records, firmware layout, probably better-looking) or through `0x1E` note slots (fahrplan's proven path, full control of text)? Cheap way to settle it: fire one populated `0x06 0x03` schedule record on device and look at the dashboard. Do that before building `DashboardComposer`, because it changes the model shape.
  - Firmware-side reading if needed: `init_dashboard_info.c`, `DashBoard_Reflash.c`, `ui_DashBoard_task.c`, `setCalenadrIndex.c`.
- **Notes**: Supersedes the former `dashboard-injection` Backlog entry. Cross-ref `quicknote-dashboard-push` (Backlog) — that item pushes a completed QuickNote to a named slot; they share the `0x1E` byte format but are separate features. Decide at implementation time whether to fold `quicknote-dashboard-push` into this item or keep it as a follow-on. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / Render pipeline / 0x1E dashboard widgets" section. fahrplan source references: `models/g1/note.dart`, `models/fahrplan/fahrplan_dashboard.dart:147-183`, `bluetooth_manager.dart:806-822`.


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
- **Firmware-decomp input (2026-09-07)** — this item is now much cheaper than "Low priority, wire up a guess". Three sources agree on the field order (wiki, fahrplan, and the firmware parser's storage offsets), and **we are already sending all five trailing bytes as `00 00 00 00 02`**:

  | Offset | Field | Currently |
  |--------|-------|-----------|
  | `0x11` | weather icon | `0x00` |
  | `0x12` | temperature | `0x00` |
  | `0x13` | unit (C/F) | `0x00` |
  | `0x14` | 12/24-hour | `0x00` |
  | `0x15` | unknown; triggers a firmware redraw when changed | `0x02` |

  So the confirmation step is a probe, not an implementation: flip `0x11` and `0x12` on device and watch the native dashboard. No new packet, no new opcode. Also resolve `0x15` — the wiki has it as `0x00` and we send `0x02`, and it forces a redraw when it changes.
- **Notes**: Cross-ref `gadgetbridge-weather-receiver` (also Next, PR-B) which is the intended live data source. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / Render pipeline / 0x06 0x01 time-and-weather" subsection, and `docs/firmware-decomp-notes.md`.

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

### quick-ask-intermittent-capture-failure: Quick Ask — intermittent capture failure on consecutive asks
- **Status**: Backlog
- **Priority**: Medium
- **Context**: Left-hold Quick Ask intermittently fails after a preceding successful ask — the user is in listening state but never sees the "You said:…" transcript preview and no answer renders. The display either clears generically or stays blank. Pattern (observed 2026-05-27): the second consecutive Quick Ask fails; the first ask of a fresh session succeeds. Strongly implicates state/teardown not being reset cleanly between asks.
- **Log evidence** (GlanceAssistant tag, `logs/hermes.txt`): repeated `micOn failed`, `transport lost — flags cleared`, and `close -> cancel capture and clear` — the in-flight request is cancelled via a `requestVersion` bump before the transcript preview can show. No transcription or network errors in the logs. This is a BLE/gesture/capture-lifecycle issue, NOT a Hermes or network issue, and NOT related to `hermes-agent-v1`.
- **Likely root cause**: `GlanceAssistantService.startListening` (BleManager `startGlassesCapture` + `Proto.micOn`) and the teardown/reset path after a successful ask. The second `micOn` may be failing because the prior capture session or the `0x52` display surface was not fully released before the next mic start. Cross-ref `ChatService.startListening`, which has an explicit guard to exit any active `0x52` streaming surface (comment notes firmware needs `0x18` before mic audio routes correctly after a `0x52` session) — `GlanceAssistantService` may lack the equivalent guard. Also worth checking per-leg BLE capture state between asks.
- **Acceptance**:
  - [ ] Reproduce with fresh targeted logcat across two consecutive Quick Asks (first succeeds, second fails).
  - [ ] Identify whether the second mic start fails because the prior capture/`0x52` surface was not released.
  - [ ] Identify whether the per-leg BLE capture state is being reset between asks.
  - [ ] Add equivalent `0x52` surface-exit guard to `GlanceAssistantService.startListening` if missing (mirroring `ChatService`).
  - [ ] Confirm second consecutive ask succeeds reliably on device after fix.
- **Notes**: Related history — `ble-mic-on-reconnect-ghost` (Done 2026-05-13) fixed a different mic-start failure (ghost notification on single-leg reconnect); that fix introduced the flag-only `handleTransportLost()` teardown and is now stable. This item is a distinct failure mode: no reconnect event, in-session, triggered by consecutive asks. The `mic-right-side-only-spike` (Next, PR-C) may surface related mic routing behaviour — coordinate if that spike runs first.
- **Cross-ref (transport review, 2026-06-09)**: `_syncUnknownNotes` in `lib/ble_manager.dart` paces with fixed 2 s/3 s sleeps and no completion signal — timing-coupled in the same way and likely related. Investigate alongside the consecutive-ask teardown path.

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

#### BLE transport — robustness review findings (2026-06-09)

Source: production-robustness review of BLE transport and notification path, 2026-06-09. Files reviewed: `android/.../bluetooth/BleManager.kt`, `BleDevice.kt`, `BleChannelHelper.kt`, `QuickNoteAudioBuffer.kt`, `MainActivity.kt`, `CompanionForegroundService.kt`, `RecentNotificationsListenerService.kt`, `lib/ble_manager.dart`, `lib/services/proto.dart`, cross-checked against `docs/current-architecture.md`.

Items 1–2 were the top transport priorities; both shipped in the 2026-06-13 design pass (see Recently Done). Remaining open items follow.

### companion-lifetime-decision: Companion lifetime — design decision (Tier 1, decision gate)
- **Status**: Backlog
- **Priority**: Low (step 1 shipped; step 2 not yet prompted by field evidence)
- **Context**: Companion lifetime is Activity-scoped; the foreground service is a placebo. `connectGatt` uses Activity context; `reconnectLeg`/`checkBluetoothStatus` bail when `weakActivity` is gone; `CompanionForegroundService` hosts no BLE and no engine. Swiping the app from recents kills the engine while the persistent notification still claims "Companion mode active in background". **Confirmed in the field by Eddie**: swipe-kill loses all functionality while the notification persists.
- **Options**:
  1. Move BLE ownership to application context with the engine hosted service-side (full background-capable companion).
  2. Accept Activity lifetime and make the notification honest ("Tap to resume" rather than false "active in background" claim).
- **Decision (2026-06-09)**: Two-step path agreed.
  - Step 1 (immediate): Option 2 ships now as a standalone quick fix — `honest-foreground-notification`. Detects engine/activity death and updates `CompanionForegroundService` notification to reflect real state instead of falsely claiming "Companion mode active in background".
  - Step 2 (full): Option 1 (service-hosted BLE) is folded into a single design pass together with `ble-native-write-queue` and `ble-pending-gatt-leak`. All three restructure `BleManager.kt`'s ownership model and the file should not be refactored twice. The design pass covers all three items together; do not implement option 1 independently of that pass.
- **Acceptance**:
  - [x] Decision made and recorded — two-step path (2026-06-09).
  - [x] Step 1 delivered via `honest-foreground-notification` (Done 2026-06-13).
  - [ ] Step 2: BLE + engine moved to service context; `connectGatt` no longer uses Activity context; `CompanionForegroundService` is no longer a placebo. Gated on a future joint design pass.
- **Notes**: Step 1 is done. 4-hour field test on 2026-06-13 under the swipe-kill scenario revealed no new requirement to escalate to step 2 — the honest notification covers the UX problem adequately for now. Step 2 remains available if a genuine background-connectivity use case emerges (e.g. BLE must stay alive with the app backgrounded). Do not implement option 1 until that case is clear.

### heartbeat-suspend-is-noop: `suspendHeartbeats`/`resumeHeartbeats` is a no-op — wire or delete (Tier 1, small)
- **Status**: Backlog
- **Priority**: Medium
- **Effort**: ~1 h including doc fix.
- **Context**: `suspendHeartbeats`/`resumeHeartbeats` (`lib/ble_manager.dart:1682`) increment a depth counter that nothing reads; there are zero call sites in `lib/`. Additionally, `docs/current-architecture.md` falsely states that Navigate uses it during the 108-packet bootstrap burst — this is doc/code drift. During bootstrap, `0x25` heartbeats with 1500 ms timeouts contend with the packet burst today with no suppression.
- **Acceptance**:
  - [ ] Either wire it (timer checks depth, Navigate wraps the burst with `suspend`/`resume` calls) OR delete the dead code and correct `docs/current-architecture.md` to remove the false claim.
  - [ ] `docs/current-architecture.md` heartbeat-pause claim corrected either way.
  - [ ] If wired: Navigate bootstrap burst wrapped and no `0x25` heartbeat contention confirmed in logcat during an actual bootstrap.
- **Notes**: The false architecture doc claim is a guaranteed fix regardless of the wire-vs-delete decision. Small item — do not over-scope it.

### mtu-failure-fallthrough: MTU negotiation failure falls through to bond/ready (Tier 1, small)
- **Status**: Backlog
- **Priority**: Medium
- **Effort**: Small.
- **Context**: `onMtuChanged` (`BleManager.kt:465`) proceeds to bond/ready regardless of status. A failed negotiation leaves MTU at 23 bytes while the app sends 176–202-byte frames and receives 42-byte `0x21` frames; the fixed-offset parsers would misread frames after truncation.
- **Acceptance**:
  - [ ] MTU negotiation failure treated as setup failure.
  - [ ] Connection recycled (close + reconnect) when MTU negotiation fails.
  - [ ] No regression on the happy path — successful MTU negotiation proceeds to bond/ready as before.
- **Notes**: Straightforward defensive guard. No protocol changes.

### reconnect-strategy-consolidation: Consolidate competing reconnect systems (Tier 2)
- **Status**: Backlog
- **Priority**: Medium
- **Context**: Two competing reconnect systems exist with a coverage hole. Per-leg `autoConnect` reconnect vs full-session scan ladder (immediate/30/60/120 s, then gives up). Full disconnect with glasses away for more than ~4 minutes never recovers. The recovery scan is unfiltered + `SCAN_MODE_LOW_LATENCY`: Android 8.1+ suppresses unfiltered results screen-off, so the ladder cannot work from a pocket. `autoConnect` path never calls `stopScan` after connect (only the home-page UI does).
- **Acceptance**:
  - [ ] Persistent per-leg `autoConnect` pending connects used as the long-game recovery mechanism (depends on `ble-pending-gatt-leak` owned-state fix).
  - [ ] Scan used only for cold-start discovery, with a `ScanFilter` on the NUS service UUID / name prefix.
  - [ ] `stopScan` called on connect.
  - [ ] Away-for->4-minutes scenario recovers without user interaction.
- **Notes**: `ble-pending-gatt-leak` (the owned-state precondition) is now Done (2026-06-13) — this item is unblocked. Cross-ref `ble-stability-tier3` (reconnect tuning) which covers schedule widening.

### bond-pending-leg-ready: `markLegReady` fires while bond is pending (Tier 2)
- **Status**: Backlog
- **Priority**: Low
- **Context**: `markLegReady` fires while `BOND_PENDING`; initial heartbeat written before bond resolves; `bond_failed` legs still marked ready. Works only because G1 does not enforce encryption on those characteristics. A firmware update or stricter pairing policy could break this silently.
- **Acceptance**:
  - [ ] `markLegReady` gated on bond resolution — does not fire until `BOND_BONDED` (or `BOND_NONE` for unpaired operation).
  - [ ] `bond_failed` legs not marked ready; failure logged and connection recycled.
- **Notes**: Low-urgency hardening; current firmware tolerates it.

### notification-listener-rebind: Notification listener — silent death and battery-string false drop (Tier 2, cheap)
- **Status**: Backlog
- **Priority**: Low
- **Effort**: Cheap.
- **Context**: `RecentNotificationsListenerService` has no `onListenerDisconnected → requestRebind`; the listener can silently die and Glance goes quiet until the user toggles notification access. Additionally, `shouldIgnoreNotification` drops any notification whose title/text contains the substrings `"charging"` or `"battery"` — this will eat real messages containing those words; it should be a package-based rule in `NotificationPolicy` instead.
- **Acceptance**:
  - [ ] `onListenerDisconnected` implemented with `requestRebind(componentName)` call.
  - [ ] Battery/charging string filter moved to a package-based exclusion rule in `NotificationPolicy` (or removed if no longer needed).
  - [ ] Glance does not silently go quiet after listener disconnect; recovers automatically.
- **Notes**: Classic Glance-goes-quiet failure mode. The string-match filter is a latent correctness bug.

### lc3-hot-path-crash: `!!` NPE on bad LC3 frame in live mic path (Tier 2, cheap)
- **Status**: Backlog
- **Priority**: Low
- **Effort**: Cheap.
- **Context**: `Cpp.decodeLC3(lc3)!!` in `onCharacteristicChanged` (`BleManager.kt:518`) NPEs the app on one bad mic frame mid-capture. The `decodeLc3Frames` channel method already does skip-and-log; the live-mic path should match.
- **Acceptance**:
  - [ ] `!!` removed; null result from `Cpp.decodeLC3` handled with skip-and-log, matching the `decodeLc3Frames` pattern.
  - [ ] One bad mic frame does not crash the app or terminate the capture session.
- **Notes**: One-liner fix; high crash-safety value for minimal effort.

### rx-frame-guards: Unguarded RX frame indexing and double-subscribe risk (Tier 2, cheap)
- **Status**: Backlog
- **Priority**: Low
- **Effort**: Cheap.
- **Context**: Unguarded frame indexing: `_handleReceivedData` reads `res.data[0]`/`[1]` without length checks; `exit()` guards `isNotEmpty` then reads `[1]`; `_requestList` reads `resp.data[1]` bare. The RX stream subscription has no `onError` handler; double `startListening()` would double-subscribe.
- **Acceptance**:
  - [ ] A guarded frame-entry function (checks minimum length before indexing) used at all RX entry points.
  - [ ] RX stream `onError` handled (log + recover).
  - [ ] `startListening()` guarded against double-subscribe.
- **Notes**: Defensive hardening batch; each sub-item is a few lines. Group together for a single small PR.

### request-correlation-seq: Request correlation by (leg, opcode, seq) — fix collision risk (Tier 2)
- **Status**: Backlog
- **Priority**: Low
- **Context**: `request()` correlation is `(leg, opcode)` only; two in-flight same-opcode requests to one leg collide. Protocol sequence bytes are unused for correlation. Interim mitigation: per-leg TX mutex. Proper fix: match on seq byte.
- **Acceptance**:
  - [ ] Either: per-leg TX mutex preventing concurrent same-leg requests (interim); or correlation keyed on `(leg, opcode, seq)` (proper).
  - [ ] Two concurrent same-opcode requests to one leg do not corrupt each other's response.
- **Notes**: Low-frequency bug in current usage patterns, but correctness gap. Interim mutex is a cheap short-term fix.

### transport-honesty-smalls: Transport honesty — small correctness gaps batch (Tier 2)
- **Status**: Backlog
- **Priority**: Low
- **Effort**: Small batch.
- **Context**: Three small correctness gaps identified in the robustness review:
  1. `disconnectFromGlasses` (`BleManager.kt:253`) is a stub that disconnects nothing.
  2. `_recordLegAck` flips a leg back to connected/healthy on stray RX against native state.
  3. Pre-Tiramisu write branch in `BleDevice.sendData` never sets the characteristic value (latent bug, not triggered on S24U).
- **Acceptance**:
  - [ ] `disconnectFromGlasses` calls `gatt.disconnect()` / `gatt.close()` on each connected leg.
  - [ ] `_recordLegAck` cross-checks native GATT connection state before marking a leg healthy.
  - [ ] Pre-Tiramisu write branch sets the characteristic value before writing (matches the Tiramisu path).
- **Notes**: These can land as a single small PR. Item 3 is latent on the S24U but would bite on older devices.

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

#### App features — new captures (2026-06-20)

### hermes-quicknote-sync: Hermes bidirectional to-do list sync
- **Status**: Superseded by `hermes-dewire-chat`
- **Priority**: None
- **Context**: Superseded because Hermes is being removed as the app assistant backend. Keep this record only so the prior QuickNote integration idea is not rediscovered as active work.
- **Acceptance**:
  - [ ] Hermes can read the current to-do list from the app's local store.
  - [ ] To-do items created or checked off in Hermes are reflected back in the app's `NotesStore`.
  - [ ] Push cadence defined (on-change, on-interval, or both).
- **Notes**: If a future assistant needs QuickNote access, design a separate, explicit app-data contract. Do not revive the Hermes push/poll/socket proposal by default.

### battery-variance-spike: Battery status wild swings — spike
- **Status**: Backlog
- **Spike**
- **Priority**: Unprioritised
- **Effort**: Short investigation.
- **Context**: Battery percentage shows wild swings in practice — Eddie observed 95% → 55% → 95% in a single session (2026-06-20). Hypothesis: the G1 reports per-leg battery independently and the two legs can diverge substantially, causing apparent swings when the display alternates between or picks one leg's value.
- **Spike scope**:
  - Confirm whether the app is displaying left-leg, right-leg, or an alternating value.
  - Check whether left and right leg battery readings differ significantly in practice (log both values side-by-side).
  - Evaluate two display options: (a) show an average of the two legs; (b) show both values separately (e.g. "L: 95% R: 55%").
  - Recommend the better UX and implement it.
- **Acceptance**:
  - [ ] Root cause confirmed (per-leg divergence vs. firmware reporting artefact vs. other).
  - [ ] Display approach decided (average or dual).
  - [ ] Implemented and validated — no more wild swings visible in normal use.
- **Notes**: The dashboard `system-status` widget planned in `dashboard-widgets-v1` will also show battery; coordinate so both surfaces use the same resolved value.

### auto-brightness-spike: Auto brightness unreliable — spike
- **Status**: Backlog
- **Spike**
- **Priority**: Unprioritised
- **Effort**: Short investigation.
- **Context**: Auto brightness does not behave as expected. Eddie suspects you need to explicitly set brightness to 0 (or some low value) *and* set the auto-on flag together — having auto-on active while the app's manual brightness value is high seems to let the higher manual number win and override auto. Symptom: auto brightness appears to be ignored when a non-zero manual brightness is set.
- **Spike scope**:
  - Review the current auto brightness command sequence — what opcodes are sent, in what order, with what values.
  - Test whether sending brightness = 0 before setting auto-on changes behaviour.
  - Identify whether the firmware treats manual brightness as an override that must be cleared before auto takes effect.
  - Confirm working sequence on device.
- **Acceptance**:
  - [ ] Correct command sequence identified (auto-on + brightness interaction fully understood).
  - [ ] Auto brightness behaves reliably after fix — manual brightness does not silently override it.
  - [ ] Finding documented in `docs/protocol-reference.md` or `docs/current-behaviour.md`.
- **Notes**: If the firmware requires a specific ordering or a brightness = 0 pre-condition, that should be captured in the protocol reference so it does not have to be re-discovered.

#### App features - new captures (2026-09-07)

### recording-filename-seconds-resolution: Recording filenames collide within the same minute
- **Status**: Backlog
- **Priority**: Low
- **Context**: Both recorders (`GlassesCaptureRecorder`, via the shared `WavRecordingStore`, and the new `PhoneCaptureRecorder`) stamp filenames only to the minute (`Capture-yyyy-MM-dd-HH-mm.wav`), so two recordings started inside the same minute collide. MediaStore resolves the collision itself by appending a suffix such as `Capture-2026-09-07-14-32 (1).wav`, which then matches neither regex in `lib/models/recording.dart` - `prefix` falls back to the whole stem, `timestampSuffix` returns null, and the rename UI degrades to editing the entire filename instead of just the trailing timestamp. The risk pre-dates this session for back-to-back glasses captures, but adding a second mic source (`phone-local-capture`, Done 2026-09-07) makes the same-minute collision materially more likely.
- **Acceptance**:
  - [ ] Filename stamp widened to include seconds (e.g. `Capture-yyyy-MM-dd-HH-mm-ss.wav`) in `WavRecordingStore` and any remaining glasses-only formatting path.
  - [ ] `lib/models/recording.dart` parser extended to accept both the new seconds-resolution stamp and the existing minute-resolution stamp, so older files still parse correctly.
  - [ ] Two recordings started within the same minute no longer collide, and the rename UI correctly isolates the timestamp suffix for both old and new filename widths.
- **Notes**: Surfaced during `phone-local-capture` (Done 2026-09-07) and deliberately not bundled into that item, to keep it tight. Low priority - MediaStore's own de-dupe suffix means no data loss today, just a rename-UI degradation.

---

## Parked

### PANORAMIC_MAP decision
- **Status**: Parked — option 3 being resolved by `navigate-osm-research`
- **Context**: The 488×136 PANORAMIC_MAP region is shown in the glasses' "look up" mode and is a large piece of screen real estate. Previously the app sent a static capture taken from the official app during a previous route — misleading (not active to the user's actual location).
- **Three options (historical)**:
  1. Keep static forever (current behaviour — misleading) — rejected
  2. Generate a neutral placeholder (decorative, honest about not being a map) — **done** as part of Navigate cleanup composite (Now #4)
  3. Build the real local-surroundings line-drawing path — **in progress via `navigate-osm-research`**
- **Resolution (2026-06-20)**: Option 3 is being implemented via the thin phone + thick Deepthought architecture decided in `navigate-osm-research`. The `cartographer` service on Deepthought will render 488×136 monochrome frames from OSM data using Cairo, pre-rasterise them into a "map tape" keyed by position along the route, and serve the tape to the phone at trip start. The rendering lift (which made option 3 feel like a "big lift" previously) is offloaded entirely to Deepthought — the phone only indexes the cached tape. Route geometry is owned by the Valhalla/GraphHopper routing engine, not by Google Maps notifications (bypassing the "tiny cartography hell" constraint).
- **Remaining gate**: visual feasibility must be confirmed by `cartographer-frame-prototype` (Spike 1, Next) before the full implementation proceeds. If the HUD renders the frame as mush at 488×136 monochrome, this item will be re-parked at option 2 (placeholder remains as the permanent answer).
- **Constraint (updated)**: the "do not use Google Maps for route geometry" constraint still holds — `cartographer` derives geometry from OSM + routing engine, not from Maps notifications.

---

## Recently Done

### hermes-dewire-chat: Remove Hermes as the Even assistant backend (2026-09-07, working tree, uncommitted)
- **Status**: Done
- **Outcome**: Hermes fully retired as an app backend - the second-backend plumbing was deleted outright rather than repointed at a local model (see Decision below). `ChatBackendRouter` and `ChatRoute` existed only to make the Hermes-vs-OpenAI routing decision, so with Hermes gone there was nothing left for them to decide: `lib/services/chat_backend_router.dart` and `test/services/chat_backend_router_test.dart` were deleted outright, taking the health probe, fallback logic and routing-notice mechanism with them. `chat_service.dart` and `glance_assistant_service.dart` now hold a `ChatBackend` directly (defaulting to `OpenAiChatBackend`) instead of a router; constructor injection changed from `ChatBackendRouter? router` to `ChatBackend? backend`; the pre-flight routing phase and one-time notice display were removed from both, so Chat's numbered phase comments renumbered from 4 phases to 3. `assistant_backend_config.dart` lost `resolveHermes()` and the four `HERMES_*` dart-define constants; `profileLabel` was kept (it names the backend in error messages) but now only ever resolves to 'OpenAI'. `app_settings_store.dart` lost the `AssistantBackendKind` enum entirely, all five Hermes fields/getters, `saveHermesSettings`, `setAssistantBackend` and `setHermesFallbackEnabled`. Credential and settings cleanup shipped as a migration, not just a deletion: `_purgeRetiredHermesSettings` runs on every `AppSettingsStore.init()` and deletes the five retired SharedPreferences keys (`assistant.backend`, `assistant.hermes_fallback`, `assistant.hermes_base_url`, `assistant.hermes_chat_model`, `assistant.hermes_timeout_seconds`) plus the `assistant.hermes_api_key` secure-storage entry, idempotently - a device upgrading from a Hermes build does not keep a bearer token in its keystore for a service that no longer exists. `settings_page.dart` lost the whole Hermes section - backend segmented selector, fallback switch, URL/key/model/timeout fields, "Save Hermes", "Test connection" chip and the reachability chip widget - plus the four controllers and the `_parseTimeout` helper that only served it. `docs/hermes-api-tailscale-bind-brief.md` moved to `docs/archive/` with its retirement header updated; its worklist cross-reference (in the `hermes-agent-v1` Done entry, above) was repointed to the archive path. No `HERMES_*` dart-defines needed removing from README.md or scripts - they were never documented there.
- **Acceptance**:
  - [x] Remove `AssistantBackendKind.hermes`, the Hermes `OpenAiChatBackend` instance and Hermes fallback logic from `ChatBackendRouter` - done via outright deletion of the router and its test rather than a partial strip.
  - [x] Remove Hermes URL, API-key, model, timeout, selector, fallback and connection-test settings from the app UI and `AppSettingsStore`, including secure-storage cleanup/migration for `assistant.hermes_api_key` - `_purgeRetiredHermesSettings` runs idempotently on every `init()`.
  - [x] Remove Hermes-specific tests, build defaults and documentation that describe it as an active app dependency; retain the completed `hermes-agent-v1` record as historical context - `docs/hermes-api-tailscale-bind-brief.md` archived, not deleted.
  - [ ] Confirm both Chat and left-hold Quick Ask work over the direct OpenAI route on device, including a clean network failure - **outstanding, deliberately left unticked**. `flutter analyze` reports 0 errors (two pre-existing warnings, unrelated: `chat_service.dart` unused catch clause, `evenai.dart` unused field) and `flutter test` passes 7/8 (the one failure, `widget_test.dart` "app renders companion home screen", fails identically at HEAD and is unrelated); the debug APK builds. None of that is a device pass. Do not treat this criterion as met until Chat and Quick Ask have actually been exercised on the glasses over the direct OpenAI route, including a clean network-failure case.
  - [x] Mark `hermes-quicknote-sync` superseded - it has no valid backend once Hermes is retired. (Ticked previously.)
- **Decision recorded**: keeping the second-backend plumbing and repointing it at Ollama on Deepthought (`http://deepthought:11434/v1`, already tailnet-reachable and unauthenticated - no infrastructure work needed) was explicitly considered and rejected in favour of the full strip. Rationale unchanged from the item's original framing: a glasses assistant has different latency, reliability and credentials requirements than a coding assistant, and local-model access belongs in T3/OpenCode first. If a local backend earns its way in later it should be re-added deliberately behind a real wearable use case - re-adding is cheap since the router was a clean generic abstraction, so deleting it cost little optionality.
- **Notes**: Hermes the *service* is retired; the `deepthought` box is not - it now runs Ollama, T3 Code and a local OpenCode provider. Do not read this entry as deepthought having been decommissioned. Working tree, uncommitted.

### phone-local-capture: Phone-mic recording - capture without the glasses (2026-09-07, working tree, uncommitted)
- **Status**: Done
- **Context**: Eddie wants the recording feature available when he is not wearing the glasses - a button in the app that records through the same pipeline and stores to the same place. Explicitly scoped to the phone's own mic for now; Bluetooth headsets and external mics (e.g. something like a Pebble Index 01) are a later question, not in this pass.
- **Outcome**: `WavRecordingStore.kt` (new) extracts the WAV framing and MediaStore publishing out of `GlassesCaptureRecorder` so both mic sources emit byte-identical WAVs into the same folder; holds the fixed 16 kHz mono 16-bit format constants and `saveWaveToPublicRecordings`, with `GlassesCaptureRecorder` now delegating to it and keeping only its own 200 ms LC3 startup trim. `PhoneCaptureRecorder.kt` (new) is an AudioRecord-based recorder on the `VOICE_RECOGNITION` audio source, buffered at 4x the platform minimum, with a dedicated `phone-capture-read` thread at `THREAD_PRIORITY_URGENT_AUDIO`, writing PCM to a cache temp file and publishing through `WavRecordingStore`; teardown order is deliberate and shared between stop and cancel via one `teardownCapture()` (clear flag, `stop()` to unblock the pending read, join the thread, release, then close the stream); it passes no `skipBytes` since the glasses' LC3 trim artefact doesn't apply to AudioRecord. `PhoneCaptureService.kt` (new) is a foreground service typed `microphone`, live only for the duration of a recording - this is what keeps the mic working when the app is backgrounded or the screen locks. It is deliberately separate from `CompanionForegroundService` (typed `specialUse`, runs for the whole app lifetime) - folding the mic type in would hold a mic grant permanently and mean combining service types. Its notification carries a "Stop and save" action that routes back into Dart so the save path is shared with the in-app button, and uses Android's own chronometer (`setWhen` + `setUsesChronometer`) so the elapsed timer advances with no per-second work from the app. `AndroidManifest.xml` gained `RECORD_AUDIO` and `FOREGROUND_SERVICE_MICROPHONE`, and registered the new service. `lib/services/phone_capture_service.dart` (new) holds the Dart-side session state, runtime permission check/request, a 1 Hz in-app tick, and a typed `PhoneCaptureStartResult` so the UI can explain a refusal instead of showing a generic failure. New channel methods: `startPhoneCapture`, `stopPhoneCapture`, `cancelPhoneCapture`, `hasRecordAudioPermission`, `requestRecordAudioPermission`, plus the `phoneCaptureStopRequested` Kotlin-to-Dart callback. The home screen gained a "Phone recording" card with Record/Stop and a live timer, above the Recordings card; the Recordings card subtitle changed from "Captured audio from glasses mic" to "Captured audio from glasses and phone". Mutual exclusion runs both ways: `PhoneCaptureService.startRecording` refuses if a glasses capture is running, and `CaptureService.startRecording` refuses if a phone recording is running - the phone has one microphone, and the glasses paths (Capture, Chat, QuickNote, Quick Ask) all assume they own the audio session. Glasses HUD mirroring is gated on Capture mode being the active mode: in Glance, Chat or Navigate the active feature owns the `0x4E` surface, so pushing a REC line would fight the Glance carousel or a nav card - this respects the existing "mode ownership stays in CompanionController" guardrail.
- **Design decisions**:
  - Filenames are identical to glasses captures (`Capture-yyyy-MM-dd-HH-mm.wav`, same folder, same parser) - Eddie's explicit choice, on the basis that a recording is a recording and the source is not meant to be visible in the list. The considered alternative was a distinct prefix such as `Memo-`.
  - Phone audio format deliberately matches the glasses at 16 kHz mono 16-bit rather than using a higher phone-mic rate, because `Recording.duration` in Dart computes a fallback duration from file size at 32,000 bytes/second - a second sample rate would silently mis-report durations for any file MediaStore has not yet indexed.
  - Phone recording is not an `AppMode`: it has no gesture and no BLE dependency, and starts whether or not the glasses are connected - that is the whole point of it.
- **Verification state**: `flutter analyze` 0 errors, debug APK builds. **Device-verified 2026-09-07** on the S24 Ultra:
  - Record/stop/save, temp PCM cleaned up, `PhoneCaptureService` confirmed foreground with `types=0x00000080` (MICROPHONE) and notification id 4103 coexisting with the companion service's 4102.
  - Locked-screen and app-backgrounded capture: 13 minutes with the screen off produced 99.73% non-zero samples, peak at full scale, and no 30-second window quieter than -55 dBFS. Android substitutes exact digital silence when the foreground-service type is wrong, so a real noise floor is the proof that the mic stayed live.
  - MediaStore indexing alongside existing glasses captures with the correct `duration`, same filename pattern.
  - Notification chronometer advancing (`setWhen` + `setUsesChronometer`) with no app involvement.
  - First-run `RECORD_AUDIO` prompt: permission revoked, cold start, one tap on Record produced the prompt and recording started immediately on grant - confirming the held-open method-channel result fix.
  - Glasses HUD mirror in Capture mode, plus the phone-then-glasses mic exclusion: two tilt-ups both logged `Capture: start refused - phone recording active`, and the phone recording saved intact at 35 s. The gesture reached `CaptureService.startRecording` and was refused there, so the guard is load-bearing rather than the gesture being dropped.
  - The glasses-then-phone direction: starting a glasses capture by tilt-up greys out the phone Record button immediately, and it re-enables only after the glasses recording ends. Both directions of the mic exclusion now hold on device.
- **Still outstanding**: the notification "Stop and save" action tapped for real (the intent path is shared with the in-app button and `dumpsys` confirms one action attached, but adb cannot spoof the tap because the service is correctly `exported="false"`); and a long screen-off recording against Samsung's battery optimiser, since the app is on no allowlist. Note also that `VOICE_RECOGNITION` AGC clipped at full scale on loud nearby speech - fine for STT, worth a look if the audio needs to sound good.
- **Structural note (no action needed today)**: the phone card's enabled state reads `CaptureService.isRecording`, but `CaptureService` is not a `ChangeNotifier` and nothing listens to it. The UI stays correct because every path that mutates its recording flag runs inside a `CompanionController` method that calls `notifyListeners()` (both gesture dispatchers do), or sits alongside a `DeviceStatusService.reset()` on transport loss. Checked rather than assumed, and both observed transitions are covered. If a future entry point starts or stops a glasses capture outside those paths the button will go stale - making `CaptureService` a notifier is the fix at that point, not before.
- **Attribution**: `PhoneCaptureRecorder.kt` was generated by the local `qwen3-coder:30b` model via the local-dev agent against a specified interface, then reviewed and corrected. Two real bugs were caught in that review loop - release-before-join on the `AudioRecord` (a native use-after-free) and an ignored nullable `Uri` return that would have reported success with a path of "null". A further pass removed a spurious read-error log that fired on every stop, deduplicated ~40 lines between the stop and cancel teardown paths, and wrapped the unguarded `AudioRecord` constructor and stream close.
- **Notes**: Working tree, uncommitted. Cross-ref `recording-filename-seconds-resolution` (Backlog) - surfaced during this work and deliberately not bundled in, to keep this item tight.

### BLE ownership design pass: `ble-native-write-queue` + `ble-pending-gatt-leak` + `honest-foreground-notification` + `cold-connect-false-positive-reconnect` (2026-06-13, commits 7808f39 + c8d45e1, main)
- **Status**: Done
- **Outcome**: Four related fixes landed as a single BleManager.kt ownership design pass, field validated 2026-06-13 in ~4 hours of continuous use.

**`ble-native-write-queue`** — `GattWriteQueue.kt` (new file) implements a per-leg serialised write queue drained on `onCharacteristicWrite`, with a 500 ms watchdog fallback, bounded depth, busy-retries, and flush on disconnect. Method-channel `send` now resolves with the real write outcome rather than always `success(null)`. `BleDevice.writeRaw` replaces `sendData`, returning raw submit status; pre-Tiramisu branch now sets the characteristic value before writing (latent bug fixed, would have bitten on older devices). `BleManager.kt` `LOG_TAG` changed from `::class.simpleName` to a const string literal — R8 was tagging every native log line as `"k"` in release builds; this directly improves weekend debuggability for all three fixes above.

**`ble-pending-gatt-leak`** — At most one outstanding `BluetoothGatt` is held per leg. Pending reconnects are `close()`-d before issuing a new `connectGatt`; superseded instances are rejected at first callback; stale disconnects can no longer mutate live-leg state. Breaks the dropped-write → reconnect churn → GATT exhaustion cycle. Status 133 / GATT exhaustion provisionally resolved; multi-day cradle cycling is the remaining confirmation stress.

**`honest-foreground-notification`** — `engineAlive` flag in `BleChannelHelper`; `onTaskRemoved` (swipe-from-recents) swaps the notification to "Even Companion stopped — Tap to resume" (dismissible, no mode buttons), calls `stopForeground`+detach+`stopSelf`. Any service start without a live engine renders the stopped state. Confirmed by field test: swipe-from-recents shows "Tap to resume" rather than the "Companion mode active in background" placebo. Step 1 of `companion-lifetime-decision` is complete.

**`cold-connect-false-positive-reconnect`** (surfaced during device validation, commit c8d45e1 — not a pre-existing backlog item) — `_applyConnectionPayload`'s single-leg-disconnect branch was gating on bare `!state.connected`, which mistook a leg still mid-GATT-discovery for a dropped leg. Every cold connect was firing a spurious reconnect for the lagging leg. Fixed by gating on the connected→disconnected transition for the current payload. Confirmed by post-fix logcat: no `single-leg disconnect detected` line during cold connect.

**Field validation summary (2026-06-13, ~4 h continuous)**: no reconnect flash card observed, no silent death event, honest notification confirmed on swipe-kill. GATT leak fix provisionally working; strongest stress (multi-day cradle cycling) is the remaining gate.

---

### hermes-agent-v1: Hermes Agent — replace OpenAI direct with Hermes over Tailscale (2026-05-27, merge 642f19b, main)
- **Status**: Done
- **Outcome**: Both voice surfaces (tilt-up Chat mode and left-hold Quick Ask) route through the shared `ChatBackendRouter`; Hermes answers end-to-end from Deep Thought over Tailscale, device-verified 2026-05-27. Hermes self-identified as model `gpt-5.5` via `openai-codex` provider and reached `/vibe` meeting notes — confirming genuine Hermes tool access, not OpenAI direct. OpenAI fallback confirmed working in Chat mode with Tailscale down. Both sessions (Chat and Quick Ask) persist and are badged in the Chat Log via the unified `kind` column (`'chat'` / `'quick_ask'`). App Settings expose Hermes URL / key / model / timeout / backend selector / fallback toggle / "Test connection" chip. Hermes API key in Flutter secure storage (`assistant.hermes_api_key`). An earlier `/v1/chat/completions` 404 was a Hermes-side route issue (also broke OWUI), surfaced correctly by the app, resolved on the Hermes side — not an app bug.
- **Acceptance**:
  - [x] Left-hold Quick Ask sends prompt to Hermes and displays response on glasses. — device-verified 2026-05-27 (both surfaces).
  - [x] Existing OpenAI direct path still works as fallback when Hermes is unreachable. — confirmed with Tailscale down.
  - [x] App Settings expose Hermes URL / key / model configuration. — done; also timeout field, backend selector, fallback toggle, "Test connection" chip.
  - [x] Hermes response is short enough for glasses by default (glasses-native system instruction enforced). — reuses existing system prompt + length caps; renders fine.
  - [x] Network failure handled cleanly with user-visible fallback message. — "Hermes unreachable. Using fallback." notice confirmed.
  - [x] STT unchanged. — `AssistantBackendConfig.resolve()` kept as the OpenAI profile; STT + note-tidy untouched.
  - [x] API key stored in Flutter secure storage (not `SharedPreferences` or hardcoded). — confirmed.
- **Notes**: Diagnostic-logging enhancement (log request URL + Dio type + status on chat failures) was offered and parked — pick up if a 404 recurs after Hermes is healthy. V2 scope (session persistence via `/v1/responses`, Whisper-over-Tailscale STT) remains a future item. Cross-ref `docs/archive/hermes-api-tailscale-bind-brief.md` for infrastructure context (archived 2026-09-07 when the app-side route was removed).

### router-v1-chat-logging: Router v1 — Chat history logging (single feed, origin tag) (2026-05-27, merge 642f19b, main)
- **Status**: Done
- **Outcome**: All acceptance criteria delivered as part of `hermes-agent-v1`. Both Chat-mode and Quick Ask sessions persist in the Chat Log, distinguished by a `kind` column (`'chat'` / `'quick_ask'`) and badged in the Chat Log list on `home_page`. Eddie confirmed done 2026-05-27.
- **Acceptance**:
  - [x] All Quick Ask invocations (router-claimed and LLM-fallback) produce an entry in Chat history.
  - [x] Entry shows the question and the response.
  - [x] Origin tag (`Chat` / `Ask`) is visible per entry.
  - [x] Existing Chat entries unaffected.

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
  - Hermes dewire (`hermes-dewire-chat`) - **Done 2026-09-07, working tree uncommitted**; Hermes fully stripped (not repointed at a local model - see the Decision in Recently Done); analyze/test/build clean; on-device confirmation of Chat + left-hold Quick Ask over the direct OpenAI route, including a clean network failure, is still outstanding
  - Phone-local capture (`phone-local-capture`) - **Done 2026-09-07, working tree uncommitted**; new home-screen Record/Stop button using the phone's own mic, same pipeline and storage as glasses Capture; analyze/build clean but NOT device-verified (locked-screen/backgrounded case is the main risk); `recording-filename-seconds-resolution` (Backlog, Low) was surfaced by this work
  - Navigate `0x0a` cleanup (`navigate_service.dart`, `nav_icon_generator.dart`) — **Now #4 (in flight)**; startup robustness, EXIT/ARRIVED handling, replay scaffolding decision remain open; field extraction / time set / PANORAMIC_MAP placeholder done
  - Dashboard widgets v1 (`dashboard-widgets-v1`) — **Next #1 (Medium-high)**; first `0x1E` implementation; calendar events + system status widgets; PR-B
  - Router v1 (`router-v1-glance-handlers`) — **Next #2**; medium priority; fahrplan VoiceModule registry + STT noise filter now incorporated into `router-v1-glance-handlers`; PR-A (`router-v1-chat-logging` done — delivered by hermes-agent-v1)
  - BLE hardening (`heartbeat-retry-suppression`, `heartbeat-counter-echo-verify`, `mic-right-side-only-spike`) — Low priority, Next; small targeted fixes from comparison; PR-C
  - Honest foreground notification (`honest-foreground-notification`) — **Next (Medium)**; step 1 of the `companion-lifetime-decision` two-step path; standalone quick fix, no dependency on the joint BleManager.kt design pass; Codex brief available
  - BLE transport robustness (2026-06-09 review): items in Backlog under "BLE transport — robustness review findings"; `companion-lifetime-decision` decided 2026-06-09 (two-step path); Tier 1 high-priority items now are `ble-native-write-queue` + `ble-pending-gatt-leak` (joint design pass with service-hosted-BLE from `companion-lifetime-decision`; Codex briefs available) + `heartbeat-suspend-is-noop` + `mtu-failure-fallthrough`; Tier 2 items follow
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
