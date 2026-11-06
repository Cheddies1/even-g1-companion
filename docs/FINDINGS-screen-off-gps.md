# FINDINGS: screen-off GPS (gate C)

> **Document type:** Device findings
> **Audience:** AI agents and Eddie working on walking navigation
> **Evidence basis:** S24 Ultra (SM-S928B, SDK 37) traces from `GpsTraceService`

Gate C of [plans/navigate-v1-cartographer.md](plans/navigate-v1-cartographer.md): can the
phone deliver ~1 Hz fixes for 30-60 min pocketed with the screen off?

**Status:** recorder built and smoke-tested; the pocketed walk is not yet done. Gate C is open.

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

## Pocketed walk - TODO
Protocol: app open, start the trace, lock the phone, pocket it, walk 30-60 min including a
stretch of stationary waiting (doze is the risk), stop from the notification, pull, summarise.
Optionally a second run with `--es provider gps` to compare.

Pass: no OS kill, gaps over 5 s rare and short, accuracy p95 usable for the >15 m map-match
corridor in phase 5, battery drain tolerable for an hour's walk. Kill: sustained gaps or kills
that settings cannot fix.

| Date | Provider | Span | Fix rate | Gaps > 2 s (count / total) | Max gap | Acc p50 / p95 | Battery %/h | Doze fixes | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | |
