# Worklist history

Archive of completed work from `docs/current-worklist.md`. Items here have been completed and remain in the historical record but are no longer part of the live worklist. Newest first.

The live worklist keeps the most recent ~7 days of completed work for quick "what just shipped" context. Older entries are archived here when that window grows beyond a comfortable size.

Conventions:
- Entries are date-stamped at the title line, matching the format used in the live worklist.
- Where commits are referenced, the SHA is included so git log can be cross-referenced.
- Files-changed lists are preserved verbatim from the worklist at the time of archive.

---

## 2026-11-07 — navigate-cleanup-composite: 4. Navigate cleanup (composite) (closed 2026-11-07, phases 5-6 of the nav plan)

- **Status**: Closed 2026-11-07 - remaining open edges moved to `navigate-v1-open-items` in the live worklist
- **Context**: Navigate is functionally working on the `0x0a` structured-card path. Phase 6 of the nav plan (2026-11-07) removed the replay scaffolding and added liveness, reconnect re-boot and ARRIVED/EXIT; the fallback device test is the main thing still open.
- **Acceptance** — all of the following:
  - [ ] **Startup robustness** — keep observing first-entry Navigate starts, especially cases where one leg begins degraded or reconnecting. Idle prompt is now suppressed; verify no regressions. Phase 6: reconnect re-boot verified on the walking navigator (8 s Bluetooth drop, 2026-11-07); still open for the Google Maps fallback path.
  - [x] **Field extraction cleanup** — fix `turnDistance` being populated with road text such as `towards Milton Rd` or `Home (36 Campbell Rd)`. Tighten the Google Maps notification parsing model.
  - [x] **Proper EXIT / ARRIVED handling** - done in phase 6 (2026-11-07): `NavCardSession.arrived` / `exit`; walking navigator sends ARRIVED then EXIT on arrival (device-verified), fallback ends with EXIT when Google Maps removes its notification (no ARRIVED, not yet device-tested).
  - [x] **Replay scaffolding decision** - removed in phase 6 (2026-11-07): `nav_replay_data.dart`, the 108-packet replay, the generated `MAP_OVERVIEW` arrow and the notification-PNG icon conversion are deleted; the fallback uses blank maps and the firmware's built-in arrow.
  - [ ] **Fallback device test** - Google Maps notification fallback after the `NavCardSession` rewrite (boot with blank maps, TRIP_STATUS-only updates, reconnect via `resyncAfterReconnect()`, EXIT on notification removal) has not been run on device.
  - [x] **Time set (0x06 01)** — periodic epoch-time push from the app to the glasses. The glasses use this for both the navigation HUD clock and the firmware dashboard. Wire format per JohnRThomas wiki: `06 16 00 <seq> 01 <epoch32> <epoch64_ms> <weather_icon> <temp_c> <c_f_flag> <24h_flag> 00`. Start with time-only; weather fields can be zeroed initially.
  - [x] **PANORAMIC_MAP placeholder** — replace the misleading static map capture (488x136) with the smallest viable neutral placeholder image. This is option 2 from the Parked PANORAMIC_MAP decision item. The placeholder should be honest about not being a real map — single-colour fill or minimal grid.
- **Firmware-decomp input (2026-09-07)** — `docs/firmware-decomp-notes.md`. Three things land on this item:
  - **TRIP_STATUS field model was wrong.** `y` is a `uint16` (offsets 8-9), not a byte plus a null separator, and the first string starts at offset 10. Our captured prefix `01 03 c8 00 12 00` re-reads as direction=Right, x=200, y=18. Corrected in `docs/protocol-reference.md` and `docs/FINDINGS-layouts.md`. Check `navigate_service.dart` against the corrected table before any further dynamic-field work.
  - **Field size caps are hard.** 24 / 24 / 64 / 24 / 24 bytes for `time_remaining` / `remaining_kilometers` / `road_name_info` / `remaining_distance_info` / `current_speed`. Exceeding one **aborts the whole packet** rather than truncating — a plausible cause of any "renders nothing" case with a long road name. Same for bytes 1-2: if the declared length does not match the actual packet length, the firmware drops it silently.
  - **`spec_ble_command_hook.c` is an on-device nav simulator.** The firmware can synthesise `BLE_REQ_PUT_NAVIGATION_INFO` payloads from cJSON with no phone attached. If it is reachable over a normal BLE session (unknown), it is a much better way to isolate rendering bugs than replaying 108 packets. Worth 30 minutes before the replay-scaffolding decision.
- **Notes**: Cross-ref `docs/FINDINGS-layouts.md`, `docs/firmware-decomp-notes.md`, `lib/services/navigate_service.dart`, `lib/services/nav_card_session.dart`, `lib/services/nav_manoeuvre.dart` (was `nav_icon_generator.dart`). See the related Parked item on PANORAMIC_MAP.

---

## 2026-11-06 — single-tap-0x5x-adoption: Use single taps now that `0x4E` status `0x5x` forwards them (2026-11-06, commits 22280ce + 3f6f5d2)
- **Status**: Now - Glance implemented and device-verified 2026-11-06 on branch `glance-tap-paging`
- **Implementation (2026-11-06)**: `GlanceCarousel` (pure paging + deferred dismissal, 18 unit tests), `Proto.isTapSurfaceOpen` / `isInSelfCloseWindow`, `TextService.startSendText(tapSurface:)`, `G1TextLayout.evenAiLayoutWidth`, `F5 01` routed to `CompanionController` when Even AI is not running. Decisions taken without a device: an end card after the oldest notification (right tap or tilt-up there closes); repeated tilt-up advances like a right tap, so the old wrap-around for protected items is gone; a new notification while the recall is up does not move the user; an update to the item being read follows it to the front.
- **Device results (2026-11-06, S24 Ultra, fw 1.6.6)**: tilt-up opens on both lenses (one "Even AI Listening" flash), right tap next, left tap back, end card, extra right tap closes, double tap closes, tilt-down timeout closes, read notifications dismissed on the phone together at close (three in one close), call HUD unaffected, every self-inflicted `F5 00` ignored. One bug found and fixed: the pin sent ~300 ms after the open was lost on the left (slave) lens, which stayed on "Even AI Listening"; `TextService` now waits 1 s between open and pin. Not yet checked: tilt-up over a live auto-pop, the 400-width wrap on a long notification, Even AI flash rate on close.
- **Device checklist (original)**: tilt-up from idle opens cleanly (one "Even AI Listening" flash); tilt-up over an auto-pop (`0x31` over `0x71`) opens cleanly and any `F5 00` is ignored; R/L taps page and wrap to 400-width lines; end card then close; double tap closes and dismisses the read notifications on the phone; tilt-down timeout still closes; left tap returns to a paged-past item before close; call HUD and media line unaffected; Even AI flash on close no worse.
- **Priority**: High - removes the biggest input constraint the app has been designed around
- **Effort**: ~1 day design + implementation, plus a device session
- **Context**: Device run 2026-11-06 (S24 Ultra, fw 1.6.6) confirmed that with a `0x4E` surface sent with status `0x51` (twice), single taps reach the phone as `F5 01`, tagged with the lens tapped (R, R, L, L in four taps). Under our usual `0x71`, on the dashboard and when idle they stay firmware-only, which is why every earlier test said "absorbed". Source: `src/threads/threads.c:2225-2262` in the `1.66_exact` decomp. Full status-nibble table in [protocol-reference.md](protocol-reference.md) § `0xF5 0x01`.
- **Recipe (`Confirmed` on device 2026-11-06)**: open with status `0x31`, pin by re-sending the same page with `0x51`, page with `0x51` updates, close on `F5 00` (double tap), tilt-down or timeout. Clean layout, no auto-dismiss once pinned, `F5 01` tagged L/R, clean page swaps. `0x51` from idle draws nothing, and `0x71` then `0x51` overlays two layouts - do not use either. Full detail in [protocol-reference.md](protocol-reference.md) § "Recipe: tap-enabled text surface".
- **Costs to design around**:
  - "Even AI Listening" entry screen flashes once per open (not per page)
  - text area is 472 px (x 88-560) instead of 576; `G1TextLayout` needs a second wrap width, and long notifications gain a line
  - our own `0x18` (and sometimes a render) makes the right lens emit `F5 00`; every mode treats that as close, so ignore `F5 00` briefly after our own renders and clears
  - a mis-hit double tap arrives as `F5 01` then `F5 00`
