# Walking navigation v1: cartographer tiles on deepthought, navigator on the phone

**Status:** IN PROGRESS - phases 1-4 done (gates A, B and C passed; cartographer live); next is phase 5
**Created:** 2026-11-06   **Last updated:** 2026-11-06   **Completed:** -

## Start here (next session: phase 5)
- **Code state (2026-11-06):** phases 1-4 on `main`, pushed. Branch from `main` for phase 5.
- **Cartographer:** live at `https://deepthought.tail082c0b.ts.net:9446/v1/route` (Valhalla
  pedestrian, home region only). Schema, tile model, marker transform and arrow mapping:
  `docs/cartographer-contract.md`. Codex owns the service and its repo
  (`/home/eddie/projects/personal/cartographer/`, now under git).
- **First step of phase 5:** read the contract, then design the navigator around the two open
  questions below that phase 5 owns (manoeuvre noise, mini-map position cue).

## Goal
A working v1 walking navigation mode. At trip start, a `cartographer` service on deepthought
compiles a pedestrian route and pre-renders a bundle of route-forward map tiles. The phone caches
the bundle, tracks GPS with the screen off, moves the firmware's position marker every second,
switches tiles at overlap boundaries, and drives the `0x0a` nav card. Trips start from a Google
Maps share. Phases 1-3 are feasibility gates: a failed gate stops the plan and is recorded.

## Why this shape (supersedes the 2026-06-20 phone-rasteriser decision)
The firmware decompilation (`JohnRThomas/even_realities_decomp`, branch `1.66_exact`) showed:
- `TRIP_STATUS` `pos_x` (<=488) / `pos_y` (<=136) draws a marker glyph over the panoramic map,
  and a position-only change redraws map + marker without resending the bitmap
  (`src/ui/ui_navigation_map.c:161`, `:236`; `src/ble/ble_proto.c:2231`). We currently hard-code
  `x=200, y=18` (`lib/services/proto.dart:1232`).
- `TRIP_STATUS` `direction` (1-0x23) selects one of ~35 built-in arrow bitmaps
  (`ui_navigation_map.c:40`); the 136x136 `MAP_OVERVIEW` is a separate mini-map region
  (`:95`, `:107`). Our generated arrow duplicates firmware work at 13 packets per leg.
- A full panoramic image is ~90 packets per leg and display content is not relayed between lenses,
  so image swaps are expensive; marker moves are cheap. Both maps must be ready before the
  firmware enters RUNNING (`ui_navigation_map.c:371`). SYNC is master-only with ~19 s grace.

So: static route-forward tiles + cheap marker moves, rendered on deepthought, not a live on-phone
rasteriser. Codex (gpt-5.6-sol) independently recommended the same hybrid on 2026-11-06.

## Out of scope
Live heading-up rotation, dynamic zoom, continuous panorama refresh, on-phone rasterising, rich
map labels, voice destination entry, coverage beyond the home area, frequent rerouting.

## Inputs and access
- App repo (this one): `lib/services/navigate_service.dart`, `proto.dart` (nav bootstrap,
  `_buildNavTripStatusPacket`, SYNC poller), `nav_icon_generator.dart`, `nav_replay_data.dart`.
- Protocol docs: `docs/protocol-reference.md` (0x0a), `docs/firmware-decomp-notes.md`,
  `docs/FINDINGS-layouts.md`, worklist items `4. Navigate cleanup`, `navigate-osm-research`.
- Firmware source: re-clone `https://github.com/JohnRThomas/even_realities_decomp` branch
  `1.66_exact` into a scratch dir (the 2026-11-06 copy was in `/tmp`).
- Optional: `https://github.com/JohnRThomas/Even-G1-Simulator` (Renode) to preview bitmaps
  before a device session.
- Device: S24 Ultra + G1 (fw 1.6.6); adb over Tailscale (`100.89.74.113:5555`, needs a USB
  `adb tcpip 5555` after a phone reboot). Debug probe: see AGENTS.md "Debug protocol probe".
- deepthought: **Codex owns the box.** All deepthought work is delegated to Codex via T3
  `delegate_task`; read `/home/eddie/projects/personal/deepthought/README.md` before briefing.
- Home-area extract: bbox W -0.410, S 51.467, E -0.266, N 51.557 (Hanwell / Ealing, ~5 km).

## Phases

