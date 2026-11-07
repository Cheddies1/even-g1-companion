# Region sync: sync, list and manage walking regions from the app

**Status:** DONE 2026-11-07 - all five phases complete
**Created:** 2026-11-07   **Last updated:** 2026-11-07   **Completed:** 2026-11-07

## Goal
From the app's Navigate area, "Sync current location" builds a walkable region (~5 km radius) on
cartographer as a background job, with a phone notification when it is ready. The app lists
regions with pin, unpin and delete; unpinned regions expire after ~30 days unused. A shared
destination outside every region offers a sync, and trips route on the region that contains
them instead of the hard-coded `home`.

## Out of scope
Walks that cross two regions; pre-building Prague for w/c 2026-11-09; in-app destination entry
(the Google Maps share stays the only trip start); per-region tile pre-rendering (tiles stay per
trip); Wi-Fi-only or indoor positioning.

## Inputs and access
- App repo (this one): `lib/services/walknav/walk_navigator_service.dart` (`routeUrl`,
  `_fetchBundle` with `region_id: 'home'`), `NavLocationService.kt` (location FGS, `NavBridge`),
  `lib/views/` (no Navigate screen yet).
- Design agreed with Eddie 2026-11-06: `docs/plans/navigate-v1-cartographer.md`, "Follow-on after
  v1: region sync" (pinned regions: home, work, Prague office at Nove Butovice, central Prague at
  Namesti Republiky; fleeting ones deleted when done; large transient downloads fine).
- Contract: `docs/cartographer-contract.md` ("Regions, operations and failures": `GET /v1/regions`
  and a per-region manifest already exist; no build or sync API; the engine and routing adapter
  are single-region).
- cartographer: `/home/eddie/projects/personal/cartographer/` (git; Valhalla 3.9.1;
  `prepare.py`, `prepare_routing.py`, `service.py`). **Codex owns the box**: all server work via
  T3 `delegate_task` to Codex; read `/home/eddie/projects/personal/deepthought/README.md` before
  briefing. Service URL `https://deepthought.tail082c0b.ts.net:9446`, tailnet only.
- Source extracts: Geofabrik (England ~1.5 GB, Czech Republic ~0.9 GB, NRW ~0.7 GB); clip, then
  delete or park on the NAS.
- Device: S24 Ultra + G1, adb over Tailscale; desk test recipes in AGENTS.md.

## Phases

### [x] 1 - Multi-region routing on cartographer
- **Objective:** route on any prepared region, not just `home`.
- **Steps:** Codex makes the engine and routing adapter serve several regions (one Valhalla
  tile set per region or a merged set - Codex chooses on memory and rebuild cost); bbox
  validation per region; when `region_id` is omitted, pick the region whose bbox contains both
  endpoints, 404 `no_region` if none. Build one second region by hand to prove it (a small
  test area away from home).
- **Deliverable:** service change + routing section of `docs/cartographer-contract.md`.
- **Done when:** `home` acceptance still passes and the second region returns a valid bundle.
- **Delegate:** Codex via `delegate_task`; Claude reviews the contract.

### [x] 2 - Region lifecycle API
- **Objective:** build and manage regions over HTTP.
- **Steps:** `POST /v1/regions {lat, lon, name?, pinned?}` -> job id (pick the Geofabrik extract
  for the point, clip ~5 km radius, build geometry cache + routing graph, write manifest);
  `GET /v1/regions/jobs/{id}` (queued/running/done/failed + reason); `PATCH /v1/regions/{id}`
  (pin, rename); `DELETE /v1/regions/{id}`; expiry sweep of unpinned regions unused for 30 days
  (`last_used`). One build at a time; reject a new build whose centre is already inside a region.
- **Deliverable:** service change + regions section of `docs/cartographer-contract.md`.
- **Done when:** a region built via the API from a coordinate routes, and an expired unpinned
  test region is swept (test with a backdated `last_used`).
- **Delegate:** Codex via `delegate_task`; Claude reviews the contract.

### [x] 3 - Regions screen in the app
- **Objective:** see and manage regions from the phone, and start a sync.
- **Steps:** Navigate area entry on the home page; regions page (list from `GET /v1/regions`,
  cached for offline display; pin/unpin, rename, delete with confirm); "Sync current location"
  takes one fix (reuse the location FGS) and POSTs a build. Poll the job on the Android side
  (Dart timers stall with the screen off, see the 2026-11-07 wakelock fix), then post a local
  notification ready/failed. Debug broadcast to sync a given coordinate for desk tests.
