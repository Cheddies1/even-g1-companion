# G1 BLE — settings opcodes & quicknote post-release stream

> **Document type:** G1 reference
> **Audience:** Anyone integrating with or reverse-engineering the Even Realities G1
> **Evidence basis:** HCI snoop captures + live testing, firmware 1.6.6

Source: `btsnoop_hci.log` (5.6 MB, 2026-04-28 15:28–15:39 UTC), official Even
Realities Android app, firmware 1.6.6. Wall-clock annotations in
`wall clock settings.md`.

Tooling: `analyze_settings.py`. Baseline references:
`btsnoop_hci_baseline.log`, `btsnoop_hci_taps.log`.

---

## TL;DR

| Setting             | TX command                              | Confirmed values                                                                  |
|---------------------|-----------------------------------------|-----------------------------------------------------------------------------------|
| Head-up mode        | `08 06 00 00 03 <value>` to both legs   | `0x00` = dashboard, `0x02` = none                                                  |
| Double-tap action   | `26 06 00 <seq> 05 <value>` to both legs | `0x00` = none, `0x02` = translate, `0x03` = teleprompter, `0x04` = dashboard, `0x05` = transcribe |

Both follow the same shape as the brightness command (`0x01 <level> <auto>`)
— short fixed-width settings opcodes. Both are sent to **both** legs at
roughly the same instant in the official app's traffic.

`R21` (right-hold quicknote) was also captured cleanly. After the user
releases the right-hold, the firmware emits the existing `0x21` release
event and then immediately streams a chunked binary blob back to the host
on opcode `0x1e`. Volume scales with recording duration, consistent with
encoded audio (likely LC3 or similar). The user's "PCM stream comes down"
hypothesis is corroborated; the family is `0x1e`, not `0xf1`.

---

## Head-up mode — `0x08 06 00 00 03 <value>`

Wall-clock anchors and matching writes:

| wall-clock                    | annotation                  | TX (left+right) within ±2 s |
|-------------------------------|-----------------------------|------------------------------|
| 15:29:11                      | head-up = dashboard         | `08 06 00 00 03 00`          |
| 15:29:32                      | head-up = none              | `08 06 00 00 03 02`          |
| 15:29:47                      | head-up = dashboard         | `08 06 00 00 03 00`          |
| 15:30:09                      | head-up = none              | `08 06 00 00 03 02`          |

Decoded structure:
```
08         opcode = head-up settings family
06         total length (= 6 bytes)
00         reserved / always zero in this family
00         reserved / always zero
03         category byte — 0x03 = "head-up mode"
<value>    setting value:
             0x00 = dashboard
             0x02 = none
             other values not tested in this capture
```

Notes:

- Both temples receive the identical write at near-identical timestamps.
  The official app writes to one and then the other ~10–20 ms apart; the
  setting takes effect once both are ack'd.
- Baseline capture also contained `08 06 00 00 04 00`, which has category
  byte = `0x04`. This is a *different* setting in the same family, not yet
  identified — likely another head-up-related option (notification widget,
  time, etc.) the user didn't toggle in either capture.
- 0x01 hasn't been observed for the value byte. The official app's head-up
  menu may have a third option we didn't capture (a follow-up exhaustively
  cycling the menu would resolve it, but the two values we have cover the
  user's actual ask).

---

## Double-tap action — `0x26 06 00 <seq> 05 <value>`

Wall-clock anchors and matching writes:

| wall-clock                    | annotation                            | TX (left+right) within ±2 s |
|-------------------------------|---------------------------------------|------------------------------|
| 15:31:00                      | double-tap = none                     | `26 06 00 05 05 00`          |
| 15:31:10                      | double-tap = dashboard                | `26 06 00 06 05 04`          |
| 15:31:20                      | double-tap = transcribe               | `26 06 00 07 05 05`          |
| 15:31:30                      | double-tap = translate                | `26 06 00 08 05 02`          |
| 15:31:40                      | double-tap = teleprompter             | `26 06 00 09 05 03`          |
| 15:31:50                      | double-tap = none (confirm)           | `26 06 00 0a 05 00`          |

