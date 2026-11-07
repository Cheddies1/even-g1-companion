# Cartographer HTTP contract v1

Running on deepthought, service 1.2.0, 2026-11-07. Base URL: `https://deepthought.tail082c0b.ts.net:9446`. HTTPS is Tailscale Serve, tailnet only, with no application authentication. No Funnel or LAN listener. The API binds loopback port 8766; each prepared region has a separate Valhalla engine on loopback (home 8003; other ports allocated per region). Operational runbook and implementation: [cartographer](../../cartographer/README.md). Display protocol remains [FINDINGS-nav-marker-tiles.md](FINDINGS-nav-marker-tiles.md).

## Request and response

`POST /v1/route`, `Content-Type: application/json`, body 1..4096 bytes. Only origin, destination and optional region_id are accepted. Coordinates must be finite numeric WGS84 degrees. Equal endpoints are rejected. An explicit region_id selects that region and requires both endpoints inside its bbox. Omit region_id to auto-select the smallest spherical bbox area containing both endpoints; equal areas use lexicographic region_id as a deterministic tie-break. No matching region returns HTTP 404 `no_region`. The phone may continue sending `home`.

```json
{"origin":{"lat":51.5122017,"lon":-0.3405805},"destination":{"lat":51.5067295,"lon":-0.3374416},"region_id":"home"}
```

The response is UTF-8 JSON. Every coordinate pair in `polyline` is `[latitude,longitude]`, decoded from the engine's polyline6 shape; this field is an array, not an encoded string. Distances are metres measured cumulatively along that shape with the renderer's local tangent distance. `total_m` and manoeuvre progress use the same basis, avoiding disagreement between engine summary distance and phone progress.

| Field | Type and meaning |
|---|---|
| bundle_id | SHA-256 of canonical request, service version and data identity; phone cache key |
| version | Bundle schema/behaviour semantic version, currently `1.2.0` |
| region_id | ID of the selected prepared region |
| data_id | SHA-256 of geometry cache bytes followed by routing extract bytes |
| polyline | Ordered array of numeric `[lat,lon]` pairs, snapped to pedestrian network |
| total_m | Number, length of polyline |
| maneuvers | Ordered array of objects described below |
| tiles | Ordered array of objects described below |
| coordinate_order | Literal `lat,lon` |
| attribution | OSM attribution and licence string to retain with cached data |

Each manoeuvre has numeric `progress_m` at its engine begin-shape vertex, `instruction` text, `street_name` text (empty for unnamed paths), integer `direction` (firmware value, decimal in JSON), and integer `engine_type` for diagnostics. Arrival uses straight as the safe arrow fallback. These are human instructions, not pre-truncated firmware TRIP_STATUS fields: the phone must apply protocol byte limits, especially the 64-byte road field.

Each tile has string `id`, numeric `progress_start_m`, `progress_end_m`, clockwise true-north `orientation_deg`, `panoramic`, `mini_map`, and `marker_transform`. Each bitmap object has integer `width`, `height`, `raw_bytes`, `wire_bytes`, `encoding` (`raw` or `rle`), `sha256` of the decoded-base64 wire bytes, `raw_sha256` of the decompressed pixels, and `data_base64`. Hash strings are lowercase hexadecimal.

Abbreviated example, with bitmap data and hashes truncated and most tiles/coordinates omitted (not valid for validation):

```json
{
  "bundle_id":"08c3546b8b5fea789b8cfb4ef15dbb96e7a558d37147726fd6973df7c606824f",
  "version":"1.1.0","region_id":"home","data_id":"...",
  "coordinate_order":"lat,lon",
  "polyline":[[51.512202,-0.340581],"..."],"total_m":723.5828357226798,
  "maneuvers":[{"progress_m":83.76159090349222,"instruction":"Turn left onto Station Road.","street_name":"Station Road","direction":4,"engine_type":15}],
  "tiles":[{
    "id":"t000","progress_start_m":0,"progress_end_m":190,"orientation_deg":180.0,
    "panoramic":{"width":488,"height":136,"encoding":"raw","raw_bytes":16592,"wire_bytes":16592,"sha256":"...","raw_sha256":"...","data_base64":"..."},
    "mini_map":{"width":136,"height":136,"encoding":"rle","raw_bytes":4624,"wire_bytes":2158,"sha256":"...","raw_sha256":"...","data_base64":"..."},
    "marker_transform":{"projection_origin_lat_lon":[51.512202,-0.340581],"orientation_deg":180.0,"metres_per_pixel":1.5,"pixel_offset":[244,68],"earth_radius_m":6371008.8,"clamp":{"x":[6,482],"y":[6,130]}}
  }],"attribution":"© OpenStreetMap contributors, ODbL 1.0; https://www.openstreetmap.org/copyright"
}
```