- **Deliverable:** regions page + region service (pure parsing/state unit-tested) + Kotlin poller.
- **Done when:** on device, a debug-coordinate sync appears in the list, notifies when done, and
  pin and delete round-trip to the server.
- **Delegate:** inline. Can start once phase 2's contract section exists.

### [x] 4 - Region-aware trip start
- **Objective:** trips pick their region; uncovered destinations offer a sync.
- **Steps:** on share, check origin and destination against cached region bboxes (refresh the
  list first if online); none -> phone notification "Sync this area?" with an action that starts
  the phase 3 sync at the destination, plus a glasses card "Walk: outside synced areas"; send the
  containing `region_id` (or omit and let the server pick); handle `no_region` cleanly.
- **Deliverable:** walk navigator + controller changes with unit tests for region selection.
- **Done when:** a share to a destination outside `home` prompts, the sync completes, and a
  re-share walks there (desk replay acceptable).
- **Delegate:** inline.

### [x] 5 - Review and ship
- **Objective:** merged, reviewed, documented.
- **Steps:** `review-loop` on the app changes; update `current-behaviour.md`,
  `current-architecture.md`, worklist, AGENTS.md (one line for the regions debug broadcast);
  merge to `main` and push.
- **Deliverable:** merged code + updated docs.
- **Done when:** merged and pushed with review approval and docs current.
- **Delegate:** inline, then `review-loop`.

## Decisions
- 2026-11-06 - Region sync design agreed (see the v1 plan's follow-on section): Navigate-area
  trigger, auto-offer for uncovered destinations, pinned vs ~30-day expiry, large transient
  downloads accepted, tiles still rendered per trip.
- 2026-11-07 - Normal pace; Prague w/c 2026-11-09 is not a target (Eddie).
- 2026-11-07 - Sync runs as a server background job; the phone polls and notifies, so the
  phone can be pocketed (Eddie).

- 2026-11-07 - Phase 1 design (Codex): one Valhalla graph + container per region on its own
  loopback port (manifest `routing_port`; home 8003, `richmond-test` 8004); ~60 MiB engine RAM
  each. Regions are discovered from `data/<dir>/manifest.json`, so phase 2 must publish the
  manifest only after data and engine are ready, serialise builds, and allocate distinct ports.
  Benchmark full-source extraction before setting HTTP/job timeouts (graph stage alone ~0.5 s for
  Richmond). `richmond-test` (unpinned) is the phase 2 sweep/delete test candidate.
- 2026-11-07 - Contract for phases 3-4: omitting `region_id` auto-selects the smallest bbox
  holding both endpoints, else 404 `no_region`; manifest `size_bytes` is an object (`total` etc.),
  `last_used` may be null; bundle version is 1.1.0 (app accepts any `1.x`).
- 2026-11-07 - No per-region roundabout handedness: walking directions, so it does not matter (Eddie).
- 2026-11-07 - Phase 2 contract (Codex, cartographer `f584161`): POST builds return 202
  `{job_id, region_id}` and are not idempotent - on a lost response check `GET /v1/regions` before
  retrying. 409 `build_busy` (no queue) means retry later; 409 `region_exists` means the centre is
  covered; DELETE on a pinned region is 409 `pinned`. Jobs persist indefinitely; the phone must
  persist `job_id`, resume polling after hours or disconnects, and notify on done/failed. Failure
  `reason` is free text, not an enum. Region ids are opaque.
- 2026-11-07 - Radius fixed at 5 km (~10 x 10 km bbox); a real Prague build took 25.6 s from
  Geofabrik's 45 MB Praha extract, but country-sized sources will be far slower, so the app must
  never assume a quick finish. Expiry 30 days default via `CARTOGRAPHER_EXPIRY_DAYS`; Eddie can
  change it without an app change.
- 2026-11-07 - Live regions after phase 2: `home` (pinned) and a Prague region built via the API;
  `richmond-test` was swept as the expiry test.

- 2026-11-07 - Phase 3 shape: Dart (`lib/services/walknav/region_service.dart`, pure parsing in
  `region_model.dart`) owns list/cache/PATCH/DELETE/POST; after a 202 it hands the job to Android
  (`service/RegionSync.kt`): `RegionJobStore` (SharedPreferences) + `RegionJobWorker` on WorkManager
  2.9.1 (network constraint, linear 20 s backoff, first poll at 15 s), notification channel
  `even_companion_region_sync`. Dart hears `jobUpdate`/`jobFinished` on the `eventRegions` channel.
  Phase 4 should reuse `WalkRegion.contains` and `RegionService.regions`/`syncAt`.
- 2026-11-07 - Deviation: "Sync current location" uses `LocationManager.getCurrentLocation` while
  the app is in front, not the nav location FGS, so it never collides with an active trip's
  `NavBridge` stream.
- 2026-11-07 - Debug broadcast for the phase 5 AGENTS.md line: `am broadcast -p
  com.eddie.evencompanion -a com.eddie.evencompanion.REGION_SYNC --es at "lat,lon" [--es name X]
  [--ez pinned true]`; app must have been opened since install. Over `adb shell` a name with spaces
  needs inner quoting or it truncates at the first space.

- 2026-11-07 - Phase 4 shape: the route request omits `region_id` (server auto-selects with the
  same smallest-bbox rule), so a stale phone list cannot pin a trip to the wrong region. The phone
  list only gates the sync offer: `tripCoverage` in `region_model.dart` (covered / unknown /
  uncovered / split). Checked at share time on the destination alone (settles the old open
  question: yes, pre-check, before GPS starts) and again with the origin after the first fix;
  `regionsForTrip` refreshes with a 6 s cap, then uses the cache. Empty cache = let the server
  decide; a server `no_region` refreshes and offers. Split walks get "Walk: spans two areas", no
  offer. A running build suppresses a second offer ("Walk: area still syncing").
- 2026-11-07 - The offer's action runs entirely on Android (`RegionOfferReceiver` ->
  `RegionBuildWorker` POST -> `RegionSync.watch`), so it works with the app closed. The POST is
  never retried; failures post a notification. Samsung hides the action until the notification
  is expanded (Eddie missed it on the first try).

