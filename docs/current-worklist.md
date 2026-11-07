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
- Chat mode works end-to-end with local whisper-server STT (deepthought) + OpenAI assistant responses, paced `0x52` streaming, host-managed scrolling
- Glance tap paging (2026-11-06): tilt-up opens the carousel on the tap-enabled `0x4E` surface; right tap next, left tap back, double tap closes; device-verified
- Navigate mode runs on the firmware `0x0a` card via `NavCardSession` (phase 6, device-verified 2026-11-07 on the walking navigator): packet-built boot, master-last maps, 5 s master SYNC keepalive with echo liveness, reconnect re-boot, ARRIVED/EXIT. Main path is the walking navigator (Google Maps share); the Google Maps notification fallback (blank maps, built-in arrow, TRIP_STATUS only) is rewritten but not yet device-tested
- Region sync (2026-11-07, [plans/region-sync.md](plans/region-sync.md)): multi-region `cartographer`, regions page, background builds with notifications, and a sync offer when a shared walk falls outside every region. Pinned: home and Prague
- Quick mode switching works from app UI and persistent notification
- Right-hold QuickNote: full pipeline live (gesture → LC3 decode → WAV → Whisper STT → GPT-4.1-mini tidy → local notes store → in-app UI). Phone-side keyboard add also live (FAB → category chips → multi-line text → same store); device-verified 2026-05-19.
- Per-leg link keepalive (`0x25` sub 4 is teleprompter app-sync, not a true heartbeat; the firmware needs any write within 30 s), independent per-leg start, parallel sends; reconnect logic exists
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
- Direct-OpenAI Chat/Quick Ask device pass - `hermes-dewire-chat` (Done 2026-09-07) removed the Hermes backend and its plumbing entirely. Device-verified 2026-09-08: Chat and left-hold Quick Ask both work end-to-end over the direct OpenAI route. The only fault hit during testing was an OpenAI 429 (account had run out of API credit), resolved by adding credit - not an app bug. Still outstanding: the clean-network-failure sub-case (glasses connected, network unreachable) has not yet been exercised.
- Phone-local recording on device - `phone-local-capture` (Done 2026-09-07) shipped a home-screen Record/Stop button using the phone's own mic, with a dedicated `microphone`-typed foreground service. Device-verified 2026-09-07: record/stop/save, the locked-screen and app-backgrounded case (13 minutes, 99.7% non-zero samples, no 30-second window below -55 dBFS), MediaStore indexing with correct duration, the first-run `RECORD_AUDIO` prompt starting on a single tap, the glasses HUD mirror in Capture mode, and both directions of the mic exclusion (phone-then-glasses refuses the tilt-up; glasses-then-phone greys the Record button out until the glasses recording ends). The notification's "Stop and save" action has since been tapped for real and confirmed working (2026-09-08). Still outstanding: a long (hour-plus) screen-off recording against Samsung's battery optimiser.

---

## Now / In Flight

Nothing in flight. The walking navigation work (plan phases 1-6 and region sync) is complete; its leftovers are in `navigate-v1-open-items` (Next).

---

## Next — Prioritised

### navigate-v1-open-items: Walking navigation v1 - leftovers after the plan closed
- **Status**: Next
- **Priority**: Medium (carried over from `navigate-cleanup`)
- **Context**: [plans/navigate-v1-cartographer.md](plans/navigate-v1-cartographer.md) (all six phases DONE 2026-11-07) and [plans/region-sync.md](plans/region-sync.md) (DONE 2026-11-07) own the design and history. This replaces the former `4. Navigate cleanup (composite)`, `navigate-cleanup` and `navigate-osm-research` items. Only the open edges are tracked here; the plan's "Open questions" section is the source.
- **Acceptance**:
  - [ ] **Fallback device test** - Google Maps notification fallback after the `NavCardSession` rewrite (boot with blank maps, TRIP_STATUS-only updates, reconnect via `resyncAfterReconnect()`, EXIT on notification removal) run on device during a live Maps navigation session.
  - [ ] **Startup robustness observation** - keep watching first-entry Navigate starts and degraded-leg recovery, and post-bootstrap behaviour on longer walks; the reconnect re-boot is verified on the walking navigator only.
  - [ ] **Roundabout exit mapping** - unit-tested only; check on a real route with a roundabout.
  - [ ] **Tile orientation hysteresis** (not blocking) - ask Codex for heading hysteresis in cartographer so consecutive tiles do not flip between north-south and east-west.
- **Notes**: Delegate any deepthought/cartographer change to Codex (box is Codex-owned). Cross-ref `docs/current-behaviour.md` (Navigate section) for what is verified.

### dashboard-widgets-v1: Dashboard widgets v1 - system status
- **Status**: Next
- **Priority**: Medium-high
- **PR group**: PR-B (Dashboard widgets v1)
- **Context**: fahrplan's entire app is built on `0x1E` dashboard notes — up to 4 firmware-native dashboard slots, each with title + body. They serialise every "widget" (calendar, waypoints, checklists, Träwelling, Home Assistant, custom WebViews) down to these slots and push them on a 1-minute sync tick. Their `models/g1/note.dart:18-107` documents the byte format with `Note.buildAddCommand()` and `buildDeleteCommand()`. We have had this opcode in the backlog with zero implementation — fahrplan proves the use case and the approach. Promoted from Backlog 2026-05-18 after fahrplan comparison confirmed viability.
  **Protocol**: `1e <len> 00 <seq> 03 01 00 01 00 <slot> 01 <title_len> <title> <body_len> 00 <body>`. Full field breakdown at `docs/protocol-reference.md` L444-462.
