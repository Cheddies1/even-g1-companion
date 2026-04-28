# G1 BLE — battery / wear / brightness opcode capture findings

Source: `btsnoop_hci.log` (3.0 MB, 2026-04-28 11:02–11:09 UTC), official Even
Realities Android app paired with `Even G1_71_L_350E0F` /
`Even G1_71_R_C719EC` on firmware 1.6.6.

Ground-truth values observed in the official app during the capture:
- Glasses battery: **100%** (unchanged for the full 7-min session)
- Case (cradle) battery: **60%** (unchanged for the full 7-min session)

That ground-truth pinned the byte mappings. See `parse_btsnoop.py` for the
parser (no tshark dependency) and `traffic.csv` / `summary.txt` for full
extracted UART traffic.

---

## TL;DR

```
RX  F5 06          worn
RX  F5 07          transitioning
RX  F5 08          in cradle, lid open
RX  F5 0B          in cradle, lid closed
RX  F5 0A <pct>    glasses battery percentage 0..100 (byte 2)
RX  F5 0F <pct>    case (cradle) battery percentage 0..100 (byte 2)
RX  F5 0E <flag>   cradle cable state (0/1, paired with F5 09)
RX  F5 12 <lvl>    brightness state push (echoes most recent applied level)

TX  01 <lvl> <auto>  set brightness   (level 0..42, auto 0/1)
```

All battery values are **pushed** — there is no need to poll. While worn the
glasses re-push `F5 0A` every ~1–2 s; the case re-pushes `F5 0F` more
sparsely. Both temples emit each event independently.

The official app additionally polls `0x29` (single-byte write to the right
glass, response `29 65 <pct> 00 ...`) every ~60 s. That polled path is
redundant for live readings and has not been adopted.

---

## Evidence

### `F5 0A 64` = glasses 100%

| timestamp                | side  | byte 2 hex | byte 2 dec |
|--------------------------|-------|------------|------------|
| 11:04:37.380             | right | 0x64       | **100**    |
| 11:04:37.548             | left  | 0x64       | **100**    |
| 11:05:26.023             | right | 0x64       | 100        |
| 11:05:56.426             | right | 0x64       | 100        |
| 11:06:37.041             | left  | 0x64       | 100        |
| 11:07:57.932 – 11:08:19  | left  | 0x64       | 100 (×9 burst while worn) |

Matches the on-screen "100%" exactly. While worn it re-pushes about every
1–2 s (the 9-event burst at 11:07:57–11:08:19 is in the wearing window).

### `F5 0F 3C` = case 60%

| timestamp     | side  | byte 2 hex | byte 2 dec |
|---------------|-------|------------|------------|
| 11:04:41.292  | right | 0x3c       | **60**     |
| 11:04:41.294  | left  | 0x3c       | 60         |
| 11:05:45.926  | right | 0x3c       | 60         |
| 11:05:46.622  | left  | 0x3c       | 60         |
| 11:09:10.376  | right | 0x3c       | 60         |
| 11:09:10.491  | left  | 0x3c       | 60         |

Matches the on-screen "60%" exactly.

### Wear state

Reading the `F5 06`/`F5 07`/`F5 08`/`F5 0B` events as a timeline produces a
coherent narrative consistent with the user's actions during the capture:

```
11:04:35 F5 11           (just connected)
11:04:36 F5 08           in cradle, lid open
11:04:47 F5 06           worn       <- user put them on
11:05:41 F5 07           transitioning
11:05:43 F5 08           in cradle, lid open
11:06:19 F5 0B           in cradle, lid closed
11:06:27 F5 08           in cradle, lid open
11:06:39 F5 07           transitioning
11:06:43 F5 06           worn       <- worn again
11:07:57-11:08:19        9× F5 0A 64 (re-push burst while worn)
11:09:06 F5 08           in cradle, lid open
11:09:07 F5 0B           in cradle, lid closed
```

### `F5 12` is **brightness state echo**, not battery