- **Glance design (agreed 2026-11-06)**:
  - tilt-up opens the carousel on the tap-enabled surface (tilt-up advance stays as a fallback)
  - right tap = "read, next"; left tap = back
  - phone dismissals are deferred: notifications paged past are marked pending and only dismissed on the phone when the carousel closes (double tap, tilt-down or timeout), so left tap can genuinely go back within a session. Protected and ongoing notifications are never dismissed, as today
  - closing the carousel commits the pending dismissals - the same "read it, it's gone" behaviour as tilt-up then tilt-down today
- **Other candidate uses**: Quick Actions Next/Done on a displayed list item (`router-v1-glance-handlers`), dismissing a Chat reply.
- **Acceptance**:
  - [ ] Glance carousel uses the open/pin/page recipe; right tap advances, left tap goes back, tap semantics live in `CompanionController` (mode ownership stays there).
  - [ ] Phone dismissal deferred to carousel close; left tap can return to a notification paged past in the same session.
  - [ ] Self-inflicted `F5 00` after our own render or clear does not close the surface; a real double-tap close still works.
  - [ ] `G1TextLayout` wraps to the 472 px Even AI layout for these surfaces.
  - [ ] Even AI flash on open and on clear judged acceptable on device, or mitigated.
  - [ ] AGENTS.md trusted-behaviour, `current-behaviour.md` and `even-g1-event-mapping.md` updated with the shipped behaviour.

---

## 2026-11-06 — navigate-osm-research: Navigate mode - architecture decision and spike plan (superseded 2026-11-06 by plans/navigate-v1-cartographer.md)
- **Status**: Now
- **Research** — decision reached 2026-06-20; now gating child spikes
- **Context**: The dashboard layout and HUD structure work well. The problem is data quality. The current approach — pulling turn instructions from Google Maps notifications — does not surface the next turn instruction reliably, breaks with the screen off, and provides no map geometry for the panoramic-map or mini-map regions.
- **Hard constraints** (any viable approach must satisfy all four):
  1. **Next turn displayed reliably** — the current Google Maps notification approach does not surface the next instruction dependably; the replacement must.
  2. **Map line-drawing** — renders a line-drawing of the map into the panoramic-map region (488×136) of the HUD; mini-map (136×136) shows the derived maneuver direction icon.
  3. **Walking / pedestrian directions** — this is a walking use case; routing quality for pedestrians is a first-class criterion.
  4. **Screen-off operation** — the current notification approach degrades or breaks when the phone screen is off; the replacement must work reliably with the screen off.
- **Superseded 2026-11-06**: the firmware decomp showed `TRIP_STATUS` `pos_x`/`pos_y` moves a marker over the panoramic map without resending it, and `direction` selects built-in arrows. The plan is now deepthought pre-rendered route-forward tiles + phone-driven marker; see [plans/navigate-v1-cartographer.md](plans/navigate-v1-cartographer.md). The June decision below is kept for history.
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
  - **Destination entry:** decided 2026-11-07 - Google Maps share only, no in-app picker (see the nav plan). Original note: architecture currently ignores how the user starts navigation. Options: share-destination intent from Google Maps, voice destination via existing assistant/quick-ask path, recent/favourites. Worth a follow-on sub-spike once core nav works.
  - **Map-match corridor width and off-route hysteresis:** tunables to be set during the routing-engine spike; default to generous (>15 m corridor, >10 s sustained off-route) until walking data says otherwise.
- **Child spikes** (cross-ref entries in Next):
  - `cartographer-frame-prototype` — Spike 1: visual feasibility — render pathological scenes, ship to glasses (parallel feasibility gate)
  - `navigate-foreground-service` — Spike 3: phone-side GPS endurance (parallel feasibility gate — either can kill the project)
  - `cartographer-routing-engine` — Spike 2: routing + scene-graph emission (gated on Spike 1 passing)
- **Resolution of `PANORAMIC_MAP decision` Parked item**: this architecture implements option 3 from that item ("build real local-surroundings line-drawing"), with the rendering lift offloaded to Deepthought. See updated Parked item.
- **Status note (2026-11-07)**: phases 1-5 done; phase 6 (protocol hardening and de-replay) code done and desk-verified on the walking navigator, with the fallback device test and the plan's cross-model review still open. The plan file owns phase status.
- **Notes**: Google Maps notification path stays as fallback only. `cartographer` is a new Deepthought service, separate from Hermes. Keep separate from `navigate-cleanup` (tactical protocol cleanup, also in Now) — they remain deliberately parallel.

---