### [x] 1 - Marker and tile harness (gate A)
- **Objective:** prove cheap marker motion and measure what an image swap costs on the glasses.
- **Steps:** from the decomp, write down exact `PANORAMIC_MAP` / `MAP_OVERVIEW` formats (bitmap +
  mask, bit depth, row order, packet framing, `PANORAMIC_MAP_SIZE`). Add a debug path (probe
  intent or debug-only button) that loads a chosen panoramic + overview image, then sends
  `TRIP_STATUS` with configurable `pos_x`/`pos_y`/`direction`, plus timed image replacements.
  Device session: 1 Hz marker sweep incl. edges/corners, both-lens alignment, swaps at 2/5/10 s
  (transfer time, tearing, eye gap), catalogue the built-in arrows 1-0x23.
- **Deliverable:** `docs/FINDINGS-nav-marker-tiles.md` + the harness code on a branch.
- **Done when:** the findings doc records all of the above with measured numbers and an arrow
  table. **Kill:** marker motion is poor, or an occasional swap is visibly unacceptable.
- **Delegate:** inline (device back-and-forth). The decomp format read can go to a subagent.

### [x] 2 - Fixture tiles (gate B) - render part parallel-safe with 1
- **Objective:** prove a 1-bit 488x136 route-forward tile and a 136x136 mini-map are legible
  while walking.
- **Steps:** Codex builds a renderer on deepthought from an OSM extract of the home area and
  produces panoramic + overview images for three scenes: suburban, dense junction, cut-through.
  Output in the format pinned in phase 1. Then push each with the phase 1 harness and walk them.
- **Deliverable:** renderer + fixtures (location chosen by Codex, recorded here) and a verdict
  section appended to `docs/FINDINGS-nav-marker-tiles.md`.
- **Done when:** each scene has a legible / marginal / dead verdict from a walk.
- **Delegate:** Codex via `delegate_task` for the renderer; device verdict inline.

### [x] 3 - Screen-off GPS recorder (gate C) - parallel-safe with 1 and 2
- **Objective:** prove ~1 Hz GPS for 30-60 min with the phone pocketed and screen off.
- **Steps:** Android foreground service of type `location`, fused provider at ~1 Hz, writes a
  timestamped trace; One UI battery-optimisation exemption. No BLE, no routing.
- **Deliverable:** the service on a branch + `docs/FINDINGS-screen-off-gps.md` with the trace
  summary (fix gaps, accuracy, battery drain).
- **Done when:** a 30-60 min pocketed walk shows acceptable gaps and battery. **Kill:** sustained
  gaps or OS kills that settings cannot fix.
- **Delegate:** implementation can go to a subagent; the walk and verdict are inline.

### [x] 4 - Route-bundle API on deepthought
- **Objective:** a versioned `cartographer` endpoint returning a cacheable trip bundle.
- **Steps:** Codex imports the home-area extract, stands up a pedestrian routing engine (Valhalla
  or GraphHopper, chosen on walking quality), and returns `{polyline, maneuvers, tiles[]}` where
  each tile has `id`, `progress_start_m`, `progress_end_m`, `orientation_deg`, panoramic and
  overview bitmaps, and a marker transform (route progress -> pixel). Overlapping tiles centred
  on manoeuvres plus coverage between them. Manoeuvres map onto the firmware arrow table from
  phase 1. Tailscale-only, separate from anything else on the box.
  Build on the gate B renderer and its defaults (pano 1.5 m/px forward-right, mini-map 2 m/px
  forward-up, ~190 m tiles with ~50 m overlap). Every tile carries **both** a panoramic and a
  mini-map bitmap in the pinned two-layer 1-bit format; mini-map RLE when smaller than raw.
  Put the cartographer directory under git as part of this phase.
  Store regions by id with a small manifest (name, centre, bbox, created, last used, pinned,
  size on disk), even though v1 has only the home region, so the region-sync follow-on below is
  an addition, not a rework. Record measured per-region disk use (extract, geometry cache,
  routing graph) in the contract doc.
  Arrow table: `docs/FINDINGS-nav-marker-tiles.md` "Built-in arrows" (resolved 2026-11-06).
- **Deliverable:** the service + `docs/cartographer-contract.md` in this repo.
- **Done when:** one real home-area route downloads once, hashes and dimensions validate, and the
  bundle stays usable with Tailscale disconnected.
- **Delegate:** Codex via `delegate_task`; Claude reviews the contract against phase 1 findings.