- **Scope for v1**:
  - Build `DashboardNote` model mirroring fahrplan's `Note` shape.
  - Build `DashboardComposer` that gathers up to 4 typed widgets and serialises to notes.
  - 60-second sync timer that pushes the current widget set. (fahrplan sync timer pattern: `bluetooth_manager.dart:806-822`.)
  - First concrete widget: **system status** (battery + connection + signal strength), using existing data sources.
  - **Scope update (2026-09-09)**: calendar integration is parked in `calendar-integration-outlook`. Eddie's only useful calendar is gated in Outlook on the phone. Calendar access is no longer a dependency of this item; existing weather and QuickNote widget work remains separate.
- **Acceptance**:
  - [ ] `DashboardNote` add/delete builder against `0x1E` byte format.
  - [ ] `DashboardComposer` produces up to 4 widget payloads.
  - [ ] 60-second sync timer pushes refresh.
  - [ ] System-status widget rendering.
  - [ ] Widgets visible on G1 dashboard at next tilt-up.
  - [ ] Note slots correctly deleted when widgets are dismissed or empty.
- **Protocol context from the firmware decomp (2026-09-07)**: see `docs/firmware-decomp-notes.md`, "`0x06` has native structured widget types". Calendar-specific rendering decisions below are parked with `calendar-integration-outlook` and do not block the system-status widget.
  - The firmware calls `0x1E` records **quick notes**, not dashboard slots. fahrplan's widget approach is a repurposing of the note store, and our packet reading of it is confirmed correct.
  - But `0x06` carries **firmware-native structured record types** that fahrplan does not use: `0x03` schedule/calendar (`schedule title` / `time` / `location` / `schedule_validity`, with record counts and multi-packet assembly), `0x04` stocks, `0x05` news, `0x07` citywalk. Calendar events are a first-class firmware record with a firmware-rendered layout.
  - **Our app already sends `0x06 0x03` on every connect** — with zero records. `Proto.setTimeAndWeather()`'s third frame (`06 0c 00 <seq> 03 01 00 01 00 00 00 01`) is an empty schedule push that we had mislabelled as a transaction "finalise" step. So the channel is already open.
  - **Parked decision**: if calendar integration resumes, compare one populated `0x06 0x03` schedule record with the `0x1E` note-slot path on device before choosing the calendar widget layout.
  - Firmware-side reading if needed: `init_dashboard_info.c`, `DashBoard_Reflash.c`, `ui_DashBoard_task.c`, `setCalenadrIndex.c`.
- **Notes**: Supersedes the former `dashboard-injection` Backlog entry. Cross-ref `quicknote-dashboard-push` (Backlog) — that item pushes a completed QuickNote to a named slot; they share the `0x1E` byte format but are separate features. Decide at implementation time whether to fold `quicknote-dashboard-push` into this item or keep it as a follow-on. Cross-ref: `docs/g1-companion-apps-comparison-notes.md` → "fahrplan / Render pipeline / 0x1E dashboard widgets" section. fahrplan source references: `models/g1/note.dart`, `models/fahrplan/fahrplan_dashboard.dart:147-183`, `bluetooth_manager.dart:806-822`.

### router-v1-glance-handlers: Quick Actions - local commands before the assistant

