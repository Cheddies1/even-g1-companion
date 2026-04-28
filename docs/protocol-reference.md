# Protocol Reference

Warning:
- this file is a raw vendor/demo protocol reference consolidated from the old project README and related demo material
- it is **not** ground truth by itself
- when vendor/demo notes conflict with live testing, prefer:
  1. observed device behavior
  2. current app behavior
  3. [even-g1-event-mapping.md](even-g1-event-mapping.md)

Use this file as a command-family reference, not as a definitive semantic truth source.

## Confidence labels used here

- `Confirmed`: observed in current app/device testing
- `Suspected`: plausible and partially aligned with testing
- `Vendor-claimed only`: preserved from demo/vendor material but not confirmed enough

## Related docs
- [even-g1-event-mapping.md](even-g1-event-mapping.md)
- [investigation-notes.md](investigation-notes.md)
- [python-sdk-comparison-notes.md](python-sdk-comparison-notes.md)

## Touch / gesture family: `0xF5`

### `0xF5 0x00`

- Vendor/demo meaning:
  - exit to dashboard manually
  - close feature / turn off detail view
- Observed reality:
  - `Confirmed`
  - best current meaning is close active feature / return home

### `0xF5 0x01`

- Vendor/demo meaning:
  - single tap
  - page up/down control in manual mode
  - dashboard QuickNote / notification detail interactions
- Observed reality:
  - `Vendor-claimed only` for firmware behavior
  - current Flutter code can route `F5 01` as paging
  - live testing has **not** confirmed reliable app-visible single taps in the flows we care about

Important:
- do not document or build product behavior as if `F5 01` is a proven single-tap input for this app

### `0xF5 0x02`

- Vendor/demo meaning:
  - not clearly documented in the old README
- Observed reality:
  - `Confirmed`
  - best current meaning is dashboard open / tilt-up start

### `0xF5 0x03`

- Vendor/demo meaning:
  - not clearly documented in the old README
- Observed reality:
  - `Confirmed`
  - best current meaning is dashboard close / tilt-down start

### `0xF5 0x04` / `0xF5 0x05`

- Vendor/demo meaning:
  - triple tap / silent mode toggle
- Observed reality:
  - `Suspected`
  - aligns with user-observed triple-tap silent-mode behavior

### `0xF5 0x17`

- Vendor/demo meaning:
  - long-press / start Even AI
- Observed reality:
  - `Suspected` at protocol level, `Confirmed` as the current app’s connected left-hold voice entry path

### `0xF5 0x18`

- Vendor/demo meaning:
  - stop Even AI recording
- Observed reality:
  - `Confirmed`
  - paired with `F5 17` press-down on every left long-press in the
    2026-04-28 taps capture; never observed without a preceding `F5 17`
  - right long-press (QuickNote) does not fire `F5 17` / `F5 18` — see the
    `R21` section below

### `0xF5 0x20`

- Vendor/demo meaning:
  - not described in the old README excerpt
- Observed reality:
  - `Confirmed`
  - fires when a double-tap triggers an official-app double-tap action that
    is **host-handled** (transcribe / translate / teleprompter); fires for
    both temples
  - does **not** fire when the configured action is firmware-native
    (Dashboard) or "None" — those are handled locally below the BLE boundary
  - the close-an-active-feature half of double-tap continues to fire
    `F5 00`, not `F5 20`
- Implementation:
  - this app routes `F5 20` to a mode-switch handler in
    [companion_controller.dart](../lib/services/companion_controller.dart)
  - see [FINDINGS-taps.md](FINDINGS-taps.md)

Notes:
- the BLE event is fired 1–6 s after the physical gesture, suggesting it's
  emitted when the firmware's feature-open animation completes rather than on
  the gesture edge
- the on-glasses overlay for the configured action (Transcribe's listening
  prompt etc.) still appears briefly; companion repurposing of the event for
  mode switching does not suppress that overlay

### `0xF5 0x1E` / `0xF5 0x1F`

- Vendor/demo meaning:
  - not present in the old README
- Python SDK meaning:
  - dashboard open/close confirm