I initially mis-read `F5 12` as a candidate battery push because byte 2
varied in 0..100 range. The wall-clock tells us the on-screen battery never
moved. Cross-checking the `F5 12` timestamps against TX `0x01 <level>
<auto>` brightness writes:

| TX brightness write at  | level | next `F5 12` at   | level mirrored |
|-------------------------|-------|-------------------|----------------|
| 11:07:01 `01 2a 01`     | 42    | 11:08:33 `f5 12 2a` | 42           |
| 11:07:33 `01 16 00`     | 22    | 11:07:42 `f5 12 16` | 22           |
| 11:07:14 `01 2a 00`     | 42    | (echoed in 11:08:33) | 42          |

So `F5 12 <byte2>` echoes whatever brightness level is currently in effect.
This is exactly the kind of confirmation channel a host would want when
adjusting brightness.

---

## What's now wired in the app

- `lib/services/device_status_service.dart` (new) holds the parsed values
  and exposes them via `ChangeNotifier`
- `lib/ble_manager.dart` calls `DeviceStatusService.get.ingestF5Event(...)`
  once per F5 event (before the gesture switch) and adds empty cases for
  6/8/10/11/15 so they don't trip the "Unhandled Ble Event" info log
- `lib/ble_manager.dart` resets device status on full disconnect
- `lib/services/glance_service.dart` appends the glasses % to the time line:
  `14:32  85%`
- `lib/views/home_page.dart` subscribes to the service and renders Glasses,
  Case, and State pills
- Logging via `AppLog` with tag `DeviceStatus`

`lib/services/companion_controller.dart` is intentionally untouched — device
status is not mode state, and AGENTS.md keeps mode ownership central. The
companion controller still drives gestures via the F5 dispatch unchanged.

---

## Open follow-ups

1. **`F5 09`/`F5 0E` substate semantics.** Both toggle 0/1 and pair tightly
   in time. The Python SDK calls `0x0E` "Cradle charging cable state changed";
   the 0/1 mapping (plugged vs unplugged, or vice versa) is not yet pinned
   down. A capture that deliberately plugs and unplugs the cradle cable
   would resolve this.
2. **`F5 11`, `F5 14`, `F5 15`, `F5 32`** remain in the `Unknown` list in
   `docs/even-g1-event-mapping.md`; this capture didn't move them.

Resolved since the snoop:
- Brightness control is now wired end-to-end: the home screen has a slider
  + auto switch that send `0x01 <level> <auto>`, and the firmware's `F5 12`
  echo drives a `Confirmed:` indicator next to the slider.

---

## Other novel opcodes spotted (not battery, but worth logging)

| Opcode | Direction | Cadence       | Notes                                                                                  |
|--------|-----------|---------------|----------------------------------------------------------------------------------------|
| `0x1f` | TX/RX     | every ~2 s    | Periodic exchange the official app uses in lieu of `0x25`. Format `1f <subcode> <seq>`. The current firmware accepts both `0x25` and `0x1f` heartbeats — this app's `0x25` heartbeat continues to work. |
| `0x6e` | RX        | once on connect | Firmware version string in ASCII: `"net build time: 2025-10-22 14:21:16, app build time 2025-10-22 14:20:59, ver 1.6.6, JBD DeviceId 4010"`. |
| `0x3e` | RX        | once on connect | Large 200+ byte device-info / calibration dump.                                        |
| `0x2c` | RX        | every ~10 s   | Periodic state push. Fixed 3-byte signature `66 64 64` then 17 bytes of state.         |
| `0xf1` | RX        | burst         | Sequence of 18 ~140-byte chunks at 11:08:32–34. Looks like a media or asset push.       |
| `0xc9` | (marker)  | various       | Recurs as byte-1 status marker on many response opcodes. Likely "OK" status.           |

The `0x6e` payload is potentially useful as a firmware version/build-id
signal in the connection area on the home page; tracked separately.
