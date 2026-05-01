# G1 BLE — taps & long-press capture findings

> **Document type:** G1 reference
> **Audience:** Anyone integrating with or reverse-engineering the Even Realities G1
> **Evidence basis:** HCI snoop captures + live testing, firmware 1.6.6

Source: `btsnoop_hci.log` (11.8 MB, 2026-04-28 14:06–14:21 UTC), official Even
Realities Android app, firmware 1.6.6. Wall-clock annotations in
`wall clock taps.md`.

Parser/analysis: `parse_btsnoop.py` (re-used) and `analyze_taps.py` (new,
buckets every UART frame into a wall-clock phase).

Baseline: `btsnoop_hci_baseline.log` / `traffic_baseline.csv`.

---

## TL;DR

| Gesture                         | BLE event           | Notes                                      |
|---------------------------------|---------------------|--------------------------------------------|
| Single tap left (idle)          | **none**            | Confirmed firmware-only                    |
| Single tap right (idle)         | **none**            | Confirmed firmware-only                    |
| Single tap left (dashboard list)| **none**            | Confirmed firmware-only even with target   |
| Single tap right (dashboard list)| **none**           | Confirmed firmware-only even with target   |
| Triple tap                      | `F5 04` / `F5 05`   | silent on / silent off                     |
| Double tap (closes active feat) | `F5 00`             | Already Confirmed in docs                  |
| **Double tap (opens feature when configured to "transcribe")** | **`F5 20`** | **NEW** — fires for both left and right when double-tap setting = transcribe |
| Long-press LEFT (Even AI)       | `F5 17` → `F5 18`   | Press-down → release. F5 18 newly Confirmed |
| Long-press RIGHT (QuickNote)    | `0x21` only (no F5) | 15-byte payload in current firmware (docs say 42) |

The single biggest practical takeaway: **single taps are not surfaced over BLE in any tested state**, including with a pageable dashboard list visible. The firmware does react visibly to the taps (notes/notifications cycle on the glasses), but the event never crosses the BLE boundary. This is the strongest possible negative result for the "maybe firmware forwards taps when there's a target" hypothesis.

---

## Single-tap evidence (negative result)

Phases where a single tap was performed and verified against the trace within ±5 s:

- **14:08:40** right tap, idle: 0 F5 events; only `0x25` heartbeats and the periodic `0x2b` push.
- **14:09:10** right tap, idle: same — heartbeats and `0x2b` only.
- **14:10:49 / 14:10:55 / 14:11:00** left taps, idle: same.
- **14:13:10–20** right taps, dashboard list visible (cycling notes): 100+ RX frames in window, but **all of them are `0xf1` audio/asset stream**, `0x22` dashboard family, and `0x2c` periodic state pushes. **No F5 events attributable to the taps themselves.**
- **14:14:10–20** right taps, dashboard list visible: same pattern. The only F5 events are `02 / 1e / 03 / 1f` for the tilt-up-then-tilt-down boundaries.
- **14:14:30–40** left taps, dashboard list visible (notifications, empty queue): same.

Conclusion: paging behaviour the user sees on the glasses during dashboard interaction is **entirely firmware-local**. Tap events are consumed by the firmware and never forwarded to the host.

---

## Long-press: the asymmetry

Left and right long-press are handled by completely different event families.

### Left long-press (Even AI / voice)

Fires the F5 family, with a clean press-down/release pair:

| ts                          | side | event   | meaning                        |
|-----------------------------|------|---------|--------------------------------|
| 2026-04-28T14:10:05.414Z    | left | `F5 17` | press-down — long-press start  |
| 2026-04-28T14:10:07.869Z    | left | `F5 18` | release                        |
| 2026-04-28T14:10:35.919Z    | left | `F5 17` |                                |
| 2026-04-28T14:10:42.520Z    | left | `F5 00` | release / close-active variant |
| 2026-04-28T14:19:00.774Z    | left | `F5 17` |                                |
| 2026-04-28T14:19:08.021Z    | left | `F5 18` |                                |

`F5 18` was previously Suspected in the docs; this capture promotes it to Confirmed for the "voice-flow stop / long-press release" meaning.

### Right long-press (QuickNote)

Does **not** fire `F5 17` or `F5 18` at all. Instead, on release, it fires a single `0x21` notification on the right side:

| ts                          | hex                                                | corresponding wall-clock note            |
|-----------------------------|----------------------------------------------------|------------------------------------------|
| 2026-04-28T14:09:19.677Z    | `21 0f 00 01 01 01 01 8e bf f0 69 31 fe 92 c5`     | 14:09:15 accidental quicknote            |
| 2026-04-28T14:17:49.740Z    | `21 0f 00 03 01 01 01 8c c1 f0 69 10 4a c0 cf`     | 14:17:45–50 "this is a test quicknote"   |
| 2026-04-28T14:18:19.845Z    | `21 0f 00 00 01 01 01 aa c1 f0 69 85 65 c2 d3`     | 14:18:15–20 "this is a test quicknote 2" |

Structure (15 bytes total):
```
21 0f 00 <id> 01 01 01 <8 bytes>
```
- byte 0 = opcode
- byte 1 = `0x0f` (= 15, payload length minus opcode itself)
- byte 2 = `0x00` (constant marker)
- byte 3 = note id, observed values `0x01 / 0x03 / 0x00` (non-sequential — possibly wraps or skips deleted IDs)
- bytes 4–6 = `01 01 01` (constant)
- bytes 7–14 = 8 bytes that change every quicknote — almost certainly a timestamp or note UID

**Important — this contradicts the existing docs.** `even-g1-event-mapping.md` says `R21` is repeatedly length 42; in current firmware the QuickNote release payload is length 15. Three explanations are plausible:
1. Firmware behaviour changed since the original `R21` investigation.
2. The 42-byte packets observed previously were a different family member (e.g., a session-metadata push that doesn't fire in the simple speak-and-save flow tested here).
3. The packets concatenate differently when more notes exist; this user's note count was small.

In `lib/ble_manager.dart` the right-hold mode-switch POC currently gates on `res.data.length == 42`. With current firmware this gate would never fire. Not a problem today because the user pulled that feature, but worth noting for any future re-enablement.

---

## NEW event: `F5 20` — double-tap-opens-feature

The double-tap setting in the official Even Realities app was changed to "transcribe" mid-capture. After that change, double-tapping either temple to open the transcribe feature consistently fires `F5 20`:

| ts                          | side  | wall-clock event                                          |
|-----------------------------|-------|-----------------------------------------------------------|
| 2026-04-28T14:15:56.026Z    | right | 14:15:50 double right tap → started transcribe (~6 s lag) |
| 2026-04-28T14:16:49.884Z    | left  | 14:16:50 double left tap → started transcribe (~1 s lag)  |

Confidence: medium. The two samples line up with the only two double-tap-to-start events in the capture, and no `F5 20` fires anywhere else in the trace.

Caveats:
- **`F5 20` may be specific to the "transcribe" double-tap action**, not double-tap in general. Other configured actions (dashboard, Even AI, the firmware's own QuickFeature) might fire different sub-codes — or no event at all. We need a follow-up capture to confirm.
- The latency between the user's double-tap and `F5 20` is variable (1–6 s in this trace). It may be tied to when transcribe-mode finishes opening on the glasses, not to the tap itself.
- The opposite double-tap behaviour — closing an already-open feature — fires `F5 00`, not `F5 20`. So `F5 20` is "feature opened via double-tap" only.

If we want to use double-tap as a host-side trigger in the companion app today, the cheapest reliable path is:

1. User configures double-tap-left and/or double-tap-right to **transcribe** in the official app (the setting is persisted on the glasses).
2. Companion app subscribes to `F5 20` and treats it as a generic "double-tap fired" intent, ignoring the transcribe semantics on-device.
3. On `F5 00` while transcribe is "active" (we can infer this from a prior `F5 20`), treat as the close-half of the double-tap pair.

This isn't perfect (depends on a setting in another app, and the transcribe overlay still appears on the glasses), but it's the first observed BLE path for double-tap.

---

## Triple tap (silent mode)

Already partially documented. This capture firms it up:

| ts                          | side  | event   | wall-clock                                    |
|-----------------------------|-------|---------|-----------------------------------------------|
| 2026-04-28T14:07:48.418Z    | right | `F5 04` | "accidental triple tap to silence" @ 14:07:53 |
| 2026-04-28T14:07:48.426Z    | left  | `F5 00` | side-effect: close-active                     |
| 2026-04-28T14:07:52.407Z    | right | `F5 05` | "another to activate"                         |

Pattern: triple-tap-on → `F5 04` (and a `F5 00` close-active because silent suppresses anything visible); triple-tap-off → `F5 05`.

A second pair of `F5 04` / `F5 05` fires near the start of the transcribe phase (14:15:48 and 14:15:51) without an explicit user note. Most likely an accidental triple-tap during touch-bar fumbling immediately before the deliberate double-tap. Worth re-checking on a future capture but doesn't change the F5 04/05 = silent-toggle interpretation.

---

## Other things spotted (not tap-related)

- **`0xf1` audio/asset bursts on tilt-up to dashboard.** During phases 06 and 08 (~10 s windows centred on tilt-up to dashboard with notes visible), 100+ `0xf1 <seq> <30 bytes>` frames fire from the right side. Sequence numbers increment monotonically. This is the `0xF1` family the docs label as LC3 mic audio, but the user wasn't recording — the official app's dashboard interaction is causing it. Possible interpretations: the official app does ambient mic capture during dashboard for wake-word / preview, or `0xF1` is dual-purpose (audio AND content asset push). Not relevant to taps. Worth a separate investigation.
- **TX `0x4d`, `0x4e`, `0x52`, `0x53`, `0x54`, `0x55`** appear in this trace but not the baseline. `0x4e` is the known text-rendering opcode; the others are likely related families (`0x4d` close-text, the `0x5x` group probably state push). Out of scope for this pass.
- **`F5 0a` glasses battery push value drifted** between 0x5f (95%) and 0x60 (96%) during the capture. Confirms the battery push really does update mid-session.

---

## What I'd do with these findings

1. Update `docs/even-g1-event-mapping.md`:
   - Promote `F5 18` to Confirmed (left long-press release).
   - Add `F5 20` under Suspected → "double-tap-feature-open (currently observed for the configured 'transcribe' action only)".
   - Strengthen the single-taps note with the negative-result evidence: tested in idle and with a pageable dashboard list, never seen.
   - Note that the QuickNote `R21` payload is length 15 in current firmware (not 42).

2. Optionally wire the `F5 20` path in the companion app:
   - `BleManager._handleReceivedData` route `F5 20` into a new `CompanionController.handleDoubleTapStart()` hook.
   - The user can map it to whatever they want (mode switch, glance assistant, transcription, anything).
   - Document the dependency on the official app's double-tap setting clearly.
   - Pair it with `F5 00` for close-feature so the user can also handle the close-half of the gesture.

3. **Don't** try to handle single taps. The negative result is robust enough to stop investing in this path — they genuinely don't surface.

4. The `0xf1` dashboard bursts and the `0x4d/0x52–0x55` family are worth a separate session if the user wants to mine more useful opcodes from the official app, but they're orthogonal to taps.

5. Consider a focused follow-up capture that **changes the double-tap setting between phases** — try "Even AI", "Dashboard", "QuickNote", with double-tap on each, and watch which BLE event fires for each configured action. That would tell us whether `F5 20` is generic ("any double-tap action started") or specific to transcribe.

---

## Implemented (2026-04-28)

- `F5 20` is now wired into the companion app:
  - `BleManager` F5 dispatch routes `case 32:` (= 0x20) to
    `CompanionController.handleDoubleTapModeSwitch()`
  - the controller cycles modes `Glance` → `Navigate` → `Chat` → `Capture` →
    `Glance` (via `AppMode.nextMode`), debounced at 1500 ms
  - no idle-only gate: when a feature is up the firmware emits `F5 00`
    (close-active) instead, which the existing close-active path already
    handles
- The `_describeF5Event` label for `case 32` was updated from
  `unknown-background-state-32` to `double-tap-feature-open`
- Documentation updated across `docs/even-g1-event-mapping.md`,
  `docs/protocol-reference.md`, `docs/current-architecture.md`,
  `docs/current-behaviour.md`, `docs/current-worklist.md`,
  `docs/investigation-notes.md`, and `AGENTS.md`
- Open user-facing test: confirm the mode cycle works, then change the
  official app's double-tap action to something other than transcribe and
  see whether `F5 20` (and therefore the cycle) still fires.

### Live test results (2026-04-28, follow-up)

User confirmed the wiring works as intended: double-tap from idle cycles
modes consistently; double-tap with anything on the glasses display fires
the existing `F5 00` close-active path, exactly as the firmware behaviour
predicted.

Cycling the official Even app's double-tap action through every choice
gave a clean classification of `F5 20`:

| official-app double-tap action | `F5 20` fires? | mode cycle works? |
|--------------------------------|----------------|--------------------|
| Transcribe                     | yes            | yes                |
| Translate                      | yes            | yes                |
| Teleprompter                   | yes            | yes                |
| Dashboard                      | no             | no — firmware shows the dashboard locally even with the official app force-stopped |
| None / Close active feature    | no             | no — only `F5 00` fires, and only when something is open to close |

So `F5 20` is the **generic "double-tap delegates to host" event**: it fires
whenever the configured action requires the host (mic / network / text
rendering), and is swallowed by the firmware whenever the action can be
fulfilled locally. The Suspected confidence in
`docs/even-g1-event-mapping.md` and `docs/protocol-reference.md` was bumped
to Confirmed and the docs now record the experimental matrix.