Transform numbers in the abbreviated example are illustrative; always consume the returned values.

## Tiles and marker transform

Retains gate B's renderer: panoramic 488x136, forward right, 1.5 m/px; mini-map 136x136, forward up, 2 m/px, tile-start cue at (68,112), approximately 224 m ahead. Route 4 px bright, sparse dim context. Maps are static for each interval; the phone updates the firmware circle on the panoramic map. The baked gate B chevron remains at tile start; the mini-map has no moving firmware marker.

Tiles target 190 m. Starts near manoeuvre progress minus 95 m put turns near the middle. Nearby manoeuvres share tiles: candidate starts less than 90 m beyond the preceding start are coalesced. Fill tiles advance by 140 m, giving 50 m overlap; manoeuvre placement can increase overlap. Final tiles may be shorter. If a bend cannot fit both maps with marker clearance at the fixed scales, reduce the interval by 20% repeatedly and adapt the overlap to at most half its length. No scale changes or clipped route intervals. A one-metre minimum fit failure, or more than 500 tiles, returns an error. Each tile's heading follows its first 20 m, or its entire interval when shorter.

Phone selects a tile whose interval contains matched route progress. Retain the old tile through the overlap until the new pair of maps has finished transferring. Choose the next tile before leaving the old interval. Gate A's master-last transfer and clear-before-INIT rules remain the phone's responsibility.

For progress `s`, interpolate `[lat,lon]` along `polyline` using cumulative local tangent segment distances. For each segment from `a` to `b`, distance is `hypot(R*radians(b.lon-a.lon)*cos(radians(a.lat)), R*radians(b.lat-a.lat))`. Linearly interpolate lat/lon within the containing segment. Use the returned transform to project this position, or project a GPS lat/lon directly:

```text
R = earth_radius_m = 6371008.8
phi0, lambda0 = projection_origin_lat_lon (degrees)
east  = R * radians(lon-lambda0) * cos(radians(phi0))
north = R * radians(lat-phi0)
theta = radians(orientation_deg)
forward = east*sin(theta) + north*cos(theta)
right   = east*cos(theta) - north*sin(theta)
x = round(forward/metres_per_pixel + pixel_offset[0])
y = round(right/metres_per_pixel   + pixel_offset[1])
x = min(482,max(6,x)); y = min(130,max(6,y))
```

Round to nearest integer, ties to even, matching Python. Panoramic offset centres the interval's rotated bounding box. Every route vertex and every metre within each advertised interval is validated before handoff without clamping. Linear segments cannot have interior extrema in this projection. For progress beyond an active tile, hold at the interval endpoint while swapping; never extrapolate. For GPS off the matched route, clamp to the safe rectangle. Clamping prevents edge debris, but does not establish that a walker is still on route; rerouting/matching policy belongs to the phone.

## Arrow mapping