- Observed reality:
  - `Suspected` to `medium-high`
  - current best model:
    - `0x1E` = dashboard/state-up follow-on
    - `0x1F` = dashboard/state-down follow-on

### `0x22` dashboard-family packets

- Vendor/demo meaning:
  - not described in the old README
- Python SDK meaning:
  - dashboard packet family
- Observed reality:
  - `Suspected`
  - seen during firmware-dashboard-related runs
  - payload semantics still unknown

## Old demo “Start Even AI” notes

Preserved from vendor/demo material:
- command family: `0xF5`
- subcmd `0`: exit to dashboard manually
- subcmd `1`: page-up/page-down control in manual mode
- subcmd `23`: start Even AI
- subcmd `24`: stop Even AI recording

Observed reality:
- subcmd `0` concept aligns with `F5 00` close/home
- subcmd `1` remains untrusted as a product input for this app
- the old Even AI path existed in the demo app, but this project no longer treats that as the primary product model

## Glasses mic enable / disable: `0x0E`

Vendor/demo reference:
- command: `0x0E`
- enable `1` = enable mic
- enable `0` = disable mic
- response status:
  - `0xC9` success
  - `0xCA` failure

Observed reality:
- mic enable is `Confirmed` enough for the current app path
- the app has used mic-on successfully for the old connected voice flow and for current capture scaffolding
- mic-disable / clean stop semantics are still not proven strongly enough to document as settled behavior

## Glasses mic audio packets: `0xF1`

Vendor/demo reference:
- command: `0xF1`
- `seq`: sequence number
- `data`: LC3 audio chunk payload

Observed reality:
- `Confirmed`
- the app receives mic audio packets
- native code decodes LC3 to PCM
- this path is now reused for Capture-mode WAV recording scaffolding

Relevant implementation:
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](../android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
- [android/app/src/main/cpp/liblc3.cpp](../android/app/src/main/cpp/liblc3.cpp)

## Text / AI result sending: `0x4E`

Vendor/demo reference:
- command: `0x4E`
- fields:
  - `seq`
  - `total_package_num`
  - `current_package_num`
  - `newscreen`
  - `new_char_pos0`
  - `new_char_pos1`
  - `current_page_num`
  - `max_page_num`
  - `data`

Old vendor/demo “AI result” status notes:
- lower bits:
  - `0x01` = display new content
- upper bits:
  - `0x30` = Even AI displaying
  - `0x40` = Even AI display complete
  - `0x50` = Even AI manual mode
  - `0x60` = Even AI network error

Old vendor/demo “Text sending” status notes:
- lower bits:
  - `0x01` = display new content
- upper bits:
  - `0x70` = text show
- example:
  - `0x71` = new content + text show

Observed reality:
- `Confirmed` at the command-family level
- the app uses `0x4E` for text rendering today
- field-level transport structure is broadly consistent with the vendor/demo description
- the old Even AI-specific semantic labels should be treated as historical/demo framing, not as current product truth

## BMP transfer

Vendor/demo reference:

### BMP data packet: `0x15`
- `seq`
- first packet includes address `[0x00, 0x1c, 0x00, 0x00]`
- packet carries BMP bytes

### Transmission end: `0x20`
- fixed command: `[0x20, 0x0d, 0x0e]`

### CRC check: `0x16`
- CRC32/XZ big-endian over address + BMP data

Observed reality:
- `Confirmed` enough for the earlier bitmap experiments and demo features
- image transfer path exists and works in this repo
- but bitmap dashboard rendering is no longer treated as the primary UX path for the companion app

## Battery and wear state: `0xF5`

Source:
- official-app HCI snoop captured from this repo's target hardware on
  firmware 1.6.6 — full write-up in
  [FINDINGS-battery+brightness.md](FINDINGS-battery+brightness.md)

Observed reality (`Confirmed`):

- `F5 06` — wearing
- `F5 07` — transitioning
- `F5 08` — in cradle, lid open
- `F5 0A <pct>` — glasses battery percentage push (byte 2, range 0..100)
- `F5 0B` — in cradle, lid closed
- `F5 0F <pct>` — case (cradle) battery percentage push (byte 2, range 0..100)

Notes:
- both temples emit these events independently; the app accepts whichever
  arrives most recently
- battery is push-based — there is no need to poll
- while worn, `F5 0A` is re-pushed every ~1–2 s; while cradled it goes quiet
  until the value changes
- the official Even Realities Android app also implements a polled fallback
  via a single-byte `0x29` write to the right glass with response
  `29 65 <pct> 00 ...`, but a polling path is not required for live readings

Implementation:
- ingestion: [lib/services/device_status_service.dart](../lib/services/device_status_service.dart)
- routed from the F5 dispatch in [lib/ble_manager.dart](../lib/ble_manager.dart)

Cross-reference:
- [even-g1-event-mapping.md](even-g1-event-mapping.md) "Battery and wear state"

## Head-up settings: `0x08 06 00 00 03 <value>`

Source:
- 2026-04-28 settings capture cycling the official Even Realities app's
  "head-up" / tilt-up behaviour menu — see
  [FINDINGS-settings.md](FINDINGS-settings.md)

Observed reality (`Confirmed`):

- TX `0x08 06 00 00 03 <value>` to both legs persists the head-up behaviour
  on the glasses themselves
- verified values:
  - `0x00` — the firmware's own dashboard appears on tilt-up
  - `0x02` — no firmware overlay on tilt-up; the glasses still emit
    `F5 02` / `F5 03`, leaving the host to drive any visible response
- the value at byte 4 (`0x03`) is the head-up sub-key; the baseline capture
  also contains writes with byte 4 = `0x04`, which is a different unmapped
  setting in the same family
- writes are sent to both legs at near-identical timestamps and persist
  across an app uninstall — the official app sets, the firmware remembers

Implementation:
- TX command: [Proto.setHeadUpMode](../lib/services/proto.dart)
- UI / persistence:
  [DeviceStatusService](../lib/services/device_status_service.dart)
  + [AppSettingsStore](../lib/services/app_settings_store.dart)
  + the "Firmware Settings" section on the
  [Settings page](../lib/views/settings_page.dart)

## Touch settings: `0x26 06 00 <seq> 05 <value>`

Source:
- same 2026-04-28 settings capture, cycling the official app's "double-tap
  action" menu through every option

Observed reality (`Confirmed` for the double-tap sub-key):

- TX `0x26 06 00 <seq> 05 <value>` to both legs persists the double-tap
  action on the glasses themselves
- verified values for sub-key `0x05`:
  - `0x00` — none / "close active feature"
  - `0x02` — translate
  - `0x03` — teleprompter
  - `0x04` — open the firmware's own dashboard locally
  - `0x05` — transcribe (host-handled — fires `F5 20`, which the companion
    app routes to a passive mode cycle)
- byte 3 `<seq>` is a transaction sequence the official app increments
  monotonically per change; the firmware appears to accept any value
- baseline traces show writes with sub-keys `0x02` and `0x08` at byte 4
  (different lengths, different shapes); these are likely triple-tap or
  long-press configurations and are not yet isolated

This is the wire-level explanation for the F5 20 matrix in
[even-g1-event-mapping.md](even-g1-event-mapping.md): values `0x02`,
`0x03`, `0x05` are the host-handled actions; `0x04` is firmware-native;
`0x00` only emits `F5 00` when there's something to close.

Implementation:
- TX command: [Proto.setDoubleTapAction](../lib/services/proto.dart)
- UI / persistence: same triplet as Head-up settings

## Quicknote post-release stream: `0x1e c8 ...`

Source:
- 2026-04-28 settings capture, Phase 3 (right-hold quicknotes of varying
  duration: ~10 s long, ~5 s short, ~3 s silence)

Observed reality (`Suspected`, medium confidence — structure is clear but
codec is not yet decoded):

- after every `0x21` quicknote-release (the `R21` family already
  documented), the firmware emits a chunked binary stream back to the host
  on opcode `0x1e`
- per-chunk framing:
  ```
  1e c8 00 <seq1> 02 61 00 <seq2> 00 01 <~130 bytes binary data>
  ```
  with `seq1` and `seq2 = seq1 + 1` increasing monotonically through each
  burst
- frame counts scale with recording duration (~50 frames for 3 s silence,
  ~100 frames for 10 s) at ~140 bytes per chunk and ~10 frames/s — roughly
  11 kbit/s, in the range of low-bitrate voice codecs like LC3
- byte distribution and sequencing are consistent with **encoded audio**;
  not yet decoded

Notes:
- this is the BLE path the user can tap to recreate the firmware's
  quicknote behaviour in the companion app (record → on-device or hosted
  transcription → stored note)
- decode work would start with the existing LC3 path in
  [android/app/src/main/cpp/liblc3.cpp](../android/app/src/main/cpp/liblc3.cpp)
- out of scope for the current code; documented as a future feature

## Note management: `0x06 ... / 0x22` ack

Source:
- 2026-04-28 settings capture, Phase 4 (delete / reorder of saved notes
  in the official app's note list)

Observed reality (`Suspected`, structural):

- delete and reorder both produce a clean three-step transaction on opcode
  `0x06`, sent to both legs:
  ```
  TX  06 07 00 <seq>   06 00 00                                       — request
  TX  06 16 00 <seq+1> 01 <8-byte note UID> d4 9d 01 00 00 02 10 00 00 02   — payload
  TX  06 0c 00 <seq+2> 03 01 00 01 00 00 00 01                        — finalise
  ```
- each TX echoed back as RX, then `RX 22 05 00 <seq+3> 01 00 01 00` ack
- the 8-byte note UID structure looks identical to the trailing block in
  `R21` payloads, suggesting `R21` advertises the UID of the just-saved
  note

Notes:
- out of scope for the current app
- a future "delete a saved note from the companion app" feature would need
  the UID, plausibly recoverable either from `R21` payloads or from a
  not-yet-identified list-all opcode

## Brightness: `0x01 <level> <auto>` and `F5 12 <level>`

Vendor/demo reference:
- not described in the old README excerpt

Observed reality (`Confirmed`):

- TX `0x01 <level> <auto>` sets the brightness, where `level` is 0..42 and
  `auto` is 0/1 (1 enables firmware-driven auto brightness)
- RX `F5 12 <level>` is pushed by the glasses whenever the active brightness
  level changes; byte 2 mirrors the most recently applied level
- the auto flag is not echoed back; it is tracked locally from the last sent
  command

Implementation:
- TX command: [Proto.setBrightness](../lib/services/proto.dart)
- RX ingestion + auto-flag tracking:
  [DeviceStatusService](../lib/services/device_status_service.dart)
- UI: a Display section on the home screen with a level slider and an Auto
  Brightness switch; the slider commits its value on release, the switch sends
  the current level with the new auto flag.

Notes:
- the brightness command is sent as a fire-and-forget broadcast write, the
  same pattern the official Even Realities app uses for this command
- when auto brightness is on, the firmware adjusts the actual displayed
  level; the home screen shows the most recent echoed level under
  "Confirmed:" so the user can see the difference between requested and
  applied values

Important — byte/decimal note:
- `F5 12` is hex; in the Flutter dispatch in
  [lib/ble_manager.dart](../lib/ble_manager.dart)
  the F5 sub-code is read as a raw byte and matched as a decimal integer, so
  the brightness echo is handled at `case 18:` (= `0x12`). Reviewers comparing
  hex sub-codes against `case` arms in `_describeF5Event`/the dispatch switch
  should keep that conversion in mind.

## Heartbeat: `0x25`

Vendor/demo reference:
- not clearly described in the old README excerpt

Observed reality:
- `Confirmed`
- `0x25` is the active heartbeat request/response family in the current app logs
- the official Even Realities app uses a different periodic exchange
  (`0x1f`) at ~2 s cadence; firmware accepts both, so the `0x25` heartbeat in
  this app remains valid

## QuickNote / `0x21`

Vendor/demo reference:
- not described in the old README excerpt

Observed reality:
- `Suspected`
- right-hold QuickNote behavior is best explained by a release-time `R21` packet family
- payload meaning is still unknown
- do not overstate this beyond current investigation notes

See:
- [investigation-notes.md](investigation-notes.md)
- [python-sdk-comparison-notes.md](python-sdk-comparison-notes.md)
