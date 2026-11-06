# Findings: nav marker motion and map tile swaps (gate A)

**Date:** 2026-11-06
**Plan:** [plans/navigate-v1-cartographer.md](plans/navigate-v1-cartographer.md), phase 1
**Firmware:** 1.6.6 (decomp branch `1.66_exact`, `435c138`)
**Device:** S24 Ultra + G1, both lenses
**Harness:** `tool/nav_harness.py` + the debug probe's batch mode (`BleManager.kt`)
**Verdict:** **Gate A passes.** Marker motion is clean; panoramic and mini-map swaps are clean
and fast enough for occasional tile changes. No kill criterion was met.

## What the glasses actually show

`Confirmed` on device, matches the source (`src/ui/ui_navigation_map.c`):

| Head position | Page | Contents |
|---|---|---|
| Level (normal walking view) | **overview** | clock; road text (`road_name`, 64 B); turn distance; total time + distance line; the **built-in direction arrow** (`direction`, under the text on the left); the **136x136 `MAP_OVERVIEW` mini-map** on the right |
| Tilted up | **panoramic** | the **488x136 `PANORAMIC_MAP`** with the **position marker**; speed / time / distance in a 76 px column on the left |

The page is chosen per lens from the IMU (`nav->imu_action_status == 2`, set from `imu.mode`
in `src/threads/threads.c:1955-1966`). The position marker exists **only on the panoramic page**.
The head-level view has no marker; what moves there is the arrow, the text and whatever the
mini-map shows.

This matters for the plan: the per-second marker move is a tilt-up feature. The always-visible
map is the 136x136 mini-map, which is cheap to replace (see below).

Simulated head-up (`0x05 01 01`, debug control) is acked (`05 c9`) but did not switch the nav
page on device. Testing the panoramic page needs a real tilt.

## Formats (from source, all accepted on device)

All `0x0a` packets: `0a <len16 LE> <seq> <sub> ...`, total length validated.

**PANORAMIC_MAP (sub 3)**: `0a <len16> <seq> 03 <total16> <idx16> <flag> <payload<=185>`
- 10-byte header, `idx` 1-based. `flag` (byte 9) is stored as `nav->panoramic`; 0 works.
- Buffer `PANORAMIC_MAP_SIZE` = `0x40d0` = 16,592 B = **two 1-bit layers of 8,296 B**
  (488x136/8). Layer 1 at offset 0, layer 2 at `+0x2068` (`panoramic_map_mask`).
- **Raw only**, no RLE. 90 packets (89 x 185 + 127).
- Layers are drawn by `gui_bitmps_merge_draw(..., color1=2, color2=0xf)`: layer 1 is a **dim**
  grey, layer 2 is **full bright**. So it is a three-level image (off / dim / bright), not a
  bitmap plus a transparency mask. Use dim for context streets, bright for the route.
- Pixel packing: row-major, 61 bytes per row, **bit 0 = leftmost pixel**.
- Drawn at screen x `X0+0x58`..`X0+0x240`, y `Y0`..`Y0+0x88`.

**MAP_OVERVIEW (sub 2)**: `0a <len16> <seq> 02 <total16> <idx16> <payload<=185>`
- 9-byte header. Buffer `0x1210` = 4,624 B = two layers of 2,312 B (136x136/8), same
  dim/bright layering and packing (17 bytes per row).
- A received size of **exactly 4,624 B is treated as raw**; any other size is RLE-decoded
  (`<count><byte>` pairs). Send whichever is smaller.
- Drawn at `X0+0x1b6`..`X0+0x240` (the right-hand box on the overview page).

**TRIP_STATUS (sub 1)**: unchanged from `protocol-reference.md`. `x` (<=488) and `y` (<=136)
place the marker; a change in either sets `nav_pos_updated`, which redraws map + marker without
resending the bitmap.

## Marker motion (test 1)

1 Hz sweep: four corners, centre, left-to-right along y=68 in 24 px steps, top-to-bottom along
x=244 in 8 px steps, one out-of-range step.

- **Clean.** Steps crisply each second, **no flicker** of the map on redraw, **aligned in both
  eyes**, reaches every corner.
- Glyph is a small **circle** (firmware glyph `0x5f`, drawn from `pos_x - 6`, `pos_y - 6`, so
  about 12 px, centred on the point).
- **Edge debris:** near the map edges the part of the circle outside the map rectangle is never
  cleared (the redraw only clears the map area). **Keep the marker 6 px inside every edge:
  `x` in 6..482, `y` in 6..130.**
- Faster cadences (500 / 250 ms) were generated (`fast500.txt`, `fast250.txt`) but not run;
  1 Hz is the design rate.

## Image swaps (tests 3 and 5)

Transfer time is measured from the batch mark to the **last-packet ack** in logcat. Write
completion on Android returns much earlier and is not a delivery measure.