## 2026-09-08 — per-leg-render-silent-degradation: Single-leg render silently reports success as a clean two-leg run (2026-09-08)
- **Status**: Done
- **Priority**: High - this is a correctness-of-observability bug on the daily-use display path, and it silently produced a broken user experience that the app reported as a success.
- **Cross-ref**: `transport-honesty-smalls` and `ble-stability-tier3` (both Backlog, BLE transport family) - this belongs to that family but should not be folded into either, because it has its own reproduction and its own firmware-decomp investigation angle.
- **Context - what happened**: Device-observed 2026-09-08. Eddie ran a Chat-mode question on the glasses. The response rendered in the right eye only; the left eye showed nothing. He initially assumed a fleeting glitch. The logs say otherwise: the app logged a completely clean run - `render queue: display complete, words=124/124`, `assistant reply sent -> chars=785, turns=2`, keepalives sent on schedule, then a clean `session reset`. No leg error, no write failure, no reconnect, nothing at warn or error level. The transport reported total success while one eye was blank.
- **Context - the mechanism, established by code reading**: `BleManager._targetLegsForBroadcast()` at `lib/ble_manager.dart:1235`:
  ```dart
  final healthyLegs = ['L', 'R'].where((lr) => legState(lr).isHealthy).toList();
  if (healthyLegs.isNotEmpty) {
    return healthyLegs;
  }
  return ['L', 'R'].where((lr) => legState(lr).isAvailable).toList();
  ```
  If only one leg is healthy, `healthyLegs` is a single-element list, which is `isNotEmpty`, so broadcast targets that one leg. Every downstream success check then passes trivially because there is only one leg to satisfy: `requestList`'s `rets.every((result) => result)` around `lib/ble_manager.dart:1197-1211`, and `sendBoth`'s `allSucceeded` accumulation around `lib/ble_manager.dart:1073-1090`. Net effect: a one-eyed render returns `true` all the way up, and nothing is logged at any level. This is the only path that produces the observed symptom without a log line - a genuine write failure to a leg the app still considered healthy would have hit the `else` branch and logged `requestList: per-leg request failed` at error level, and it did not.
- **Framing for whoever picks this up**: the single-leg fallback is probably correct behaviour and should most likely be kept. During a reconnect, rendering to one eye beats failing outright. The defect is that it is silent - it violates the repo's own guardrail that `AppLog.info` / `AppLog.error` cover state changes and error paths. Do not "fix" this by making a degraded broadcast fail; fix the honesty.
- **Firmware-decomp answers (2026-09-08, commit f37f182, `docs/firmware-decomp-display-relay.md`)**: the four open questions are now settled from the firmware source. The diagnosis above is confirmed; two of my original three hypotheses were wrong and are corrected here rather than deleted, so nobody re-runs them.
  1. **CONFIRMED - the host must write display content to both legs.** `0x4E` *is* in the `master_process_put_req` forwarding subset, but its case body reads zero bytes of the request payload: it pokes state and returns `0xC9`. No text crosses. `0x52` sits in the accepted `0x47`-`0x56` range but falls to `default: return 0`, a silent no-op. `0x06`, `0x0A` and `0x1E` are absent from the subset too, so dashboard, navigation-card and note pushes are equally host's-responsibility-to-both-legs. What the inter-leg link actually carries is semantic state with change detection (`sync_to_slave.c` over ESB, not SPI; `slave_display_thread.c` reacting to wake reasons and index syncs) and each lens re-renders locally. So the fix belongs in the leg-targeting logic exactly as filed - there is no upstream relay to lean on.
  2. **WRONG, corrected - we are not discarding a render-status byte, and our ack handling is already right.** Byte 2 of the `4E C9 <seq> <total> <final>` frame is an echoed `textSeqNum`, not a received-vs-rendered discriminator. The real signal is byte 1: `0xCB` means "chunk accepted, more expected" and `0xC9` means "final chunk accepted". Our code already matches that - `_requestList` accepts both `0xc9` and `0xcB` for the non-final packets (`lib/ble_manager.dart:1226`) and `sendBoth` requires `0xC9` for the last one (`:1088`), which is the correct split. Nothing to fix here. Note the trap for future work though: anything that treats non-`0xC9` as failure on a chunked send will fail every intermediate chunk.
  3. **NEW - byte 2 is directly useful to `request-correlation-seq`.** The echoed `textSeqNum` is exactly the correlation token that item wants. Bytes 3-4 (total chunks, final chunk index) are zeroed on read, so they are one-shot.
  4. **NEW and load-bearing - the legs are not interchangeable, and left-only is the worse degradation.** Master advertises as `_R_`, non-master as `_L_` (`bt_start.c`), so **left is the slave**. On the final chunk the master stashes counters and returns 0 with no synchronous reply, deferring to the `0xF2` event path - so the deferred `4E C9 ...` completion frame is **master-only**. A right-only write fails to propagate text to the left lens; a left-only write does that *and* misses the completion-event path entirely. Consistent with the observed symptom: the reply appeared in the right eye, meaning broadcast had degraded to the master leg alone. `_targetLegsForBroadcast` currently treats L and R as symmetric, which this says is wrong.
  5. **NEW - there is a real per-lens verification primitive.** `0x39` (system status) is answered from local state with no `spim_transfer` relay call, unlike `0x29`/`0x2A`/`0x2B`/`0x37`, so it describes the lens you asked. It returns the current running app / screen id, `0x00` when idle, `0xFF` on a declared-length mismatch. This is the closest thing in the protocol to "what is this lens showing" and the only readback that would let the host verify a display push instead of trusting a GATT ACK. Caveat: the screen ids are not yet enumerated (they are compared against `0x00`, `0x04`, `0x06`, `0x07` and `0x09`-`0x14` across six firmware files), and that enumeration is a prerequisite for using it as a verification signal.
  6. **Still worth ruling out.** Bytes 1-2 are a little-endian total length the firmware validates, dropping the packet entirely on mismatch. Per-packet rather than per-lens, so it does not explain a one-eyed render on its own, but it is the other known silent-drop path here.