- **Status**: Next
- **Priority**: Medium (existing priority retained). Ships as one slice with `quick-actions-timers-reminders`; the WhatsApp follow-ons below are unprioritised.
- **PR group**: PR-A (Router v1 reference adoption)
- **Decision (2026-09-09)**: expand the existing router proposal into Quick Actions: Timer, Focus Timer, Reminder, WhatsApp Reply, Glance a list with Next/Previous/Done, and passive mode switching to Capture, Navigation or Chat. Favourite outbound messaging is a separate feasibility gate. Calendar commands are parked. These are actions within the existing app, not additional modes.
- **Routing**: left-hold Quick Ask still transcribes through local Speaches on Deepthought over Tailscale. Recognised commands execute on the phone; general questions continue to the existing OpenAI assistant. This is not offline voice recognition. Keep literal dictated message content separate from command normalisation. A recognised but incomplete or ambiguous action asks for clarification or cancels without changing state; it must not fall through to an AI answer that implies execution.
- **Command context**: Next, Previous and Done apply only to the displayed list item; Send applies only to a pending message preview. Cancel closes the pending action and Undo restores the last list completion. Allow controller-owned follow-up listening on these surfaces despite the existing visible-content Quick Ask guard. Incoming notifications must not silently change the target. Do not bypass microphone exclusion during either recording source.
- **Agreed first slice (2026-09-09)**: one router delivering list recall, timers, reminders and passive mode switches together. Read outstanding shopping/to-do items from the existing `NotesStore`, display an identified item, and support Next/Previous/Done with safe Undo. Switching mode calls `CompanionController`; selecting Capture does not start recording. Refuse a switch that would abandon a recording and retain the existing explicit stop/save flow. Voice switching while a mic is occupied is not promised. Timer, Focus and Reminder behaviour is specified in `quick-actions-timers-reminders` (Next, same slice): separate acceptance criteria, scheduled together.
- **Follow-on dependencies**: `whatsapp-notification-replies` and `whatsapp-favourite-outbound` use this router but sit outside the first slice. They have separate acceptance criteria and need not ship with it. Existing notification-only MediaHandler recall remains later scope: show full current track from existing notification state, no audio fingerprinting. `now-playing-mediasession` and `router-v1-shazam` remain separate work.
- **Open implementation choices**: final command grammar and whether commands require a `glance` prefix. The previous fuzzy-match threshold of 60 is superseded; fuzzy matching must not execute sends, completions or mode changes. Start with explicit phrases and contextual commands. The fahrplan `VoiceModule`/`VoiceCommand` registry remains a reference, not a requirement to port a framework or add a fuzzy-matching package. Assess STT noise rejection against the actual Speaches response; do not assume a confidence field or import untested thresholds that reject short commands such as "Done". An empty audio playback service is not a prerequisite for reading existing notification state.
- **Acceptance**:
  - [ ] On device, recognised commands take the local action route; a general question still reaches OpenAI after local STT. A failed STT call executes nothing.
  - [ ] Shopping/to-do recall reads the existing store, handles empty lists and boundaries, and displays the target clearly. Next/Previous/Done work while glancing; Done persists and Undo restores exactly that item.
  - [ ] Bare Done/Send outside their valid context and ambiguous action phrases cause no mutation or send. A new notification cannot redirect a pending command.
  - [ ] Capture/Navigation/Chat switches use controller ownership; Capture entry starts no recording, and active phone/glasses recordings cannot be abandoned or have their mic stolen.
  - [ ] Cancel, short follow-up speech and return to ordinary Glance are tested on the glasses. HUD output uses existing text layout and supported glyphs.
  - [ ] Timer, Focus and Reminder commands route through this same router; the slice is not complete until `quick-actions-timers-reminders` acceptance also passes.
- **References**: [comparison notes](g1-companion-apps-comparison-notes.md), fahrplan `lib/voice/module.dart`, `lib/voice/voicecontrol.dart` and `lib/voice/modules/{checklist,music,stop,waypoint,webview}.dart`. `router-v1-chat-logging` is already done.

### quick-actions-timers-reminders: Timer, Focus Timer and app-owned Reminder

- **Status**: Next - ships in the Quick Actions first slice with `router-v1-glance-handlers`
- **Priority**: Medium (same slice as `router-v1-glance-handlers`)
- **PR group**: PR-A (Router v1 reference adoption)
- **Depends on**: `router-v1-glance-handlers` command routing and controller-owned display restoration. Agreed 2026-09-09 to ship in the same slice, not as a later increment; the 2026-09-09 grooming pass split them and that split was wrong.
- **Scope (2026-09-09)**: "Timer for ten minutes" displays a countdown that incoming notifications may cover, then restores the correct remaining time. "Focus for 25 minutes" adds suppression of ordinary glasses interruptions for that duration. "Remind me in an hour to call Paul" saves the text and surfaces it when due; support explicit relative/absolute times without calendar access. Cancel and remaining-time queries are supporting commands.
- **Boundaries**: deadlines run independently of display visibility. Focus changes this app's glasses interruptions, with phone notification/DND changes outside this scope. Ending or cancelling Focus restores the prior glasses policy. Decide overlapping timers, reminder delivery during Focus, urgent-call exceptions and mode conflicts before implementation; suggested exceptions are not settled policy.
- **Firmware note (2026-11-06)**: the firmware has a native countdown, `0x07`, but on 1.66 it renders garbled digits and a Chinese end string (device-tested). Timers stay app-drawn. See `firmware-mod-spike`.
- **Acceptance**:
  - [ ] On device, a normal notification covers a timer and dismissal restores a countdown based on the original deadline. Switching mode or disconnecting the glasses does not reset it.
  - [ ] Focus suppresses ordinary glasses notifications and restores the previous policy on expiry/cancel. Exercise the chosen call/reminder exception policy explicitly.
  - [ ] A reminder retains its dictated text and confirmed due time. Ambiguous times do not silently schedule; cancel removes the selected reminder.
  - [ ] Timer expiry and reminders are tested with the phone locked/backgrounded. Persist deadlines and document/test process restart, reboot and disconnected-glasses delivery behaviour before calling the feature complete.

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

### capture-meeting-cue-cards: Prepared meeting points attached to a recording

