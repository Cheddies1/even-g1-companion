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
  - `Suspected`
  - often accompanies the end of the current app’s voice flow

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
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
- [android/app/src/main/cpp/liblc3.cpp](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/cpp/liblc3.cpp)

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

## Heartbeat: `0x25`

Vendor/demo reference:
- not clearly described in the old README excerpt

Observed reality:
- `Confirmed`
- `0x25` is the active heartbeat request/response family in the current app logs

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