Valhalla type integers follow its [route API](https://valhalla.github.io/valhalla/api/route/api-reference/). Firmware meanings are pinned by the [tested built-in arrow table](FINDINGS-nav-marker-tiles.md#built-in-arrows-test-4). UK circulation is clockwise. Never select the even counterclockwise roundabout values for this region.

| Engine type | Firmware direction |
|---|---|
| 9 SlightRight / 16 SlightLeft | 0x05 / 0x06 |
| 10 Right / 15 Left | 0x03 / 0x04 |
| 11 SharpRight / 14 SharpLeft | 0x07 / 0x08 |
| 12 UturnRight / 13 UturnLeft | 0x0a / 0x09 |
| 23 StayRight / 24 StayLeft | 0x22 fork right / 0x23 fork left |
| 18 RampRight / 19 RampLeft | 0x20 / 0x21 |
| 20 ExitRight / 21 ExitLeft | 0x03 / 0x04 |
| 25 Merge / 37 MergeRight / 38 MergeLeft | 0x0b / 0x1f / 0x1e |
| 26 RoundaboutEnter | 0x1d clockwise enter |
| 27 RoundaboutExit | Exit bearing relative to approach, clockwise sectors below |
| All other types, including start, arrival, continue, steps and unknown | 0x02 straight |

For a roundabout exit, find the preceding enter manoeuvre. Compare heading on the segment before its begin vertex with heading on the segment after the exit begin vertex. Signed delta is `(exit-approach+180)%360-180`. Absolute delta >=165 degrees selects 0x1b U-turn; <=15 selects 0x13 straight. Positive delta selects 0x11 slight right (<45), 0x0f right (<135), otherwise 0x0d sharp right. Negative selects 0x15 slight left (>-45), 0x17 left (>-135), otherwise 0x19 sharp left. Missing entry/exit geometry falls back to 0x02. This uses geometry, not exit count: spokes need not be evenly spaced. All eight clockwise sectors have automated mapping checks; the acceptance walk has no roundabout, so that integration remains untested on a real route.

## Bitmap encoding and caching

Two one-bit planes per map: dim first, bright second. Each plane is row-major top-first, bit 0 leftmost, no row padding or headers. Bright wins where both planes are set. Panoramic has two 8,296-byte planes, always raw, exactly 16,592 B. Mini-map has two 2,312-byte planes, decoded total exactly 4,624 B.

Mini-map RLE reuses the gate B harness encoder: pairs of unsigned bytes `<count><value>`, count 1..255, runs spanning row and plane boundaries, no terminator or header. Expand each value count times across the concatenated planes. Send RLE only when strictly smaller than raw; otherwise raw at exactly 4,624 B. Firmware interprets exactly 4,624 B as raw and any other size as RLE. `encoding` makes that choice explicit for the phone.

JSON contains base64 of the actual bytes to send. There are no external tile URLs or runtime dependencies in a bundle. Save the complete response under bundle_id, verify both bitmap hashes and decoded sizes, and reload locally after Tailscale disconnects. Retain attribution. The HTTP response includes an ETag (SHA-256 of response bytes) and `Cache-Control: private, max-age=31536000, immutable`; POST bodies must be part of any request cache key. Phone storage by bundle_id is authoritative rather than relying on an HTTP cache.

Versioning: `/v1` fixes the schema and bitmap contract. Additive fields may increment the minor version. Any changed routing image/configuration, arrow semantics, tile model or rendering behaviour increments `version`, and therefore changes bundle IDs. Breaking decoding changes require `/v2`. Changed extracts or geometry change `data_id` and bundle IDs. Restart the service after replacing datasets. Existing downloaded bundles remain valid and immutable. There is no expiry-driven network refresh.

## Regions, operations and failures

`GET /v1/regions` returns `{"regions":[...]}` from published `data/<dir>/manifest.json` files. Each has region_id, name, centre (`lat`,`lon`), bbox_wsen (W,S,E,N), created, last_used (UTC, initially null), pinned, routing_port and measured size_bytes (extract, geometry_cache, routing_extract, routing_graph, routing_config, total). Successful route creation/cache retrieval updates only the selected region's last_used. Each region has its own graph/container; adding/deleting one never rebuilds another. Home stays pinned on port 8003. Both endpoints and the snapped route must remain within the selected bbox. There is no handedness field; the clockwise arrow adapter remains unchanged.

`POST /v1/regions` accepts `{lat,lon,name?,pinned?}` and returns HTTP 202 `{job_id,region_id}`. pinned defaults false. Coordinates must be finite numeric WGS84 degrees; names non-blank strings of at most 100 characters; pins boolean; unknown fields invalid. The fixed 5 km radius produces a bbox envelope, approximately 10 x 10 km. Envelopes beyond +/-85 latitude or crossing the antimeridian are rejected. IDs are unique name/coordinate slugs with a suffix; treat them as opaque. A centre already inside a published region returns 409 region_exists. Envelope overlap is allowed otherwise. Only one build runs at a time; another returns 409 build_busy, without queuing. A 202 is not readiness.

`GET /v1/regions/jobs/{job_id}` returns job_id, region_id, state (`queued|running|done|failed`), created and optional stage, reason, finished, timings_s and source metadata. Stages are source_download, geometry, routing_extract, graph_and_engine. Jobs persist indefinitely under data/jobs, including after region deletion. queued -> running -> done/failed; queued can fail during launch/restart. The phone must persist job_id, resume polling after hours/disconnection and notify on done/failed. A job may finish between polls. Failure reasons are diagnostic strings, not a fixed enum. A lost POST response does not make resubmission idempotent: check regions before retrying. Region_exists identifies coverage via GET regions; build_busy means retry later. Polling has no long-held request and needs no connection to remain open.

Builds use separate systemd units (4 GiB, two-hour deadline), never the API's serial worker/512 MiB cgroup. Geofabrik's index selects the smallest polygon containing the centre; a border envelope can extend beyond that source's coverage. The full source is downloaded, both extraction passes run with disk-backed node indexes, then a new engine starts on a distinct loopback port. Atomic manifest publication happens only after geometry, graph and engine readiness; created is set and last_used null. Engines retain their 2 GiB Docker ceiling. Failed/killed workers are reconciled within roughly 10 seconds: stop/remove their engine, remove partial data/source and release the port before marking failed. API restart stops unfinished builds and marks api_restarted; an already published manifest wins and marks done. A cleanup failure keeps the job active for retry. No other region is touched.

`PATCH /v1/regions/{id}` accepts `{pinned?,name?}` and returns the updated manifest (200), written with file fsync, atomic replace and directory fsync. It leaves last_used unchanged. `DELETE /v1/regions/{id}` returns 200 `{deleted:id}` after removing its engine/container, data and cached bundles. Pinned regions return 409 pinned: unpin first. Interrupted deletion resumes from a durable marker. Bundles already downloaded to the phone remain valid.

Unpinned regions expire when last_used (created if null) is older than N days. N defaults to 30 via CARTOGRAPHER_EXPIRY_DAYS in the API systemd environment. Sweep runs at startup and hourly; it uses the same deletion path. Pin to preserve a region. Full-source/partial downloads under data/sources/job_id are removed after success/failure/recovery. The manually retained London source stays. Regional bundle caches are reclaimed on deletion/expiry; no independent cache age/size eviction. Job records remain.

Measured full-source build on 2026-11-07: Geofabrik now supplies a 45,102,584 B Praha extract, smaller than Czech country data. A real 5 km-radius Prague build took download/index 2.66 s, geometry 8.24 s, routing extraction 6.16 s, graph/engine readiness 8.12 s, total 25.55 s including publication; first cold run 23.92 s. This supports the urban radius, not country-source latency. Timeouts: download 3600 s, each extraction 2400 s, engine readiness 600 s, overriding unit deadline 7200 s. The phone must poll the job rather than hold POST open or assume a 30-second completion guarantee.

| HTTP | JSON error / meaning |
|---|---|
| 400 | invalid_request: region mutation input/JSON invalid; invalid_route: malformed route request, invalid/equal coordinates, outside bbox, route leaves bbox or tiles cannot fit |
| 404 | unknown_region: explicit route/metadata/delete ID absent; no_region: no bbox contains both route endpoints; unknown_job: job ID absent/invalid; not_found: unknown path |
| 409 | region_exists: centre covered; build_busy: one build active; pinned: unpin before deletion |
| 413 | body_size: absent/zero Content-Length or more than 4096 bytes |
| 422 | no_walkable_route: engine rejects unconnected/unsnappable route |
| 503 | routing_unavailable: engine timeout/connection/server failure; build_unavailable: worker launch failed; no_port: allocation range exhausted |
| 500 | bundle_failed or region_operation_failed: storage/Docker/unexpected failure; details stay in journal |

`GET /health` (also `/`) returns service, version, routing ready with HTTP 200 when every published engine responds, else 503. The serial API worker can briefly delay health/polls during route rendering or deletion. It retains only the latest region geometry. Measured live acceptance: home still 723.58 m / six tiles, Richmond still 629.37 m / five tiles before deliberate expiry, Prague 674.81 m / five tiles. All passed saved-bundle offline validation. HTTP pin/rename/unpin/delete, restart failure recovery, build_busy and startup expiry of backdated Richmond passed. Prague was rebuilt after delete; Richmond is intentionally absent. The runbook owns units, recovery and operational limits.

## Engine choice and measured evidence

Valhalla `3.9.1-8e84136b2`, pinned scripted-image digest `sha256:4e77581226c7b6f5923372b46b0a6203e857ca828d4dfa5cb817d09949d927f3`. Chosen for pedestrian access handling and explicit footway/pavement weighting, keeping mapped cut-throughs and crossings in the network. [Pedestrian costing source](https://github.com/valhalla/valhalla/blob/master/src/sif/pedestriancost.cc) documents these factors. The service uses pedestrian costing with walkway_factor and sidewalk_factor 0.9. GraphHopper was not benchmarked head-to-head; this choice is capability-based, backed by the real local route rather than a claim of universal superiority.

Routing preparation retains all highway ways/areas intersecting the bbox envelope, referenced tagged nodes and restriction relations; it does not feed the simplified display geometry into routing. Complete ways can extend outside the envelope, but v1 rejects routes whose shape leaves it. Admin/timezone, elevation and transit data are disabled. The existing clockwise roundabout adapter is unchanged; per-region handedness was excluded from this change. Gate B display context remains sparse even when the route uses pavement/crossing geometry. Mapped access and crossing data can be incomplete; no surveyed crossing or step-free guarantee.

Measured home region file bytes on 2026-11-06:

| Component | Bytes |
|---|---:|
| Renderer highway extract | 1,694,804 |
| Geometry cache | 9,546,751 |
| Routing extract (areas/nodes/restrictions retained) | 1,785,470 |
| Routing graph (10,168,320 B tar plus 10,155,496 B loose graph tiles) | 20,323,816 |
| Routing config/hash files | 9,613 |
| Total region payload | 33,360,454 (31.82 MiB) |

Region payload excludes the tiny manifest, directory metadata, shared source download, Python environment, Docker image and bundle cache. Retained Greater London source PBF is 130,061,734 B shared preparation input, not a required regional runtime dependency.

Acceptance: public Campbell Road / Golden Manor junction to the Boston Road POI from the request above. Engine route 723.58 m; six tiles, twelve maps; saved JSON 159,282 B. Walkway and crosswalk manoeuvres appear in real engine output. The bundle was fetched through the HTTPS tailnet endpoint, then reloaded from disk with socket creation disabled. Extended `validate.py` checked every wire/raw size and SHA-256, complete overlapping coverage, and all route vertices plus one-metre marker samples inside x 6..482 / y 6..130 without applying a clamp. Original gate B fixture validation and four service invariant tests also passed. Request and offline evidence are in the service's `acceptance/` directory; downloaded JSON and caches are gitignored.

Measured Richmond test region file bytes on 2026-11-07 (same payload exclusions as home):

| Component | Bytes |
|---|---:|
| Renderer highway extract | 164,065 |
| Geometry cache | 863,696 |
| Routing extract | 173,509 |
| Routing graph (tar plus loose graph tiles) | 1,791,736 |
| Routing config/hash files | 9,613 |
| Total region payload | 3,002,619 (2.86 MiB) |

Richmond uses the retained Greater London source with no extra download. HTTPS acceptance from (51.4632,-0.3013) to (51.4595,-0.3060), omitting region_id, returned `richmond-test`: 629.37 m, five tiles, ten maps, 136,159 B. Both Richmond and home passed saved-bundle offline validation under service 1.1.0. Explicit and auto-selection produced the same cached bundle per region, distinct data IDs across regions, and last_used updated only on the selected region. HTTP checks confirmed unknown_region=404, no_region=404 and explicit endpoints outside bbox=400. Home remains 723.58 m / six tiles / 159,282 B. Six service unit tests and all twelve original fixture binaries/previews passed.