- **Status**: Backlog
- **Context (2026-09-09)**: Eddie usually records in-person meetings. Add optional typed/pasted title and points to cover when entering Capture, with no compulsory preparation before recording. Snapshot those points into the recording's metadata for either mic source, so preparation remains available afterwards.
- **Behaviour**: tilt-up during an active Capture session recalls a short cue card with a recording indicator; tilt-down or a timeout returns to the recording HUD. Repeated tilt-up recalls the same card without advancing an agenda. Start with a short card and no pagination. When a phone recording is active and Capture is the selected mode, recall its cues instead of attempting to start the glasses mic. Phone recordings in other modes must not take over their display.
- **Dependencies and boundaries**: stable recording identity/metadata association in the shared recording store; do not key notes solely by the mutable filename (see `recording-filename-seconds-resolution`). Keep gesture decisions in `CompanionController`. Preserve double-tap stop/save for glasses Capture and existing phone stop controls; this item does not assign double-tap to phone recording.
- **Acceptance**:
  - [ ] Recording starts with or without prepared points; its saved snapshot survives app restart and recording rename for both mic sources. Metadata share/delete behaviour is decided and documented before implementation.
  - [ ] On device, tilt-up recalls cues during glasses recording and during phone recording with Capture selected; tilt-down/timeout restores REC. Continuous audio is verified across these interactions, with no second mic start.
  - [ ] Ordinary head movements do not advance or complete points; the recording HUD cannot overwrite a cue card prematurely. Existing stop/save behaviour remains intact.
- **Later candidate**: match prepared questions against a post-recording Whisper transcript, linking answered questions to passages and marking unanswered ones. This depends on transcript linkage below and is not a cue-card prerequisite.

### whatsapp-notification-replies: Dictate and confirm a reply to WhatsApp

- **Status**: Backlog
- **Depends on**: `router-v1-glance-handlers` and a device spike retaining/invoking a usable WhatsApp notification reply action from the Android listener.
- **Scope (2026-09-09)**: WhatsApp first, as this is almost all of Eddie's reply use. While a message is selected, dictate a reply, display the recipient/conversation and exact text, then require explicit Send or Cancel. Preserve literal text; no AI rewriting. Bind the draft to that notification/conversation even if another message arrives.
- **Acceptance**:
  - [ ] Prove the notification reply route on Eddie's Samsung, then send a dictated reply with the phone locked and in a pocket; verify receipt in the intended WhatsApp conversation.
  - [ ] No send occurs before explicit confirmation. Cancel, stale/missing reply actions, incoming messages during dictation and repeated confirmation do not send to the wrong chat or send twice.
  - [ ] UI distinguishes hand-off to WhatsApp from independently confirmed delivery. Existing notification browsing/dismissal still works.
- **Later compatibility**: WhatsApp Business, then possibly Teams; each requires its own notification-action test. Native Gemini integration is not a prerequisite.

### whatsapp-favourite-outbound: Message a saved favourite without a notification

- **Status**: Backlog - feasibility gate
- **Context (2026-09-09)**: frequent hands-busy action: "Send a message to wife that says XXX". Configure one alias, probably "wife", against a specific WhatsApp contact. Keep this separate from notification replies: there may be no existing message to reply to.
- **Depends on**: a proven outbound route plus `router-v1-glance-handlers` and the recipient/text preview with explicit Send/Cancel. Reuse reply preview handling if available, without assuming its notification action can start a conversation.
- **Acceptance**:
  - [ ] Identify and prove a route that sends to the configured contact with the phone locked and in a pocket, with no existing WhatsApp notification. Verify receipt; document the route and limitations before scheduling implementation.
  - [ ] A click-to-chat/`wa.me` prefill that still needs phone interaction does not pass the feasibility gate. An unproven route remains blocked on evidence, not described as supported.
  - [ ] Alias resolves only to the saved contact; preview shows that person and exact dictated text. No contact guessing, AI rewriting or sending before explicit confirmation. Cancel and repeated confirmation are safe.
- **Scope**: one favourite first. More contacts and WA Business/Teams outbound support are later decisions.

### capture-bookmarks-transcript-links: Mark recording moments and find them afterwards

- **Status**: Backlog - later Capture work
- **Context (2026-09-09)**: make long recordings easier to revisit using elapsed-time markers and post-recording Whisper transcripts. Use the same stable recording metadata association as `capture-meeting-cue-cards`; cues themselves are not required for a bookmark.
- **First interaction**: Mark moment on the phone recording UI and foreground notification for both mic sources, without touching the active audio stream. A later option is finding explicitly spoken phrases such as "bookmark that" in the completed transcript and linking the preceding context. This does not require live STT or a second microphone session.
- **Gesture gate**: tilt-up is reserved for cue recall during Capture and double-tap retains glasses stop/save. Right-hold remains firmware QuickNote. Left-hold is only a feasibility candidate: test continuous audio and firmware overlays before assigning any bookmark meaning; it is not known to be a spare button.
- **Acceptance**:
  - [ ] Phone/notification markers persist their elapsed times against the right recording through rename and app restart for both mic sources; on-device audio remains continuous.
  - [ ] Post-recording transcript/audio view can jump to a marker and surrounding context with verified timestamp alignment. Decide how existing machine-side Whisper output enters this view before implementing transcript ingestion.
  - [ ] If a glasses gesture is pursued, document device evidence for audio continuity and firmware behaviour first; retain the phone marker path if no suitable gesture exists.
- **Later candidate**: cue-question-to-transcript matching from `capture-meeting-cue-cards`, with evidence links and unanswered questions retained. No new general-purpose personal-memory service is required.