### [ ] 5 - Phone navigator
- **Objective:** end-to-end walking navigation on the glasses.
- **Steps:** Google Maps share intent -> destination (plus a hard-coded dev destination); fetch
  and cache the bundle; map-match GPS to route progress (generous corridor >15 m); advance
  manoeuvres into `TRIP_STATUS` text + firmware `direction`; pick the tile, compute the marker
  from its transform; switch tiles only in overlaps; off-route after sustained disagreement
  (>10 s) -> one reroute call; keep going on cached data if Tailscale drops. Mode ownership stays
  in `CompanionController`. Ignore fixes with `acc_m` worse than ~25 m for map-matching and
  off-route (gate C). While a trip is live, route `F5 00/02/03` to the navigator rather than the
  generic close/tilt handlers. Reuse the gate C location request (`FUSED_PROVIDER`, 1000 ms, high
  accuracy) in a `location`-typed foreground service started from the share intent.
- **Deliverable:** navigator service(s) in `lib/services/` with unit tests for map-matching,
  tile selection and off-route hysteresis.
- **Done when:** a real walk shows per-second marker moves, tile switches at intended points,
  correct turn text/arrows, and arrival.
- **Delegate:** inline.

### [ ] 6 - Protocol hardening and de-replay
- **Objective:** production-grade `0x0a` lifecycle.
- **Steps:** packet builders replace `nav_replay_data.dart` in the main path; master-only SYNC
  every ~5 s with ack-based liveness (SYNC reply byte 5 = 0 means not running); reconnect
  mid-walk resyncs maps and position; proper `0x0a 05` EXIT and `0x0a 06` ARRIVED; retire the
  generated `MAP_OVERVIEW` arrow; Google Maps notification path kept as fallback. Update
  `protocol-reference.md`, `current-behaviour.md`, AGENTS.md, worklist.
- **Deliverable:** merged code + updated docs.
- **Done when:** the replay is not used in the main path, a deliberate BLE drop mid-walk recovers,
  and arrival shows ARRIVED.
- **Delegate:** inline, then `review-loop` for cross-model review.

## Decisions
- 2026-11-06 - Deepthought pre-renders route-forward tiles; phone moves the firmware marker and
  selects tiles - firmware marker makes image swaps rare; supersedes the 2026-06-20 phone
  rasteriser.
- 2026-11-06 - Use firmware built-in arrows; `MAP_OVERVIEW` becomes a real mini-map.
- 2026-11-06 - Plan runs to full v1 with phases 1-3 as kill gates.
- 2026-11-06 - Trip start via Google Maps share intent.
- 2026-11-06 - OSM extract covers home city + surroundings only.
- 2026-11-06 - All deepthought work delegated to Codex (box owner).
- 2026-11-06 - Gate A passed. Head level shows the overview page (built-in arrow + 136x136
  mini-map); the marker exists only on the tilt-up panoramic page. So the **mini-map is the
  primary walking map** and the panoramic + marker is the tilt-up detail view. Phase 2 must
  judge the mini-map scene at head level as well as the panoramic tile; phase 4 must render
  both per tile; phase 5 should refresh the mini-map per manoeuvre or tile (8-25 packets,
  0.3-0.65 s), not just the arrow.
- 2026-11-06 - Bitmap format pinned: two 1-bit layers per map, layer 1 dim, layer 2 bright,
  row-major, bit 0 = leftmost pixel. Panoramic 2 x 8,296 B raw only; mini-map 2 x 2,312 B,
  raw at exactly 4,624 B, otherwise RLE - send the smaller. See
  `docs/FINDINGS-nav-marker-tiles.md`.