- **Latent risk surfaced by the same read (may deserve its own item)**: `requestList` sends the final packet via `sendBoth(lastPack, timeoutMs: timeoutMs ?? 250)`, and on the master leg the final-chunk ack is *deferred* to the `0xF2` event path rather than replied inline. That 250 ms budget therefore has to cover an asynchronous completion event on one leg but a synchronous reply on the other. It evidently usually holds, but it is an asymmetric timing dependency nobody designed on purpose.
- **Acceptance**:
  - [x] Determine whether `0x4E` / `0x52` are in the `master_process_put_req.c` inter-leg forwarding subset. - Answered 2026-09-08: `0x4E` yes but carries no payload, `0x52` no. Host must write both legs. Recorded in `docs/firmware-decomp-display-relay.md` §1.
  - [x] Determine what the `<state>` byte in the `<opcode> C9 <state>` ack means for `0x4E`, and whether it can report a render failure. - Answered: echoed sequence number, not a render status. Our `0xC9`/`0xCB` handling is already correct. `docs/firmware-decomp-display-relay.md` §2.
  - [x] `_targetLegsForBroadcast` logs at info or error whenever it returns fewer than two legs, naming which leg was dropped and its state, so a degraded render is never silent again. - Done 2026-09-08: `Transport: degraded broadcast` names selected and dropped legs, plus each dropped leg's connection, health, heartbeat and reconnect state.
  - [x] A single-leg render is distinguishable from a two-leg render in the logs without verbose logging enabled. - The info-level degradation line is emitted once per broadcast-target selection.
  - [x] Stop treating the two legs as interchangeable: if broadcast must degrade to one leg, prefer the master (`R`) and say so, since left-only additionally loses the master-only completion-event path. - Done 2026-09-08: healthy two-leg sends retain the proven `L`, then `R` order. A forced one-leg target is ordered `R`, then `L`; the log records `masterPreferred=R`.
  - [x] Decide and record whether a degraded render should surface to the user at all (for example a status line on the home screen or the persistent notification), or logs only. - Logs only for now. A transient warning gives no recovery action and would add noise during reconnect; the home screen already exposes each leg's health.
  - [ ] Deferred evidence - force one leg unhealthy and confirm the new logging fires and says the right thing.
  - [ ] Deferred evidence - write `0x4E` text to one leg only and inspect both lenses. One line of test code settles §1 empirically.
- **Outcome (2026-09-08)**: A user-visible left-eye failure immediately after reconnect exposed an ordering regression in the first implementation, not a degraded target selection. The logs showed both writes, right first and left 235 ms later, with no degradation line. Restoring the proven healthy `L`, then `R` order made subsequent rendering materially more reliable. The two deferred experiments are not required to close the observability fix; run them before relying on the firmware relay conclusion for a future transport redesign.
- **Notes**: Found while closing out the 2026-09-08 session, from a user report that looked like a one-off. Process point worth keeping: the symptom was invisible in the logs, and only became findable because the app-level logs were clean enough to *rule out* every other explanation. Cross-ref `transport-honesty-smalls`, `ble-stability-tier3` and `request-correlation-seq` (finding 3 above feeds that one directly). Do not bundle with any of them. Using `0x39` as a real render-verification signal is a larger piece of work and probably belongs in its own item once the screen ids are enumerated.

---

## 2026-09-08 — evenai-flash-fix: "Even AI is listening" flash on screen clear - investigated, not fixable host-side (closed 2026-09-08)
- **Status**: Closed 2026-09-08 — root cause characterised, no host-side fix. Not a regression risk; nothing shipped.
- **Findings**: [FINDINGS-evenai-flash-on-clear.md](FINDINGS-evenai-flash-on-clear.md) — full device results
- **Brief**: [evenai-flash-fix-brief.md](evenai-flash-fix-brief.md) — retired, kept as the record of what was planned
- **Outcome**: The flash is a transient re-render of the firmware's Even AI surface (screen id `0x10`, `ui_even_ai_task`) on the **master/right lens** during the `0x18` teardown. `exit_running_task_keep_status` — the only `0x18` teardown path that omits `update_persist_task_status_to_idle` — leaves the screen id set; a secondary path normally resets it within a few hundred ms, and when that is slow on the master a redraw renders the Even AI surface for one frame.
- **Why us and not the official app**: our `0x4E` sends use `screenStatus 0x71` for everything, so `0x39` reads `0x10` on *every* clear — we always tear down out of the Even AI surface. The official app drives the `0x30`/`0x40`/`0x50` Even AI status lifecycle and rarely hits that path. MentraOS logged the same symptom as unsolvable.
- **Disproved on device** (3 runs, S24 Ultra, fw 1.6.6): terminal `0x4E` status `0x41` (writes the pending slot, not the live id); gating the clear on `0x39` (pre-clear is `0x10` on every clear, flashing or not); removing `0x50` (no effect). Confirmed predictor: POST-clear `R=0x10` → flash, 2/2.
- **Kept**: the `readScreenState` byte-offset fix (was reading index 1, the echoed request length, instead of index 5) with the response layout documented inline; and `Proto.postClearStateProbe`, default `false`, retaining the three-point `0x39` sampling for future runs.
- **Deliberately not done**: detect-and-repair (re-sending `0x18` when POST-clear reports `0x10`) catches only ~1/3 of events and costs two BLE round trips per clear — not proportionate to a one-frame cosmetic glitch. Driving the full Even AI status lifecycle (`0x31` renders + `0x41` terminator) is the only remaining avenue and would change every text render in the app.
- **Notes**: `Proto.clearDisplay()` is back to its original `0x50 + 0x18`. `0x50` was left in despite being inert here, because removing it showed no benefit and this path regressed once before (`worklist-history.md`, 2026-05-09). Cross-ref `nav-0x50-necessity` (closed 2026-11-06, Recently Done) for the broader `0x50` question.

---

## 2026-09-08 — stt-local-whisper: Speech-to-text moved to the local whisper-server (2026-09-08, commit 4348774, main)
- **Status**: Done
- **Context**: Prompted by a real device failure - a left long-press in Glance mode returned "Transcription failed". The captured audio was proven good: a valid 16 kHz mono WAV, 9.7 s, -17 dBFS speech, header sizes matching the body - so the fault was the HTTP call. The error message mapped specifically to the `generic` error branch, not auth, not timeout, not a connection error, which narrowed it to a 4xx/5xx from OpenAI. Root cause turned out to be an exhausted OpenAI quota (429), confirmed separately once error logging was added.
- **Outcome**: All three transcription consumers - Quick Ask, Chat mode and QuickNote - now post to the self-hosted Speaches whisper-server on deepthought (`http://deepthought:56478/v1`, model `deepdml/faster-whisper-large-v3-turbo-ct2`) over Tailscale, since they share `OpenAiTranscriptionService`.
  - Unmetered, and faster than the previous OpenAI path: measured 0.34 s to transcribe 9.7 s of glasses audio, roughly 28x realtime on the RTX 3090.
  - `AssistantBackendConfig.resolveTranscription()` added as a profile separate from `resolve()`, because STT and the reasoning call no longer share a host. The reasoning call still goes to OpenAI.
  - `isConfigured` now respects a new `requiresApiKey` flag. Without it an unauthenticated self-hosted endpoint reads as unconfigured and transcription refuses before it even tries - worth recording, because that was the non-obvious part.
  - `shouldSendApiKey` attaches `Authorization` only when the base URL is `https://`. The local endpoint needs no token and ignores one, and a bearer does not belong on a cleartext request, so the OpenAI key is not handed to a host that never asked for it.
  - Timeouts tuned for a local box: 8 s connect so an asleep or off-tailnet host fails fast mid-gesture, 60 s receive for long clips.
  - New `assistant.transcription_base_url` setting, overridable at runtime under Settings alongside the existing model field. The existing `transcription_model` setting was reused rather than duplicated, so this added one field to the UI rather than two.
  - No fallback to OpenAI, deliberately - a silent fallback would spend credit without saying so, and it is the pattern just removed with Hermes. An unreachable box now shows "Whisper unreachable" instead of the previous "Network problem", which pointed at the wrong thing.
  - New config test suite, 8 cases, covering the credential rule and the profile split. Recovers some of the coverage lost when the Hermes router test was deleted.
