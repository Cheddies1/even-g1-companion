# FINDINGS: screen-off GPS (gate C)

> **Document type:** Device findings
> **Audience:** AI agents and Eddie working on walking navigation
> **Evidence basis:** S24 Ultra (SM-S928B, SDK 37) traces from `GpsTraceService`

Gate C of [plans/navigate-v1-cartographer.md](plans/navigate-v1-cartographer.md): can the
phone deliver ~1 Hz fixes for 30-60 min pocketed with the screen off?

**Status:** gate C **passed** 2026-11-06 on a 58 min pocketed run (walk out, ~25 min stationary indoors, walk back).

## Recorder
- `android/.../service/GpsTraceService.kt`: foreground service typed `location`,
  `LocationManager.FUSED_PROVIDER` at 1000 ms, `QUALITY_HIGH_ACCURACY`, no Play Services
  dependency. `--es provider gps` switches to the raw GNSS provider for comparison.
- Debug builds only. Start with the app in the foreground (Android 14+ will not start a
  location foreground service from the background):
  `adb shell am broadcast -p com.eddie.evencompanion -a com.eddie.evencompanion.GPS_TRACE --es cmd start`
  Stop with `--es cmd stop` or the notification's Stop action.
- One CSV per run in `/sdcard/Android/data/com.eddie.evencompanion/files/gps/`, flushed per
  row. Columns: `wall_ms,t_ms,kind,provider,lat,lon,acc_m,speed_mps,bearing_deg,note,battery_pct,screen,idle`.
  `kind` is `fix`, `start`, `stop` or `error`. A missing `stop` row means the OS killed the
  service. Not sticky on purpose, so a kill shows as a truncated trace.
- Summarise with `tool/gps_trace_summary.py <trace.csv>`: fix rate, interval percentiles,
  gaps over 2 s, accuracy, battery %/h, screen-off and doze counts.
- Traces hold real coordinates. Pull them into `logs/gps/` (gitignored) and keep only the
  summary numbers in this doc.

## Preconditions on the test phone (checked 2026-11-06)
- `ACCESS_FINE_LOCATION` granted, precise.
- App already on the user battery-optimisation whitelist (`dumpsys deviceidle whitelist`)
  and `RUN_ANY_IN_BACKGROUND` allowed. No One UI change was needed.

## Smoke test, 2026-11-06 (indoors, screen off, stationary, 30 s)
29 fixes at 0.96/s, first fix 1.2 s after start, interval p50/p95/max 1000/1000/1001 ms, no
gaps over 2 s, accuracy p50 4.2 m / p95 10.8 m, all fixes screen-off, no doze. Too short to say
anything about battery or OS kills.

## Pocketed walk
Protocol: app open, start the trace, lock the phone, pocket it, walk 30-60 min including a
stretch of stationary waiting (doze is the risk), stop from the notification, pull, summarise.
Optionally a second run with `--es provider gps` to compare.

Pass: no OS kill, gaps over 5 s rare and short, accuracy p95 usable for the >15 m map-match
corridor in phase 5, battery drain tolerable for an hour's walk. Kill: sustained gaps or kills
that settings cannot fix.

| Date | Provider | Span | Fix rate | Gaps > 2 s (count / total) | Max gap | Acc p50 / p95 | Battery %/h | Doze fixes | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-06 | fused | 57.7 min, 3258 fixes | 0.94/s | 54 / 242.6 s | 7.0 s | 6.2 / 118.4 m (all); moving 5.1 / 14.4 m | 11.4 | 0 | pass |

Run 2026-11-06 20:33-21:31: walk out ~20 min, ~25-30 min stationary indoors at the
destination, walk back. Phone locked and pocketed throughout; 2962 of 3258 fixes screen-off; the
service was stopped from its notification, so no OS kill.

| Window (min) | Activity | Fixes | Acc p50 / p95 (m) | Gaps > 2 s |
|---|---|---|---|---|
| 0-20 | walking | 1201 | 3-5 / 4.4-6.0 | 0 |
| 25-50 | stationary indoors | ~1300 | 13-104 / 85-149 | 52 |
| 50-58 | walking / arriving | 455 | 6-12 / 11-15 | 1 |

Reading:
- **Walking is excellent.** 1 Hz with zero gaps and p95 accuracy of 4-6 m for the whole outbound
  leg with the screen off. Moving fixes overall (speed > 0.7 m/s): p50 5.1 m, p95 14.4 m, inside
  the >15 m map-match corridor planned for phase 5.
- **All the bad numbers are indoors.** Every gap (max 7.0 s) and every large accuracy figure is in
  the stationary indoor window, where the fused provider falls back to network/Wi-Fi fixes. That
  is not a navigation scenario, but phase 5 must not trust low-accuracy fixes: gate map-matching
  and off-route detection on `acc_m` (e.g. ignore fixes worse than ~25 m) rather than on fix rate.
- **No doze.** 0 doze-flagged fixes; the foreground service held through ~25 min of stillness.
- **Battery 11.4 %/h** (78% -> 67%) with the app, BLE to the glasses and GPS all running.
  Tolerable for an hour's walk; not yet broken out per component.
- Not done: a raw `--es provider gps` comparison run. Not needed to pass the gate.