| What | Packets per lens | First packet to last ack | Seen on device |
|---|---|---|---|
| Panoramic, boot | 90 | R 1.85 s, L 2.7 s | |
| Panoramic swap, both lenses in parallel | 90 | L 2.3-2.4 s (L is the slower lens) | clean switch, no blank, no tearing, eyes in sync |
| Mini-map swap, raw | 25 | L ~0.65 s | R slightly ahead of L at 2 s cadence; hardly noticeable at 5 s |
| Mini-map swap, RLE (horizontal-structure image) | 8 | L ~0.28 s | as above |

Swaps every 2 s and 5 s while the marker kept moving at 1 Hz: Eddie's verdict "super clean and
crisp ... position marker updated throughout, both eyes completely in sync". An occasional
panoramic swap (once per 100-200 m) is **acceptable**. The mini-map can be swapped far more
often than that.

Mini-map image design affects cost: RLE pays off on horizontal runs (rows of identical bytes),
and is worse than raw on fine vertical detail. Cartographer should send the smaller of the two.

The left lens lagging on the mini-map swap is the same ordering issue as below; the panoramic
swaps used the master-last hold and were in sync.

## Two lifecycle rules found on device

Both cost a test run each; neither is in the old docs.

1. **Clear first.** `0x0a` INIT does **not** take over a live `0x4E` text surface (Capture's
   idle HUD stayed up; every packet was acked; nothing drew). Send `0x18` and wait about 400 ms
   before INIT. In Glance mode the screen happened to be idle, so this did not show up there.
2. **Master last.** The left lens (slave) only leaves "route is being generated" for RUNNING
   on a UI event pushed from the master, and RUNNING needs both maps on *that* lens. The left
   receives its maps about a second after the right, so if the right finishes first, the
   master's event reaches the left too early and the left stays stuck at head level until the
   next tilt. Fix that worked: send everything to both legs in parallel **except the right
   lens's final `PANORAMIC_MAP` packet**, which goes once the left has finished (the harness
   waits 2 s; production should wait for the left's last-packet ack instead). Apply the same to
   mini-map swaps to remove the left-lens lag.

Also seen: the master queues its `0x0a` responses (`send_response_data_to_msgqueue`), so R's
INIT, TRIP_STATUS and last-packet acks arrive late or not at all on the phone; L posts them at
once. Use L's acks for transfer timing and progress.

## Built-in arrows (test 4)

`direction` 1-0x23 selects firmware bitmap `direction + 0x60`, drawn on the overview page
under the road text. All 35 rendered on both lenses and all were legible and distinct ("odd
roundabouts, U-turns and partial turns, all rendered wonderfully").

| Value | Arrow (names from ayroblu `DirectionTurn`, see `protocol-reference.md`) |
|---|---|
| 0x01 | straight (dot) |
| 0x02 | straight |
| 0x03 | right |
| 0x04 | left |
| 0x05 | slight right |
| 0x06 | slight left |
| 0x07 | sharp right |
| 0x08 | sharp left |
| 0x09 | U-turn left |
| 0x0a | U-turn right |
| 0x0b | merge |
| 0x0c-0x23 | roundabout and other variants: all render; **per-value meaning not recorded** |

Per-value naming of 0x0c-0x23 was not captured in this session. It is needed before phase 4
maps routing manoeuvres onto this table: photograph each one, or read the bitmaps out of the
firmware image with the Even-G1-Simulator.

`0x00` and values above `0x23` draw no arrow (`navigation_direction_img_display` bounds check).

## Closed: on-device nav simulator

`spec_ble_command_hook` (`src/ble/ble_proto.c:4592`) has a navigation simulator, but it injects
the legacy JSON `navigation_info` format, not the `0x0a` binary card. Not a useful test path.

## Running the harness

```
python3 tool/nav_harness.py push          # generate batch files and adb push them
python3 tool/nav_harness.py run t1_sweep.txt
python3 tool/nav_harness.py stop
adb logcat -s G1Probe                     # marks, acks, timing
```

Sessions are self-contained (clear, boot, test, exit), because nav drops about 19 s after the
last SYNC. Put the app in a mode that does not draw on its own (Capture, not recording);
Glance's notification close sends `0x18` and kills nav mid-test.

| File | Test |
|---|---|
| `t1_sweep.txt` | 1 Hz marker sweep (tilt up to see it) |
| `t2_fast.txt` | 500 / 250 ms sweeps (not run) |
| `t3_swap.txt` | panoramic swaps every 2 s and 5 s (tilt up) |
| `t4_arrows.txt` | arrows 1-0x23, 2 s each (head level) |
| `t5_ovswap.txt` | mini-map swaps every 2 s and 5 s (head level) |
| `t0_headup.txt` | simulated head-up (no visible effect) |