### stt-temp-wav-leak-on-failure: Temp WAV not deleted when transcription fails
- **Status**: Backlog
- **Priority**: Low
- **Context**: `GlanceAssistantService._deleteTempFile(filePath)` is only called after `_transcriptionService.transcribe(filePath)` returns successfully (`lib/services/glance_assistant_service.dart:146`). Every catch handler returns without deleting, so a failed transcription leaves its WAV in `cache/chat-temp/` permanently. Confirmed on device 2026-09-08: a 310 KB `chat_20260907_161352.wav` from the previous day's failed Quick Ask was still present and was removed by hand. Chat mode and QuickNote share `OpenAiTranscriptionService` and should be checked for the same gap. Fixing this means a failed transcription cleans up its temp WAV, so repeated failures cannot grow the app's cache without bound.
- **Acceptance**:
  - [ ] Temp WAV is deleted on the failure paths as well as the success path, in Quick Ask, Chat mode and QuickNote.
  - [ ] Deletion cannot mask the original error - the exception still propagates and still logs.
- **Notes**: Android will reclaim the cache directory under pressure, so this is untidiness rather than a real leak, but it grows silently and the files are user audio. Surfaced while diagnosing the OpenAI 429 - the orphaned WAV is actually what proved the capture pipeline was healthy and the fault was the HTTP call, so the behaviour has some accidental diagnostic value worth preserving deliberately if anyone fancies a debug-only retention flag.

### quicknote-manual-add-voice: QuickNote — voice add from the phone app (nice-to-have)
- **Status**: Backlog
- **Priority**: Low
- **Context**: Follow-on to `quicknote-manual-add` (Done 2026-05-19). Now that keyboard-based manual add has shipped, a natural extension is allowing the user to dictate a note from the phone app itself (microphone → STT → save), without needing the glasses at all. Explicitly not bundled with the keyboard-add item — keep `quicknote-manual-add` tight.
- **Acceptance**: User can record a note by voice from within the phone app; result saved to the same store as keyboard-add and glasses-captured items.
- **Notes**: Depends on the shipped `quicknote-manual-add` staying stable. STT path is already proven (Whisper via QuickNote pipeline); question is whether to reuse that path or invoke Android's built-in speech recognition for the phone-local case.

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
  - [ ] `requestConnectionPriority(HIGH)` added during nav-card sessions and `0x52` streaming sessions; returns to `BALANCED` when done.
- **Notes**: Much less urgent now that tier-2 heartbeats have significantly improved stability. Touches `lib/ble_manager.dart` (Flutter side) and `BleManager.kt` (native side for connection priority). Depends on Tier 2 being in place before adjusting detection thresholds.

#### Protocol research and hardening

### protocol-0x22: Reverse-engineer 0x22 dashboard/status family
- **Status**: Backlog
- **Priority**: High
- **Context**: `0x22` is known to exist and appears tied to dashboard state. Payload semantics remain mostly unresolved — a protocol blind spot.
- **Acceptance**: Field structure decoded. Payloads correlated against dashboard visibility, pagination, unread counts, widget selection, notification state. Determination made on whether `0x22` supports firmware UI awareness, dashboard sync, or richer glance integration.
- **Notes**: Understanding firmware-side dashboard state may reduce future UI conflicts and reduce the need for speculative sequencing hacks.

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

#### App features - new captures (2026-09-07)

### back-press-hero-race: Red screen on back press during a route transition
- **Status**: Backlog
- **Priority**: Low
- **Context**: Seen 2026-11-07 on device. A back press while a page transition was in flight threw `Cannot get renderObject of inactive element` from `HeroController._maybeStartHeroTransition` via `NavigatorState.maybePop`; the debug build showed the red error screen and the next back press left the app. No app frame in the stack, so it is a timing issue in how a page pops (likely a `Navigator.pop` racing a push, or a `GlobalKey` reused across routes).
- **Acceptance**:
  - [ ] Reproduce (rapid back during a push or pop from the home page) and find the route that owns `RepaintBoundary-[GlobalKey]`.
  - [ ] Back press during a transition no longer throws.

### reconnect-attempt-while-bt-off: First reconnect attempt fires while Bluetooth is off
- **Status**: Backlog
- **Priority**: Low
- **Context**: BT off/on test 2026-11-07: auto-reconnect attempt 0 fired immediately while the adapter was off, so the first real attempt was attempt 1 at +30 s; both legs were back ~22 s after BT came on. Listening for `BluetoothAdapter.ACTION_STATE_CHANGED` -> `STATE_ON` and retrying then would cut that to a couple of seconds.
- **Acceptance**:
  - [ ] A reconnect attempt runs on adapter `STATE_ON`, not only on the backoff schedule.
- **Notes**: Fold into `reconnect-strategy-consolidation` or `ble-stability-tier3` if either starts first.