- 2026-11-06 - Lifecycle rules for phases 5-6: `0x18` clear before INIT; right (master) lens
  receives its final map packet only after the left has finished (gate on L's last-packet ack);
  marker clamped to x 6..482, y 6..130. Use L acks for timing - R queues its responses.
- 2026-11-06 - Panoramic swap ~2.4 s per tile, visually clean and in sync: tile switches are
  cheap enough that phase 4/5 need not minimise them aggressively.
- 2026-11-06 - Home extract is a ~5 km bbox around Hanwell (W -0.410, S 51.467, E -0.266,
  N 51.557). The renderer takes the region as a parameter so a second area is a new bbox plus
  an extract download. Exact home address deliberately kept out of the repo.
- 2026-11-06 - Gate B is walked on one real route, Campbell Road junction (Hanwell) to The
  Dodo Micropub, Boston Road: 3-6 overlapping tiles `rNN_<label>` in walking order, covering
  suburban, the Uxbridge Road / Boston Road junction and arrival, plus `x_cutthrough` if the
  route has none. Tiles carry progress start/end in metres - the seed for phase 4's tile model.
- 2026-11-06 - Renderer lives at `/home/eddie/projects/personal/cartographer/` (Codex-owned;
  `prepare.py` per region, `render.py` per itinerary). Defaults: panoramic forward = right at
  1.5 m/px; mini-map forward = up at 2 m/px, ~224 m look-ahead; route 4 px bright, sparse dim
  context. Route is ~720 m in five tiles (`r01`-`r05`, ~190 m each, 50 m overlap); busiest
  junction in `r04`; `x_cutthrough` is off-route. Fixtures in `tool/nav_fixtures/`; harness
  emits `s_<scene>.txt` (boot with scene maps, marker from scenes.json, 600 s hold).

- 2026-11-06 - Gate B passed: all six scenes legible at head level and tilted up. Keep the
  cartographer defaults (pano 1.5 m/px forward-right, mini-map 2 m/px forward-up, 4 px bright
  route, sparse dim context) as phase 4's starting point; ~190 m tiles with ~50 m overlap are
  acceptable. Not yet tested: a moving marker over these tiles and the arrow as next manoeuvre
  (the walk used a fixed straight-on arrow) - both are phase 5.
- 2026-11-06 - Restarting nav (EXIT, wait ~3 s, clear + INIT) shows the "generating route"
  splash, and a faster restart blanks the display. That was a harness shortcut for gate B only.
  Real trips swap tiles inside one session by resending maps, already proven in phase 1
  (`t3_swap`, `t5_ovswap`).
- 2026-11-06 - The app's own gesture handlers fight nav: every mode acts on tilt-up and close
  sends `0x18`. Phase 5 must route `F5 02/03/00` to the navigator while a trip is live.

- 2026-11-06 - Gate C recorder uses `LocationManager.FUSED_PROVIDER` (API 31+), not Play
  Services `FusedLocationProviderClient`: no new dependency. Phase 5 can reuse the same request
  (1000 ms, high accuracy) from a `location`-typed foreground service started while the app is
  foregrounded, since Android 14+ refuses a background start. Trip start from a Google Maps
  share brings the app forward, so that constraint is met.

- 2026-11-06 - Use case is pub-to-pub walks. Indoor / Wi-Fi-only positioning is out of scope
  (Eddie); gate C's indoor gaps and 100 m+ fixes are accepted, handled only by accuracy
  filtering in phase 5.
- 2026-11-06 - Phase 4 starts on the home area only (Eddie). Travel coverage, including Prague
  w/c 2026-11-09, is not part of v1.
- 2026-11-06 - Region sync is the first follow-on after v1: Navigate-area "Sync current location",
  region list on the phone, pinned vs auto-expiring unpinned regions, large transient downloads
  accepted. Phase 4 stores regions by id with a manifest so this is additive.
- 2026-11-06 - Phase 4 engine is Valhalla 3.9.1, pedestrian costing (walkway and sidewalk factor
  0.9), chosen on capability; GraphHopper not benchmarked. Bundles are self-contained JSON with
  base64 bitmaps, cached on the phone by `bundle_id`; each tile carries its own marker transform.
  Phase 5 must clamp TRIP_STATUS strings itself (contract text is not pre-truncated) and hold the
  marker at the tile end while swapping, never extrapolate.
- 2026-11-06 - Arrows 0x0c-0x23 named from the decomp resource table and spot-rendered from the
  firmware bitmaps: roundabout cw/ccw pairs 0x0c-0x1d, merge L/R, ramp R/L, fork R/L. UK
  roundabouts use `cw` (odd values). Walking needs 0x02-0x0a, 0x22/0x23 and the `cw` set.

## Follow-on after v1: region sync (own plan when v1 ships)
Eddie's design, 2026-11-06:
- A **"Sync current location"** action in the app sends the phone's GPS position to cartographer,
  which builds a region (~5 km radius) on deepthought: extract, routing graph, geometry cache.
  Tiles are still rendered per trip, not per region.
- The app **lists the regions on deepthought** so they can be tidied from the phone; Eddie can
  also tidy locally on the box.
- **Pinned** regions are kept: home, work, Prague office (Nové Butovice), central Prague
  (Náměstí Republiky). **Fleeting** ones (e.g. Bristol, Essen) are deleted when no longer
  needed.
Agreed with Eddie 2026-11-06:
- The sync action lives in the app's **Navigate** area (a Navigate / Regions screen), not Glance.
  Also offer it automatically when a shared destination falls outside every region.
- **Pinned vs unpinned**: pinned regions are kept; unpinned ones expire after N days unused (N to
  settle, ~30), so tidying is optional.
- **Large transient downloads are fine** (Geofabrik country extracts: England ~1.5 GB, Czech
  Republic ~0.9 GB, NRW ~0.7 GB). Use the simplest source; clip, then delete or park the country
  file on the NAS. No need to engineer bbox-only fetching.
- Cached region storage (below) is acceptable on deepthought's disk.
Size estimate (measured where marked):
- Home region today: highway extract 1.7 MB + geometry cache 9.5 MB (**measured**), plus a
  routing graph not yet built (estimate 10-40 MB). So ~15-50 MB per region; ten regions under
  ~0.5 GB. Dense central Prague will be at the top end.
- Source extract used to clip it: Greater London 130 MB (**measured**); transient, can be
  deleted or parked on the NAS.
- Per-trip bundle: ~21 KB raw per tile (pano 2 x 8,296 B + mini-map 2 x 2,312 B); a 3 km walk
  is ~20-25 tiles, ~0.5 MB raw, far less compressed. Negligible on the phone.
- The six gate B fixtures take 268 KB (**measured**).
- Conclusion: regions fit comfortably on deepthought's own disk; the NAS is only worth using for
  archived source extracts.
Phase 4 lays the groundwork (region id + manifest incl. `pinned` and `last_used`, measured
size); v1 still ships with the home region only.

## Open questions
- Manoeuvre noise: the 724 m acceptance route yields 14 manoeuvres, including pavement and
  crossing micro-turns and two fork-right (0x22). Phase 5 likely needs to suppress or merge
  short-spaced manoeuvres before they drive the arrow and text.
- Mini-map position: it has no firmware marker; the baked cue sits at tile start (68,112), so
  it goes stale over a ~190 m tile. Phase 5 to decide on more frequent mini-map refreshes
  (0.3-0.65 s each) versus a cartographer change to shorter mini-map intervals.
- Roundabout exit mapping is unit-tested only; no real route with a roundabout yet.
- Tile spacing and overlap - phase 2 found ~190 m / ~50 m fine when static; confirm on phase 5 walks.

## Progress log
- 2026-11-06 - phase 1 - `docs/FINDINGS-nav-marker-tiles.md`, harness `tool/nav_harness.py` +
  probe batch mode in `BleManager.kt` on branch `nav-marker-harness`. Deviations: harness is
  adb-driven Kotlin batch + Python generator, not a Dart debug path; arrows catalogued as
  "all 35 render" without per-value names for 0x0c-0x23; 500/250 ms sweeps generated but not
  run; firmware nav simulator closed (JSON legacy format, not `0x0a`).
- 2026-11-06 - phase 2 - verdicts in `docs/FINDINGS-nav-marker-tiles.md` (gate B), fixtures
  `tool/nav_fixtures/`, renderer `/home/eddie/projects/personal/cartographer/`, harness
  `s_<scene>.txt` sessions; probe holds back F5 00/02/03 during batches. Deviations: one real
  route (home to The Dodo) instead of three unrelated scenes, plus off-route `x_cutthrough`;
  judged stationary with route knowledge, not on a moving walk.
- 2026-11-06 - phase 3 (part) - `GpsTraceService.kt` + debug `GPS_TRACE` broadcast,
  `tool/gps_trace_summary.py`, `docs/FINDINGS-screen-off-gps.md`; 30 s indoor screen-off smoke
  test clean (1 Hz, no gaps). Pocketed 30-60 min walk and verdict still to do. Code uncommitted
  on `nav-marker-harness`, not its own branch.
- 2026-11-06 - phase 3 - gate C passed on a 58 min pocketed run (`docs/FINDINGS-screen-off-gps.md`):
  walking 1 Hz, zero gaps, moving p95 14.4 m; all gaps and poor accuracy were stationary
  indoors; no doze, no OS kill; battery 11.4 %/h. Deviation: one run, fused provider only.
  Carry into phase 5: filter fixes by `acc_m`, not by rate.
- 2026-11-06 - phase 4 (part) - arrow table in `docs/FINDINGS-nav-marker-tiles.md` (from decomp
  bitmaps, no device session); phases 1-3 merged to `main` and pushed; Codex delegated to build
  the service and `docs/cartographer-contract.md`. Not ticked until the contract is reviewed.
- 2026-11-06 - phase 4 - Codex built `cartographer` (Valhalla, `:9446/v1/route`, region manifest,
  git) and `docs/cartographer-contract.md`; Claude reviewed it against gate A findings and
  re-fetched the acceptance route live (6 tiles, hashes and sizes verified). Deviation: no
  roundabout route tested.