Decoded structure:
```
26         opcode = touch settings family
06         total length (= 6 bytes)
00         reserved / always zero in this 6-byte form
<seq>      transaction sequence — strictly incremented by the official app:
             5, 6, 7, 8, 9, 0a in the observed run
05         category byte — 0x05 = "double-tap action"
<value>    action value:
             0x00 = none / close active feature
             0x02 = translate
             0x03 = teleprompter
             0x04 = dashboard
             0x05 = transcribe
             0x01 not observed — likely an unused or untested action slot
```

This maps perfectly onto the F5 20 experimental matrix from the previous
capture: actions `0x02`, `0x03`, `0x05` are the three "host-handled" cases
that emit `F5 20`; action `0x04` (dashboard) is firmware-native and does not
emit `F5 20`; action `0x00` (none) only emits `F5 00` when there's something
to close.

Notes:

- The sequence byte at offset 3 increments monotonically as the user makes
  changes. It probably exists for transaction tracking (the firmware may
  reject duplicates, though that's untested). Safe approach for the
  companion app: maintain a session-local counter that increments on each
  send.
- Baseline contained `26 06 00 00 08 00` and an 8-byte variant
  `26 08 00 00 02 00 07 03`. These are **different sub-categories of the
  0x26 family** (category bytes `0x08` and `0x02`), not double-tap settings.
  Likely cover triple-tap, long-press, or other touch configs we haven't
  isolated.

---

## R21 / right-hold quicknote — confirmed plus a new observation

Three quicknote events with clean wall-clock anchors:

| wall-clock                  | duration | RX 0x21 hex                                       |
|-----------------------------|----------|----------------------------------------------------|
| 15:33:00 press → 15:33:10   | ~10 s    | `21 0f 00 09 01 01 01 34 d3 f0 69 2e 03 bc 51`     |
| 15:34:00 press → 15:34:05   | ~5 s     | `21 0f 00 00 01 01 01 6c d3 f0 69 e7 96 7d 80`     |
| 15:34:20 press → 15:34:23   | ~3 s     | `21 0f 00 00 01 01 01 80 d3 f0 69 da bb 35 33`     |

Confirms the previous taps capture: `R21` is fired on right-hold release,
length 15 in current firmware. The 8-byte trailing block is plausibly a
timestamp/UID for the saved note.

### New observation — `0x1e` chunked stream after release

Immediately after each `0x21` release event, the firmware streams a chunked
binary blob back to the host on opcode `0x1e`. Frame counts scale with
recording duration:

| quicknote      | recording length | RX 0x1e burst frames |
|----------------|------------------|-----------------------|
| long           | ~10 s            | ~100                  |
| short          | ~5 s             | ~60                   |
| silence        | ~3 s             | ~50                   |

Per-frame structure (typical chunk):
```
1e         opcode (text/note family)
c8         sub-status (= 200 — distinct from the 0xc9 = 201 "OK" we see elsewhere)
00         reserved
<seq1>     chunk sequence number (increments 0x00, 0x01, 0x02, …)
02 61 00   constant marker (or sub-header)
<seq2>     forward-seq (= seq1 + 1)
00 01      constant
<~130 bytes of binary data>
```

Sequence numbers count up monotonically through each burst (0x00..0x28+).
The byte distribution looks like compressed binary content rather than
plaintext — consistent with **encoded audio** (e.g. LC3, the same codec
the live mic stream uses on `0xf1`). At ~140 bytes per frame and ~10
frames/s, that's roughly 11 kbit/s, which is in the range of low-bitrate
voice codecs like LC3.

This validates the user's hypothesis — right-hold *does* stream the
recording to the host, just on a different opcode than left-hold's live
mic. To turn this into a usable feature we'd need to:

1. Capture the burst into a buffer keyed off the `0x21` event
2. Strip the per-chunk framing (`1e c8 00 <seq1> 02 61 00 <seq2> 00 01`)
3. Concatenate the data payloads
4. Try to decode with the existing LC3 path (
   [android/app/src/main/cpp/liblc3.cpp](../android/app/src/main/cpp/liblc3.cpp))
   — if it isn't LC3, we'd have to identify the codec or treat as raw

That's a real chunk of work and is left as a future ticket; for now the
finding is documented as evidence the path exists.

---

## Note-management commands (delete / reorder) — out of scope but worth a note

The wall-clock noted three management actions; each produced a clean
3-step transaction on the **`0x06` family** (left + right):

```
TX  06 07 00 <seq>   06 00 00                                — request
TX  06 16 00 <seq+1> 01 <8-byte note UID> d4 9d 01 00 00 02 10 00 00 02   — payload
TX  06 0c 00 <seq+2> 03 01 00 01 00 00 00 01                 — finalize
```

with matching RX echoes and a final `RX 22 05 00 <seq+3> 01 00 01 00` ack.

The 8-byte note UIDs vary per note; the rest of the payload is constant.
Building a "delete note from companion app" feature would require either:

- knowing the UIDs of existing notes (possibly recoverable from the `0x1e`
  post-save burst — that 8-byte block in `R21` looks like the same UID
  format)
- or some sync/list query opcode to enumerate them

Both are interesting future work but well beyond the user's current ask.
The 0x06 family is the closest thing observed to a "transactional note
management protocol".

---

## What I'd do with these findings

1. **Wire `setHeadUpMode(value)` and `setDoubleTapAction(value)`** into
   `Proto.dart`. Two short methods, identical shape to `setBrightness`.
2. **Surface them in the home-screen Display section** (or a new Settings
   pane): a dropdown for head-up mode and a dropdown for double-tap
   action, both saving to `DeviceStatusService` state for the in-app
   display + actually sending the BLE write.
3. **Special case** that motivated this whole investigation: the user
   wants head-up = none and double-tap = (any host-handled action).
   A "first connect" path could send these on connect to ensure the
   companion behaviour is consistent — but that overrides whatever the
   user has set in the official app, which is invasive. Recommend
   exposing both as user-controllable settings instead, with the
   companion-app default being "leave alone".
4. **Document `0x1e` quicknote burst** in `protocol-reference.md` and
   `even-g1-event-mapping.md` as a future audio-decode opportunity.
5. **Document `0x06` note management** with the same caveat.

---

## Implemented (2026-04-28)

- `Proto.setHeadUpMode(int value)` and `Proto.setDoubleTapAction(int value)`
  added in [`lib/services/proto.dart`](../lib/services/proto.dart),
  matching the existing `setBrightness` shape (broadcast write, fire-and-forget,
  `tag: 'DeviceStatus'` debug log). The double-tap method maintains a
  session-local sequence counter at byte 3.
- [`lib/services/device_status_service.dart`](../lib/services/device_status_service.dart)
  now defines `HeadUpMode` and `DoubleTapAction` enums with `displayLabel`
  and `wireValue` extensions, plus public `setHeadUpMode` / `setDoubleTapAction`
  async methods that orchestrate the BLE write and the persistence call.
- [`lib/services/app_settings_store.dart`](../lib/services/app_settings_store.dart)
  persists the user's last picks under `firmware.head_up_mode` and
  `firmware.double_tap_action` `SharedPreferences` keys (enum-name strings).
- [`lib/views/settings_page.dart`](../lib/views/settings_page.dart)
  has a new "Firmware Settings" section between Notification Filters and
  Permissions, with two dropdowns. Both are disabled when no leg is
  connected. The companion app deliberately does not re-send these on
  reconnect.
- Documentation propagated into `docs/protocol-reference.md`,
  `docs/even-g1-event-mapping.md`, `docs/investigation-notes.md`,
  `docs/current-architecture.md`, `docs/current-behaviour.md`,
  `docs/current-worklist.md`, and `AGENTS.md`.

Out of scope from this pass (deliberately): wiring the `0x1e` quicknote
audio decode, and any UI for the `0x06` note-management family.