### recording-filename-seconds-resolution: Recording filenames collide within the same minute
- **Status**: Backlog
- **Priority**: Low
- **Context**: Both recorders (`GlassesCaptureRecorder`, via the shared `WavRecordingStore`, and the new `PhoneCaptureRecorder`) stamp filenames only to the minute (`Capture-yyyy-MM-dd-HH-mm.wav`), so two recordings started inside the same minute collide. MediaStore resolves the collision itself by appending a suffix such as `Capture-2026-09-07-14-32 (1).wav`, which then matches neither regex in `lib/models/recording.dart` - `prefix` falls back to the whole stem, `timestampSuffix` returns null, and the rename UI degrades to editing the entire filename instead of just the trailing timestamp. The risk pre-dates this session for back-to-back glasses captures, but adding a second mic source (`phone-local-capture`, Done 2026-09-07) makes the same-minute collision materially more likely.
- **Acceptance**:
  - [ ] Filename stamp widened to include seconds (e.g. `Capture-yyyy-MM-dd-HH-mm-ss.wav`) in `WavRecordingStore` and any remaining glasses-only formatting path.
  - [ ] `lib/models/recording.dart` parser extended to accept both the new seconds-resolution stamp and the existing minute-resolution stamp, so older files still parse correctly.
  - [ ] Two recordings started within the same minute no longer collide, and the rename UI correctly isolates the timestamp suffix for both old and new filename widths.
- **Notes**: Surfaced during `phone-local-capture` (Done 2026-09-07) and deliberately not bundled into that item, to keep it tight. Low priority - MediaStore's own de-dupe suffix means no data loss today, just a rename-UI degradation.

### back-during-transition-red-screen: Red error screen when pressing back during a page transition
- **Status**: Backlog
- **Priority**: Low-medium
- **Effort**: Small investigation
- **Context (2026-11-07)**: During the 2026-11-07 device session (see the progress log in `plans/robustness-smalls.md`), pressing Android back while a page route transition was still running showed the Flutter red error screen `Cannot get renderObject of inactive element`, thrown from `HeroController`. Eddie triggered it by pressing back while doing something else in the app. It is a debug-build assertion; a release build would show a grey/blank frame or nothing. Unrelated to the robustness branch. An earlier `debugNeedsLayout` red screen after a reinstall (2026-11-06) may be the same family; this link is unconfirmed.
- **Acceptance**:
  - [ ] Reproduce: back press mid-transition on the affected route. Identify which navigator push is involved and whether a Hero widget is in play (grep `lib/views`).
  - [ ] Fix, e.g. guard the pop, remove or tag the Hero, or avoid a nested navigator.
  - [ ] No red screen on repeated quick back presses during transitions.
- **Notes**: Check whether the 2026-11-06 `debugNeedsLayout` report shares a cause before closing; do not assume it does.

---

## Parked

