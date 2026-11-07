# Walking navigation v1 - older progress log

- 2026-11-06 - phase 1 - `docs/FINDINGS-nav-marker-tiles.md`, harness `tool/nav_harness.py` +
  probe batch mode in `BleManager.kt` on branch `nav-marker-harness`. Deviations: harness is
  adb-driven Kotlin batch + Python generator, not a Dart debug path; arrows catalogued as
  "all 35 render" without per-value names for 0x0c-0x23; 500/250 ms sweeps generated but not
  run; firmware nav simulator closed (JSON legacy format, not `0x0a`).