- **Decision recorded**: moving the reasoning call to Ollama on deepthought was evaluated the same day and NOT taken. Warm latency was good (first visible token 0.99 s on `gpt-oss:20b`) but cold start is 12-28 s because Ollama evicts after 5 minutes and only one model fits in the 3090's 24 GB, which also contends with T3 Code's 19 GB coder model; and factual accuracy was poor for a HUD assistant (`gpt-oss:20b` gave Prague's population as 1.9 M against an actual ~1.38 M; `qwen2.5:7b` gave three different figures across three runs). Eddie added OpenAI credit instead and the reasoning path stays on OpenAI. The Settings base-URL override remains available as a free escape hatch to Ollama if credit ever lapses again.
- **Acceptance**:
  - [x] Transcription runs on the local whisper-server for Quick Ask, Chat and QuickNote.
  - [x] No API key sent to the cleartext local endpoint.
  - [x] Runtime override of URL and model without a rebuild.
  - [x] Device-verified: the phone itself resolved deepthought over MagicDNS and transcribed the real failed clip over the tailnet in 0.347 s with the correct transcript, and Eddie confirmed Quick Ask end to end through the glasses on 2026-09-08 ("the transcription came back great - it told me what I said").
- **Notes**: Hard dependency on the box being awake and the tailnet up, with no fallback - Eddie's explicit choice, on the grounds that the box is always awake and his phone is always on Tailscale, and that other things fail anyway if it is not.

---

## 2026-09-07 — hermes-dewire-chat: Remove Hermes as the Even assistant backend (2026-09-07, working tree, uncommitted)
- **Status**: Done
- **Outcome**: Hermes fully retired as an app backend - the second-backend plumbing was deleted outright rather than repointed at a local model (see Decision below). `ChatBackendRouter` and `ChatRoute` existed only to make the Hermes-vs-OpenAI routing decision, so with Hermes gone there was nothing left for them to decide: `lib/services/chat_backend_router.dart` and `test/services/chat_backend_router_test.dart` were deleted outright, taking the health probe, fallback logic and routing-notice mechanism with them. `chat_service.dart` and `glance_assistant_service.dart` now hold a `ChatBackend` directly (defaulting to `OpenAiChatBackend`) instead of a router; constructor injection changed from `ChatBackendRouter? router` to `ChatBackend? backend`; the pre-flight routing phase and one-time notice display were removed from both, so Chat's numbered phase comments renumbered from 4 phases to 3. `assistant_backend_config.dart` lost `resolveHermes()` and the four `HERMES_*` dart-define constants; `profileLabel` was kept (it names the backend in error messages) but now only ever resolves to 'OpenAI'. `app_settings_store.dart` lost the `AssistantBackendKind` enum entirely, all five Hermes fields/getters, `saveHermesSettings`, `setAssistantBackend` and `setHermesFallbackEnabled`. Credential and settings cleanup shipped as a migration, not just a deletion: `_purgeRetiredHermesSettings` runs on every `AppSettingsStore.init()` and deletes the five retired SharedPreferences keys (`assistant.backend`, `assistant.hermes_fallback`, `assistant.hermes_base_url`, `assistant.hermes_chat_model`, `assistant.hermes_timeout_seconds`) plus the `assistant.hermes_api_key` secure-storage entry, idempotently - a device upgrading from a Hermes build does not keep a bearer token in its keystore for a service that no longer exists. `settings_page.dart` lost the whole Hermes section - backend segmented selector, fallback switch, URL/key/model/timeout fields, "Save Hermes", "Test connection" chip and the reachability chip widget - plus the four controllers and the `_parseTimeout` helper that only served it. `docs/hermes-api-tailscale-bind-brief.md` moved to `docs/archive/` with its retirement header updated; its worklist cross-reference (in the `hermes-agent-v1` Done entry, above) was repointed to the archive path. No `HERMES_*` dart-defines needed removing from README.md or scripts - they were never documented there.
- **Acceptance**:
  - [x] Remove `AssistantBackendKind.hermes`, the Hermes `OpenAiChatBackend` instance and Hermes fallback logic from `ChatBackendRouter` - done via outright deletion of the router and its test rather than a partial strip.
  - [x] Remove Hermes URL, API-key, model, timeout, selector, fallback and connection-test settings from the app UI and `AppSettingsStore`, including secure-storage cleanup/migration for `assistant.hermes_api_key` - `_purgeRetiredHermesSettings` runs idempotently on every `init()`.
  - [x] Remove Hermes-specific tests, build defaults and documentation that describe it as an active app dependency; retain the completed `hermes-agent-v1` record as historical context - `docs/hermes-api-tailscale-bind-brief.md` archived, not deleted.
  - [ ] Confirm both Chat and left-hold Quick Ask work over the direct OpenAI route on device, including a clean network failure - **partially confirmed, left unticked**. Device-verified 2026-09-08: both Chat and left-hold Quick Ask work end-to-end over the direct OpenAI route. The only fault hit during testing was an OpenAI 429 (account had run out of API credit), resolved by Eddie adding API credit - not an app bug. The clean-network-failure sub-case (glasses connected, network unreachable) has not yet been exercised, so this line stays unticked until that is done. `flutter analyze` reports 0 errors (two pre-existing warnings, unrelated: `chat_service.dart` unused catch clause, `evenai.dart` unused field) and `flutter test` passes 7/8 (the one failure, `widget_test.dart` "app renders companion home screen", fails identically at HEAD and is unrelated); the debug APK builds.
  - [x] Mark `hermes-quicknote-sync` superseded - it has no valid backend once Hermes is retired. (Ticked previously.)
- **Decision recorded**: keeping the second-backend plumbing and repointing it at Ollama on Deepthought (`http://deepthought:11434/v1`, already tailnet-reachable and unauthenticated - no infrastructure work needed) was explicitly considered and rejected in favour of the full strip. Rationale unchanged from the item's original framing: a glasses assistant has different latency, reliability and credentials requirements than a coding assistant, and local-model access belongs in T3/OpenCode first. If a local backend earns its way in later it should be re-added deliberately behind a real wearable use case - re-adding is cheap since the router was a clean generic abstraction, so deleting it cost little optionality.
- **Notes**: Hermes the *service* is retired; the `deepthought` box is not - it now runs Ollama, T3 Code and a local OpenCode provider. Do not read this entry as deepthought having been decommissioned. Working tree, uncommitted.

---

## 2026-09-07 — phone-local-capture: Phone-mic recording - capture without the glasses (2026-09-07, working tree, uncommitted)
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
  - Notification "Stop and save" action tapped for real on device 2026-09-08 (previously untestable via adb since the service is correctly `exported="false"`) - confirmed working, routing back through the same save path as the in-app button.
- **Still outstanding**: a long screen-off recording against Samsung's battery optimiser, since the app is on no allowlist. Note also that `VOICE_RECOGNITION` AGC clipped at full scale on loud nearby speech - fine for STT, worth a look if the audio needs to sound good.
- **Structural note (no action needed today)**: the phone card's enabled state reads `CaptureService.isRecording`, but `CaptureService` is not a `ChangeNotifier` and nothing listens to it. The UI stays correct because every path that mutates its recording flag runs inside a `CompanionController` method that calls `notifyListeners()` (both gesture dispatchers do), or sits alongside a `DeviceStatusService.reset()` on transport loss. Checked rather than assumed, and both observed transitions are covered. If a future entry point starts or stops a glasses capture outside those paths the button will go stale - making `CaptureService` a notifier is the fix at that point, not before.
- **Attribution**: `PhoneCaptureRecorder.kt` was generated by the local `qwen3-coder:30b` model via the local-dev agent against a specified interface, then reviewed and corrected. Two real bugs were caught in that review loop - release-before-join on the `AudioRecord` (a native use-after-free) and an ignored nullable `Uri` return that would have reported success with a path of "null". A further pass removed a spurious read-error log that fired on every stop, deduplicated ~40 lines between the stop and cancel teardown paths, and wrapped the unguarded `AudioRecord` constructor and stream close.
- **Notes**: Working tree, uncommitted. Cross-ref `recording-filename-seconds-resolution` (Backlog) - surfaced during this work and deliberately not bundled in, to keep this item tight.

---

## 2026-06-13 — BLE ownership design pass: `ble-native-write-queue` + `ble-pending-gatt-leak` + `honest-foreground-notification` + `cold-connect-false-positive-reconnect` (2026-06-13, commits 7808f39 + c8d45e1, main)
- **Status**: Done
- **Outcome**: Four related fixes landed as a single BleManager.kt ownership design pass, field validated 2026-06-13 in ~4 hours of continuous use.

**`ble-native-write-queue`** — `GattWriteQueue.kt` (new file) implements a per-leg serialised write queue drained on `onCharacteristicWrite`, with a 500 ms watchdog fallback, bounded depth, busy-retries, and flush on disconnect. Method-channel `send` now resolves with the real write outcome rather than always `success(null)`. `BleDevice.writeRaw` replaces `sendData`, returning raw submit status; pre-Tiramisu branch now sets the characteristic value before writing (latent bug fixed, would have bitten on older devices). `BleManager.kt` `LOG_TAG` changed from `::class.simpleName` to a const string literal — R8 was tagging every native log line as `"k"` in release builds; this directly improves weekend debuggability for all three fixes above.

**`ble-pending-gatt-leak`** — At most one outstanding `BluetoothGatt` is held per leg. Pending reconnects are `close()`-d before issuing a new `connectGatt`; superseded instances are rejected at first callback; stale disconnects can no longer mutate live-leg state. Breaks the dropped-write → reconnect churn → GATT exhaustion cycle. Status 133 / GATT exhaustion provisionally resolved; multi-day cradle cycling is the remaining confirmation stress.

**`honest-foreground-notification`** — `engineAlive` flag in `BleChannelHelper`; `onTaskRemoved` (swipe-from-recents) swaps the notification to "Even Companion stopped — Tap to resume" (dismissible, no mode buttons), calls `stopForeground`+detach+`stopSelf`. Any service start without a live engine renders the stopped state. Confirmed by field test: swipe-from-recents shows "Tap to resume" rather than the "Companion mode active in background" placebo. Step 1 of `companion-lifetime-decision` is complete.

**`cold-connect-false-positive-reconnect`** (surfaced during device validation, commit c8d45e1 — not a pre-existing backlog item) — `_applyConnectionPayload`'s single-leg-disconnect branch was gating on bare `!state.connected`, which mistook a leg still mid-GATT-discovery for a dropped leg. Every cold connect was firing a spurious reconnect for the lagging leg. Fixed by gating on the connected→disconnected transition for the current payload. Confirmed by post-fix logcat: no `single-leg disconnect detected` line during cold connect.

**Field validation summary (2026-06-13, ~4 h continuous)**: no reconnect flash card observed, no silent death event, honest notification confirmed on swipe-kill. GATT leak fix provisionally working; strongest stress (multi-day cradle cycling) is the remaining gate.

---

---

## 2026-05-27 — hermes-agent-v1: Hermes Agent — replace OpenAI direct with Hermes over Tailscale (2026-05-27, merge 642f19b, main)
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

---

## 2026-05-27 — router-v1-chat-logging: Router v1 — Chat history logging (single feed, origin tag) (2026-05-27, merge 642f19b, main)
- **Status**: Done
- **Outcome**: All acceptance criteria delivered as part of `hermes-agent-v1`. Both Chat-mode and Quick Ask sessions persist in the Chat Log, distinguished by a `kind` column (`'chat'` / `'quick_ask'`) and badged in the Chat Log list on `home_page`. Eddie confirmed done 2026-05-27.
- **Acceptance**:
  - [x] All Quick Ask invocations (router-claimed and LLM-fallback) produce an entry in Chat history.
  - [x] Entry shows the question and the response.
  - [x] Origin tag (`Chat` / `Ask`) is visible per entry.
  - [x] Existing Chat entries unaffected.

---

## 2026-05-25 — emoji-notification-parsing: Emoji notification parsing — substitution map for G1 display (2026-05-25, commit 1019324, main)
- **Status**: Done
- **Outcome**: `EmojiSubstitution.apply()` implemented in `lib/services/emoji_substitution.dart` with a ~25-entry glyph → ASCII-token map (👍 → `{thumbs up}`, ❤️ → `{heart}`, plus thumbs-down, smile/laugh/sad/crying, pray, fire, party, check, x, star, 100, thinking, wave, eye roll, wink, kiss, love). Applied inside `CompanionNotification.fromMap` so substitution happens at ingest — one chokepoint, before all downstream truncation/wrapping paths (glance HUD, G1TextLayout chunking, navigate/dashboard renders). Multi-codepoint sequences (e.g. `❤️` = U+2764 + U+FE0F) handled by length-descending match. Unit tests in `test/services/emoji_substitution_test.dart` cover: single emoji, mixed text, VS-16 multi-codepoint, unknown emoji passthrough, pure ASCII untouched, empty string, repeated emoji. V1 scope fully delivered.
- **Caveat**: Tests not executed on the Linux dev box (no flutter/dart toolchain); validated on the Windows side.
- **Notes**: Map is a plain `const Map<String, String>` — future additions are one-line. V2 scope (richer tokenisation) remains available as a future item if needed.

---

## 2026-05-19 — quicknote-manual-add: QuickNote — manual add from the phone app (2026-05-19, commit 86c144d, v1.2.1+11)
FAB on the Notes screen opens a modal bottom sheet with category chips (pre-selected to the active tab) and a multi-line auto-grow text field; Save / Cancel actions. `NotesStore.insert(transcriptRaw=null, sortOrder=createdAt.toDouble(), ...)` matches the voice-capture pipeline exactly — no parallel store. Empty-text save is a no-op. Empty-state hints updated. **Device-verified 2026-05-19** — golden path passed; edge cases confirmed: empty save no-op, category change mid-edit, multi-line input, manual + voice interleave. Voice-from-app remains in Backlog as `quicknote-manual-add-voice`.

---

## 2026-05-18 — capture-v2-hud-probe: Capture v2 — HUD render probe (2026-05-18, commit a827a07, v1.2.0+10)
Delivered as continuous HUD-with-fallback rather than as a discrete probe run: `CaptureService` ships continuous 5 s HUD updates with a `useStaticRecFallback` feature flag in place if on-device testing reveals audio corruption. The probe acceptance criteria (60 s window, 12 updates, gapless WAV) were validated implicitly by the implementation choice rather than in a separate logged session — the fallback flag is the safety net. Decision embedded in implementation: continuous updates are the default.

---

## 2026-05-18 — capture-v2-recording-hud: Capture v2 — Recording HUD (2026-05-18, commit a827a07, v1.2.0+10)
Live HUD replaces static "REC" indicator. Three states delivered: idle ("Capture ready / Tilt up to record"), recording (`* REC  MM:SS` cycling pulse on `*`/`#`/`.`, updates every 5 s, timer local in Dart), save confirmation ("Saved / <duration> - <filename>", auto-clears after 5 s). HUD re-render confirmed non-disruptive to WAV pipeline. Feature-flag fallback to static "REC" available via `useStaticRecFallback`.

Files changed: `lib/services/capture_service.dart`, `lib/services/companion_controller.dart`.

---

## 2026-05-18 — capture-v2-safer-stop: Capture v2 — Safer stop gesture (2026-05-18, commit a827a07, v1.2.0+10)
Tilt-up (`F5 02`) during active recording is now a no-op ("Recording — double-tap to stop"). Double-tap (`F5 00`) is the sole stop+save path. Defensive guard added to `handleDoubleTapModeSwitch` so `F5 20` cannot steal the gesture during active recording. Existing tilt-up start behaviour (when not recording) unchanged.

Files changed: `lib/services/capture_service.dart`, `lib/services/companion_controller.dart`.

---

## 2026-05-18 — pixel-aware-0x4e-wrapping: Pixel-aware `0x4E` line wrapping with per-glyph font table (2026-05-18, commits a827a07 + c8de032, v1.2.0+10)
New `G1TextLayout` module porting MentraOS's ~120-glyph `G1Text.kt` font table (ASCII + Latin-1+ accented characters). Binary-search wrapping with space-break preference replaces Flutter `TextPainter`-based measurement in `EvenAIDataMethod.measureStringList`. All three call sites (evenai ×2, text_service ×1) upgraded transparently. `c8de032` is the docs companion: `current-architecture.md` updated with the new module, `protocol-reference.md` updated with confirmed `0x4E` 9-byte header layout.

Files changed: `lib/services/g1_text_layout.dart` (new), `lib/services/evenai.dart`, `lib/services/text_service.dart`. Docs: `docs/current-architecture.md`, `docs/protocol-reference.md`.

---

## 2026-05-18 — capture-v2-recordings-list: Capture v2 — Recordings list UI (2026-05-18, commit a827a07, v1.2.0+10)
New `RecordingsPage` backed by MediaStore queries (no local database). Lists all WAV files under `Recordings/Even Companion/`, most recent first. Per-row actions: rename (prefix-only, timestamp suffix preserved), share via system intent, delete with confirmation. Home page card added between Notes and Chat history. New Kotlin platform-channel methods: `listRecordings`, `renameRecording`, `deleteRecording`, `shareRecording`. Filename pattern updated from `capture_yyyyMMdd_HHmmss.wav` to `Capture-yyyy-MM-dd-HH-mm.wav`; dual-regex parser handles both formats.

Files changed: `lib/models/recording.dart` (new), `lib/services/recordings_service.dart` (new), `lib/views/recordings_page.dart` (new), `lib/views/home_page.dart`, `android/.../BleChannelHelper.kt`.

---

## 2026-05-18 — quicknote-polish: QuickNote diagnostic log revert (2026-05-18, commit e1182dd)
Diagnostic log promotions from QuickNote v1 development reverted: `BleRx`, `R21Probe`, and `QuickNoteProbe` info promotions reverted to `AppLog.debug`; capture service probe/decode/tidy logs demoted; class doc updated.

---

## 2026-05-18 — call-state-telephony-upgrade + incoming-call-hud: Telephony-driven call handling (2026-05-18, commit dc9d959, v1.1.0+9)
Full call-lifecycle coverage on the glasses, sourced from `TelephonyManager` rather than the notification listener. **Device-verified 2026-05-18** — incoming call displayed correctly on glasses, caller name resolved, timer ticked, auto-cleared on hang-up.

- `READ_PHONE_STATE` permission added to `AndroidManifest.xml` with runtime request flow.
- `TelephonyEventService.kt`: dual-path implementation — `PhoneStateListener` (pre-API 31) and `TelephonyCallback` (API 31+). Publishes `RINGING` / `OFFHOOK` / `IDLE` states to Dart via a new `eventTelephony` `EventChannel`.
- `GlanceService`: incoming-ring path shows `"Incoming Call\n<caller name>"` on the glasses immediately on `RINGING`; active-call HUD with live timer on `OFFHOOK`; display clears automatically on `IDLE`.
- Caller identity sourced from notification metadata (the `com.samsung.android.incallui` notification carries the caller name) — `READ_CONTACTS` was deliberately not added.
- Call notifications suppressed from the Glance carousel while telephony is active (identity fed from notification metadata to the telephony-driven HUD).
- Outgoing call detection: `IDLE→OFFHOOK` without a preceding `RINGING` is treated as an outgoing call.
- Notification-based detection retained as fallback for the permission-denied case.

Files changed: `AndroidManifest.xml`, `TelephonyEventService.kt` (new), `lib/services/glance_service.dart`, `lib/services/companion_controller.dart`, `pubspec.yaml`.

---

## 2026-05-18 — call-idle-dismiss-fallback: Call HUD restored when last carousel notification dismissed (2026-05-18, commit d4f0f0e, v1.0.2+6)
`GlanceService.removeNotificationByKey()` now checks `_currentCall != null` before calling `Proto.exit()`; when the last carousel notification is dismissed during an active call it transitions to the call HUD instead of clearing the display. No protocol changes — targeted fix to the notification-removal logic only.

Files changed: `lib/services/glance_service.dart`.

---

## 2026-05-18 — ble-stability-tier2: Heartbeat cadence shifted to first-connect rate, faster than official app steady state (2026-05-18, commit 280bb32)
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

---

## 2026-05-13 — mode-title-cards: Glance and Navigate mode entry title cards, plus Connected/Reconnected clear (2026-05-13, v1.0.2+3)
All three sub-items field-verified on device by Eddie.

- **Glance title card**: flashes "Glance" for ~500 ms on mode entry, then clears. Confirmed not intrusive.
- **Navigate title card**: flashes "Navigate" for ~500 ms on mode entry, **only when no active nav instruction is held** (`!NavigateService.hasInstruction`). The hard constraint (Navigate card mid-bootstrap cancels session) was respected by awaiting the flash inside `_restoreModeEntryState`, so the trailing `0x50+0x18` clear cannot land mid-bootstrap from a concurrent Maps notification handler.
- **Connected/Reconnected force-clear**: replaces the previous "resync visible content" semantics in `CompanionController.handleTransportRecovered`. On any real reconnect (skipped on the very first connect of the session, gated by new `_hasEverConnectedThisSession` flag), the path flashes "Reconnected" for ~1 s, force-clears via the `0x50 + 0x18` combo, then conditionally resumes: REC if recording active, nav refresh if nav visible+hasInstruction, call HUD if active call, otherwise blank. Old `resendLastText`/`resendLastBmpData` calls dropped by design — stale glance content is wrong because the glasses' display state after a disconnect is unknown. Field test confirmed: Glance notification visible + Bluetooth off/on → "Reconnected" flashed and screen actually cleared (the motivating stuck-screen bug).

**What shipped:**
- New `Proto.showTitleCard(text, {duration})` helper — sends text via `0x4E`, holds, then `0x50+0x18` clear.
- New `GlanceService.handleTransportLost()` — resets `_isVisible`/`_isIdleSurfaceActive`/timers; wired into both drop paths in `BleManager` (`_onGlassesDisconnected` and the `anyLegDropped` block in `_applyConnectionPayload`). Without this, post-reconnect notifications would not auto-pop because `_isVisible` survived the drop.
- `CompanionController.handleTransportRecovered` rewritten with first-connect-this-session suppression and QuickNote-capture guard.

Files changed: `lib/services/proto.dart`, `lib/services/companion_controller.dart`, `lib/services/glance_service.dart`, `lib/ble_manager.dart`, `pubspec.yaml`.

---

## 2026-05-13 — ble-mic-on-reconnect-ghost: "Mic start failed" ghost notification on single-leg reconnect (2026-05-13)
Field-verified absent on v1.0.1+2. Not seen since the fix was installed. Three interacting causes addressed: (1) voice guard armed too late on `onServicesDiscovered` — fixed by arming before any F5 events from the newly-up leg can land; (2) stale `_isListening`/`_isThinking`/`_isRecording` flags blocking `_scheduleClear` — cleared by new flag-only `handleTransportLost()` called from both full-drop and single-leg-drop paths; (3) missing voice guard coverage on `_handleChatGesture` case 2 and `_handleCaptureGesture` case 2. Committed in `4b0fc3f` ("Connectivity fix, Mic Start Failed bug"). Flag-only teardown via `handleTransportLost()` confirmed as the correct long-term approach — no IO/non-IO split of `reset()` needed (see `glance-assistant-reset-on-reconnect`, also closed 2026-05-13).

Files changed: `lib/ble_manager.dart`, `lib/services/glance_assistant_service.dart`, `lib/services/chat_service.dart`, `lib/services/capture_service.dart`.

---

## 2026-05-13 — ble-reconnect-pacing: BLE reconnect storm — per-leg cooldown and exponential backoff (2026-05-13)
Field-verified on v1.0.1+2. Consistent reconnects observed after single-leg drops; no `GATT_NO_RESOURCES` storm (previously 4488 per ~120 s) and app log lines remain readable in logcat. Root cause was an unpaced `STATE_DISCONNECTED → _attemptLegReconnect → connectGatt` loop amplified by bare `connected=true` resets every 6 ms. Fix: per-leg cooldown gate via `_lastReconnectAttemptAt` map, exponential backoff 2/4/8/16/30 s, and counter reset moved to `_recordLegAck`/`_recordHeartbeatSuccess` only (proof of end-to-end link). Committed in `4b0fc3f` ("Connectivity fix, Mic Start Failed bug"). Kotlin in-flight guard refinement deliberately deferred — see `ble-fast-flap-investigation` in Backlog.

Files changed: `lib/ble_manager.dart`.

---

## 2026-05-11 — package-rename: Package rename com.example.demo_ai_even → com.eddie.evencompanion (2026-05-11)
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

---

## 2026-04-13 — glance-heads-up-timings: Adaptive tilt-up intent delay in Glance mode (2026-04-13)
Idle→active state transition for tilt-up intent delay: full delay from idle, zero delay mid-carousel, delay restored when carousel clears. Shipped in commit `c18ce37`.

**Acceptance checklist:**
- [x] **From idle**: tilt-up retains the existing intent delay before triggering.
- [x] **Mid-carousel**: tilt-up triggers immediately with zero delay.
- [x] **Back to idle**: the full intent delay is restored before the next tilt-up fires.
- [x] No accidental triggers from casual head movements while idle.

*Discovered already shipped during 2026-05-11 backlog review.*

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