### firmware-mod-spike: Custom app-core firmware (single tap under `0x71`, Even AI flash, `0x07` digits)
- **Status**: Parked 2026-11-06 - stock-protocol wins first
- **Context**: `JohnRThomas/even_realities_decomp` branch `1.66_exact` rebuilds byte-identical to v1.66 via `exact_build_1_66/build_repro.sh`. The app core is signed with MCUboot's public default RSA-2048 key, and MCUmgr SMP over BLE is unauthenticated, so a modified app image would be accepted. The net core uses the vendor's b0n key and cannot be changed (not needed). Three one-line candidates: forward single taps outside `0x5x` surfaces; make the `0x18` teardown for modes `0xb`/`0x10` reset the screen id (the Even AI flash path, `exit_running_task_keep_status` at `src/ble/ble_proto.c:2896`); pass character codes rather than raw digits to `font_ascii_get_glyph` in `src/notify/ui_countdown.c` so the native `0x07` timer renders.
- **Risk**: MCUboot is built `CONFIG_BOOT_UPGRADE_ONLY` (overwrite, no revert). An image that boots but breaks BLE or SMP can only be recovered over SWD. Build only via `build_repro.sh` with the vendor SDK patches (a plain `west build` behaves differently, including ESB taking MPSL's interrupt); leave BLE, ESB and mcumgr untouched; run every image in `JohnRThomas/Even-G1-Simulator` (Renode) first; flash one lens at a time. Unchecked: whether the official Even app would overwrite custom firmware, and whether a modded lens tolerates a stock partner over ESB.
- **Unpark when**: the Glance tap surface (`single-tap-0x5x-adoption`, shipped 2026-11-06) proves insufficient for other modes, or the Even AI flash becomes worth a firmware fix (it is closed as not fixable host-side, see `FINDINGS-evenai-flash-on-clear.md`).

### calendar-integration-outlook: Calendar actions and meeting-linked reminders

- **Status**: Parked (2026-09-09)
- **Reason**: Eddie's only useful calendar is his work calendar, gated in Outlook on the phone. Calendar integration is out for now. The former router CalendarHandler, today's-calendar dashboard widget and calendar/person/location-triggered reminder ideas are excluded from current Quick Actions scope.
- **Revisit condition**: Eddie chooses to reopen calendar access and a usable permitted route to the relevant events is established. Then revisit Android Calendar Provider availability and the `0x06 0x03` versus `0x1E` schedule rendering decision recorded under `dashboard-widgets-v1`.
- **Unaffected**: app-owned timed reminders, manually prepared meeting cues, system-status and weather widgets.

### live-transcription: Live captions during conversations

- **Status**: Parked (2026-09-09)
- **Reason**: Eddie liked the original app's live transcription but gets better results recording and transcribing later through Whisper on his machine. Prioritisation remains with post-recording use; this discussion does not commission a new live-transcription mode.
- **Revisit condition**: a specific live need and an on-device latency/audio-quality experiment justify reopening it. `capture-bookmarks-transcript-links` captures the useful post-recording extension.

### ideation-2026-09-09-undecided: Ambient-recall ideas raised and never discussed

- **Status**: Parked (2026-09-09) - no decision taken either way
- **Reason**: raised in the 2026-09-09 ideation session and never picked up in the conversation. Neither accepted nor rejected. Recorded here so they are not silently lost, and so they are not rediscovered later as new ideas.
- **Ideas, with the smallest useful version of each**:
  - **Remember this place** - save a cafe, a parking spot or somewhere worth returning to. Spoken label plus the phone's location; recall by name.
  - **Journey card** - keep the next train, platform, hotel address or booking reference to hand while travelling. Manually prepared cached text first; live updates later.
  - **Return-to-task prompt** - recover concentration after a call or interruption. Save "I was doing X, next step is Y" and recall it afterwards.
  - **Practice prompts** - rehearse a talk or drill vocabulary while walking. Short question cards, answers revealed on request.
- **Overlaps to check before reviving any of them**: `capture-meeting-cue-cards` already builds prepared-card display and recall; a Journey card or practice card may be the same surface with different content. `router-v1-glance-handlers` already builds Next/Previous/Done over a list, which is the interaction Practice prompts needs.
- **Revisit condition**: the next ideation pass, or once Quick Actions v1 is in daily use and the following increment is being chosen. Decide then; do not treat continued silence as rejection.

---

## Recently Done

Entries older than about 7 days live in [worklist-history.md](worklist-history.md).

### robustness-smalls: LC3 null decode, listener rebind, MTU failure, dead heartbeat suspend, auto brightness (2026-11-07, branch `robustness-smalls`)
- **Outcome**: Closes `lc3-hot-path-crash`, `notification-listener-rebind`, `mtu-failure-fallthrough`, `heartbeat-suspend-is-noop` and `auto-brightness-spike`. Device-checked: capture saves, a "battery" message reaches Glance while the charging card stays hidden, BT off/on reconnects both legs. Brightness: the manual level is a floor under auto, so turning auto on now sends level 0 (`Proto.brightnessPayload`) and the slider is disabled under auto. One capture run froze the HUD at 00:00 (master R stopped acking mid-recording); not reproduced, not tracked. Plan: [plans/robustness-smalls.md](plans/robustness-smalls.md).

### single-tap-0x5x-adoption: Glance tap paging on the tap-enabled `0x4E` surface (2026-11-06, commits 22280ce + 3f6f5d2, main)
- **Outcome**: Right tap next, left tap back, end card, double tap closes; deferred phone dismissals; device-verified on S24 Ultra, fw 1.6.6. Full record in `worklist-history.md`.

### navigate v1: cartographer spikes and walking navigator (2026-11-06 to 2026-11-07, main)
- **Outcome**: `cartographer-frame-prototype`, `navigate-foreground-service`, `cartographer-routing-engine` completed as plan phases 2, 3, 4 (gates B and C passed, cartographer live on deepthought); phase 5 walking navigator (8bd9b45, live walk passed); phase 6 `NavCardSession` and de-replay (365ab6b, council review approved). Plan: [plans/navigate-v1-cartographer.md](plans/navigate-v1-cartographer.md). Closed with it: `4. Navigate cleanup (composite)` and `navigate-cleanup` (leftovers now in `navigate-v1-open-items`), the PANORAMIC_MAP decision (resolved by cartographer tiles), `navigate-osm-research` (superseded by the hybrid architecture, 2026-06-20 decision record in `worklist-history.md`).

### region-sync: Multi-region cartographer, regions page, sync offer (2026-11-07, commits a99fbc7 + 465df5f, main)
- **Outcome**: Plan [plans/region-sync.md](plans/region-sync.md) DONE; pinned regions home and Prague.

### BLE hardening items closed as moot or already done (2026-11-07)
- **Outcome**: `heartbeat-retry-suppression` and `heartbeat-counter-echo-verify` closed as moot (`0x25` sub 4 is teleprompter app-sync; link liveness is any write within 30 s - AGENTS.md). `protocol-0x4e-header-docs` closed: the 9-byte header, `screenStatus` bits, `MAX_CHUNK_SIZE` and multi-page note are already in `protocol-reference.md`. `g1-font-table-memory-refinement` closed: the target memory file no longer exists and the glyph table was ported with `pixel-aware-0x4e-wrapping`. `per-leg-render-silent-degradation` and `evenai-flash-fix` (both 2026-09-08) moved to `worklist-history.md`; two deferred evidence checks from the former are not scheduled.

### decomp-1.66-fixes: Re-base on the `1.66_exact` firmware source; four protocol fixes (2026-11-06, branch `decomp-1.66-fixes`)
- **Outcome**: Docs re-based onto named, byte-identical firmware source (`1.66_exact`, `435c138`); raw Ghidra names replaced throughout. Four fixes in `lib/services/proto.dart`: (1) Chat `0x53` keepalive now `53 06 00 <seq> 03 00` - the bare byte failed the length check and never reset the firmware's 30 s transcribe timeout; **device-confirmed** (both legs reply `53 07 00 <seq> 03 c9 00`, Chat reply held over 60 s untouched); (2) `0x4E` text capped at 480 bytes on a UTF-8 boundary (firmware reassembly buffer has no bounds check); (3) `0x50` sent to R only on clear, streaming init and nav bootstrap (stripped from the replay list and sent once to R); (4) time sync sends only the `06 01` record - the two frames around it persisted the dashboard layout every minute; **device-confirmed** ack `06 16 00 <seq> 01 00` on both legs. Also added a debug-only adb protocol probe (AGENTS.md § "Debug protocol probe").
- **Device findings the same day**: single taps forward under `0x5x` (now `single-tap-0x5x-adoption`); `0x3F` readbacks work (`3f08` -> `00`, head-up mic not disabled; `3f05` -> `05`; `3f07` -> `00`); no head-up `F1` audio seen in Glance; native `0x07` countdown renders garbled digits and is unusable (see `firmware-mod-spike`).
- **Not done**: removing `0x50` entirely; master-only SYNC at ~5 s for Navigate; single-packet `0x52` (`total=1`). All source-backed, none device-tested.

### nav-0x50-necessity: Is `0x50` required before `0x0a` INIT and `0x52`? (closed 2026-11-06)
- **Outcome**: Answered by the named source rather than a device A/B: no. `0x50` is a dashboard-state probe - it arms a 1 s window in which the master pushes `50 06 00 00 01 01|02` if the dashboard is up (`src/ble/ble_proto.c:3933-3958`, `src/dashboard/dashboard.c:1635-1646`) - and neither the `0x0a` INIT handler nor `0x52` reads the lock bits. Device run 2026-11-06 saw the `50 06 00 00 01 01` push from R. The app now sends it to R only; full removal is a small follow-up to do with the next Navigate device session.

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
    - `NavCardSession` boot: `0x18`, INIT, maps sent master last, SYNC
    - master-only `SYNC` keepalive every 5 s with echo-based liveness
    - `TRIP_STATUS` updates, then ARRIVED (walking navigator) and EXIT
  - **`0x1e` TX dashboard data slots** — pushes titled content into the
    firmware's grid layout. Enables companion-app quicknote and dashboard
    injection features.
  - **`0x50` dashboard lock** — observed before entering streaming text or
    navigation card mode. Originally recorded as "display mode control /
    primes the display"; corrected 2026-09-08 from the firmware source — it is
    master-only and does not touch the display.
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
  - Hermes dewire (`hermes-dewire-chat`) - **Done 2026-09-07, commit 4bb6c46**; Hermes fully stripped (not repointed at a local model - see the Decision in Recently Done); analyze/test/build clean; Chat + left-hold Quick Ask confirmed working on device 2026-09-08 over the direct OpenAI route (an OpenAI 429 hit during testing was a credit issue, resolved, not an app bug); the clean-network-failure sub-case is still outstanding
  - Phone-local capture (`phone-local-capture`) - **Done 2026-09-07, commit 74b0960**; new home-screen Record/Stop button using the phone's own mic, same pipeline and storage as glasses Capture; device-verified 2026-09-07/08 including both directions of the mic exclusion and the notification's "Stop and save" action; only a long screen-off recording against Samsung's battery optimiser remains outstanding; `recording-filename-seconds-resolution` (Backlog, Low) was surfaced by this work
  - STT is now local (`stt-local-whisper`, Done 2026-09-08) - Quick Ask, Chat and QuickNote transcribe via the self-hosted whisper-server on deepthought over Tailscale, no fallback; the reasoning call for Chat and Quick Ask still goes to OpenAI, unchanged
  - Walking navigation (`lib/services/walknav/`, `nav_card_session.dart`, cartographer on deepthought) - **plan DONE 2026-11-07** (phases 1-6 and region sync); leftovers in `navigate-v1-open-items` (Next): Google Maps fallback device test, startup-robustness observation, roundabout check, tile heading hysteresis
  - Dashboard widgets v1 (`dashboard-widgets-v1`) — **Next (Medium-high)**; first `0x1E` implementation; system-status widget, calendar scope parked in `calendar-integration-outlook`; PR-B
  - Router v1 (`router-v1-glance-handlers`) — **Next**; medium priority retained; Quick Actions scope updated 2026-09-09: first slice is contextual lists, timers, reminders and passive mode switches through one router (`quick-actions-timers-reminders` is Next and ships with it), with WhatsApp replies as a separate Backlog slice; favourite outbound messaging needs a locked-phone/no-notification feasibility test; PR-A (`router-v1-chat-logging` done)
  - BLE hardening (`mic-right-side-only-spike`) - Low priority, Next; PR-C (`heartbeat-retry-suppression` and `heartbeat-counter-echo-verify` closed as moot 2026-11-07)
  - BLE transport robustness (2026-06-09 review): remaining items in Backlog under "BLE transport - robustness review findings"; `companion-lifetime-decision` step 1 shipped and the write-queue / pending-GATT / honest-notification pass is Done (2026-06-13); Tier 1 items closed by `robustness-smalls` (2026-11-07); Tier 2 follow
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