- 2026-11-07 - Offer-built regions are named from the share's first plain line
  (`MapsShare.placeName`, 40 chars), falling back to the server id (Eddie).

## Open questions
- None.

## Artefacts
- cartographer `3ea1af3`, `f584161` (multi-region + lifecycle API); `docs/cartographer-contract.md`
- App: `lib/services/walknav/region_model.dart`, `region_service.dart`, `lib/views/regions_page.dart`,
  `service/RegionSync.kt`, walk navigator region gating

## Progress log
- 2026-11-07 - phase 1 done (Codex): cartographer `3ea1af3`, service 1.1.0; `docs/cartographer-contract.md` updated; home and `richmond-test` acceptance passed. Deviation: handedness dropped mid-task (Eddie).
- 2026-11-07 - phase 2 done (Codex): cartographer `f584161` (no remote, not pushed); regions section of `docs/cartographer-contract.md` rewritten; four acceptance checks passed, 12 tests. Deviation: none.
- 2026-11-07 - phase 3 code done: regions page, `region_service.dart`/`region_model.dart` (13 unit tests), `RegionSync.kt` poller; debug sync of Greenwich (`greenwich-dd341f95`, unpinned, left in place for the UI check) built in ~65 s, polled through to done, notification posted, Dart refreshed. Eddie then pinned, unpinned, renamed and deleted it from the page; all four round-tripped (logcat `[Regions]`, server list back to home + Prague). Phase done. Deviation: one-shot fix instead of the FGS. `test/widget_test.dart` was already failing on main (sqflite + missing "Permissions" card).
- 2026-11-07 - phase 4 done: walk navigator + `tripCoverage` (6 new tests, 89 pass in `test/services`), Android offer receiver/worker. Device: debug trip to Windsor Castle was refused and offered; the action built a Berkshire-sourced region in 24.8 s and notified; a re-run routed in it (659 m, 5 tiles) and ran; test region deleted. Deviation: `region_id` omitted rather than sent.
- 2026-11-07 - phase 5 done: review-loop (loop, GPT `gpt-5.6-sol`, 2 rounds, approved; G1/G3/G4 fixed, G2 accepted as is); behaviour, architecture, worklist and AGENTS.md updated; merged to `main` and pushed. Deviation: offer naming added before review (open question). No follow-ups: Eddie renames regions and handles mid-walk `no_region` by hand.
