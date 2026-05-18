# Protocol Reference

> **Document type:** G1 reference
> **Audience:** Anyone integrating with or reverse-engineering the Even Realities G1
> **Evidence basis:** HCI snoop captures + live testing, firmware 1.6.6; supplemented by vendor demo material where noted

This file is a wire-level command catalogue for the Even G1 BLE protocol, built from HCI snoop captures of the official Android app and live device testing. Some older entries originate from vendor demo material; where these conflict with capture evidence, prefer the capture-backed finding.

Confidence hierarchy when sources conflict:
  1. Observed device behaviour (capture-backed or live-tested)
  2. [even-g1-event-mapping.md](even-g1-event-mapping.md) (event catalogue)
  3. Vendor/demo material (labelled `Vendor-claimed only` below)

Use this file as a command-family reference, not a definitive semantic truth source — the event mapping and FINDINGS docs are more precisely evidenced for the topics they cover.

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
  - `Vendor-claimed only` for firmware behaviour
  - current Flutter code can route `F5 01` as paging
  - live testing has **not** confirmed reliable app-visible single taps in the flows we care about

Important:
- do not document or build product behaviour as if `F5 01` is a proven single-tap input for this app

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
  - aligns with user-observed triple-tap silent-mode behaviour

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
- mic-disable / clean stop semantics are still not proven strongly enough to document as settled behaviour

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
- [android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt](../android/app/src/main/kotlin/com/eddie/evencompanion/bluetooth/BleManager.kt)
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

### Confirmed packet header layout

The 9-byte `0x4E` header, derived from the MentraOS `G1Text.kt` font-width
table and confirmed against live device rendering (2026-05-18):

| Byte | Field | Notes |
|------|-------|-------|
| 0 | `0x4E` | Opcode |
| 1 | `textSeqNum` | Monotonic per-send sequence counter |
| 2 | `totalChunks` | Total number of chunks for this text block |
| 3 | `i` | Current chunk index (0-based) |
| 4 | `screenStatus` | `0x71` = `0x01` (new content) \| `0x70` (text show) |
| 5 | `new_char_pos0` | New character position, low byte |
| 6 | `new_char_pos1` | New character position, high byte |
| 7 | `page` | Current page (0-based; 0 for single-page sends) |
| 8 | `totalPages` | Total pages (1 for single-page sends) |
| 9..end | body | UTF-8 text payload, max `MAX_CHUNK_SIZE = 176` bytes |

**Display constants** (firmware 1.6.6, confirmed via pixel-width measurements):
- `DISPLAY_WIDTH = 488` pixels
- `LINES_PER_SCREEN = 5`
- `MAX_CHUNK_SIZE = 176` bytes per chunk body

**`screenStatus = 0x71`** is the standard value for new text content: lower
bits `0x01` = display new content; upper bits `0x70` = text-show mode. This
aligns with the vendor/demo labelling above.

Multi-page support (the `page` / `totalPages` fields) exists in the protocol
but is not commonly used — most sends are single-page (`page=0`, `totalPages=1`).

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

## Live streaming text: `0x52` / `0x53`

Source:
- 2026-04-28 layouts capture, Phase 3 (live transcription) — full write-up
  in [FINDINGS-layouts.md](FINDINGS-layouts.md)
- confirmed and refined through live testing + BLE capture analysis,
  2026-04-29 through 2026-05-01

Observed reality (`Confirmed`, 2026-05-01):

### Wire protocol

- `0x50 06 00 00 01 01` — display mode init, sent before the first `0x52`
  frame (see "Display mode control" below)
- `0x52 06 00 00 01 01` — streaming text mode init
- `0x53` — keepalive, sent every 5 seconds to prevent firmware timeout
- Text update packet:
  ```
  52 <len> 00 <seq> 02 02 00 <line> 00 <flags> 00 00 <text_utf8> 0a
  ```
  `<line>` = line index (01 or 02); `<flags>` at byte position 9:
  `0x00` during normal updates, `0x01` at session start and paragraph
  transitions (not required for basic operation). Each update re-sends the
  full current line content (not a delta).

### Official app line model (`Confirmed`, 2026-05-01)

From BLE capture analysis of the official Even Realities app:

- **Line 1** = cursor/status marker. A regular text packet for line
  index 1, sent every update with text content `\n`. This is NOT a special
  cursor frame — it is the same `0x52` text packet format as line 2.
- **Line 2** = ALL text content. The full growing response text goes to
  line index 2. The firmware handles visual rendering (wrapping, scrolling).
- **Every update sends both packets** — line 1 marker then line 2 text.
- No "cursor frame" exists as a distinct concept. What was previously
  identified as a cursor frame (`52 0e 00 <seq> 02 02 00 01 00 00 00 00
  0a 0a`) is just a text packet for line 1 with `\n` content.
- No confirmed-flag management is needed.

### Firmware display characteristics (`Confirmed`, 2026-05-01)

- **3 visible text rows** on the display
- **~43 characters per row** (proportional font, varies slightly)
- **No native scrolling** — the firmware displays whatever text it receives
  on line 2, wrapped at its display width, but does NOT scroll when text
  exceeds the visible area
- The firmware wraps text at its own display width AND respects embedded
  `\n` characters as explicit line breaks
- Text mid-word wrapping occurs when a word crosses the display boundary
  (firmware does not word-wrap, only character-wrap)

### Scrolling (host-managed)

The firmware does NOT auto-scroll. The host must manage the visible window:

- The companion app wraps text with `\n` at ~43-char word boundaries, then
  keeps only the **last 3 lines** (matching the 3 visible rows)
- As new content wraps to a 4th line, the oldest line is trimmed from the
  front of the text
- Visual effect: text grows word by word on the bottom row. When that row
  fills, the top row disappears and new content starts at the bottom.

### Implementation

- the companion app uses `0x52` for Chat assistant replies via a paced
  `StreamingRenderQueue` — see
  [chat_service.dart](../lib/services/chat_service.dart) and
  [streaming_render_queue.dart](../lib/services/streaming_render_queue.dart)
- `0x50 06 00 00 01 01` must be sent before the first `0x52` frame
- if streaming is unavailable, Chat can fall back to `0x4E` text blocks
- `StreamingRenderQueue` pacing: 2 words every 200 ms (~450 WPM effective
  with BLE send overhead)
- each tick: adds 2 words to displayed text, wraps with `\n` at 43-char
  word boundaries, keeps last 3 lines, sends line 1 (`\n`) + line 2
  (visible text) via `Proto.sendStreamingLine`
- backend chunks are decoupled from display — chunks append to a target
  buffer, the queue drains independently
- queue keeps draining after the backend completes until all words are
  displayed, then signals completion via `onDrained` callback
- display flow: user question shown via `0x4E` → "Thinking..." via `0x4E`
  → fresh `0x52` surface → queue streams response → response stays visible
  with keepalive
- follow-up turns: `startListening` does `Proto.exit()` only when a prior
  `0x52` session is active (avoids BLE destabilisation on marginal
  connections)
- key constants: `_displayLineWidth = 43`, `_displayVisibleRows = 3`,
  `wordsPerTick = 2`, `drainInterval = 200ms`

### Previous incorrect approaches (superseded)

1. **Multi-line indices (lines 1-4)** with host-managed wrapping and
   confirmed/active flags — firmware only renders lines near the cursor
   position, so only 1-2 lines were visible
2. **Single line 2 without embedded `\n`** — firmware fills visible area
   and stops, no scrolling
3. **Single line 2 with `\n` but no tail trimming** — firmware fills
   visible area and stops (firmware does not auto-scroll)
4. **Sending cursor frame before line 2 text** — the official app doesn't
   do this; the "cursor frame" is actually a line-1 text packet with `\n`
   content
5. **`_capForPacket` truncation at 230 chars** — wrong; the BLE stack
   handles larger packets, and the `0x52` length byte wrapping with
   `& 0xff` doesn't matter since the firmware uses the BLE packet length

## Navigation card: `0x0a`

Source:
- 2026-04-28 layouts capture, Phase 4 (Google Maps navigation) — full
  write-up in [FINDINGS-layouts.md](FINDINGS-layouts.md)
- Cross-referenced against Gadgetbridge `G1Constants.java`
  (`NavigationSubcommand` names) and `ayroblu/bazel-demo` Swift
  implementation (`commands+device.swift` directionsData structure).
  See [external-protocol-wiki-notes.md](external-protocol-wiki-notes.md).

Observed reality (`Confirmed`):

- TX `0x0a` pushes structured navigation card data to the glasses. The
  firmware has a built-in card template; the host fills text fields and
  optionally supplies icon + map bitmaps.
- Sub-command names (from Gadgetbridge `G1Constants.NavigationSubcommand`):
  - `0x00` = INIT — enter navigation display mode
  - `0x01` = TRIP_STATUS — the text/direction data card
  - `0x02` = MAP_OVERVIEW — direction icon bitmap (136×136, RLE encoded)
  - `0x03` = PANORAMIC_MAP — route map bitmap (488×136, unencoded)
  - `0x04` = SYNC — commit/render signal (sent BEFORE and AFTER card data)
  - `0x05` = EXIT — properly leave navigation mode
  - `0x06` = ARRIVED — navigation complete

- Control frames:
  - `0a 06 00 <seq> 00 01` — INIT (enter navigation display mode)
  - `0a 06 00 <seq> 04 01` — SYNC (prepare / commit)
  - `0a 06 00 <seq> 05 01` — EXIT (leave navigation mode)
  - `0a 06 00 <seq> 06 01` — ARRIVED (navigation complete)

- Official app sequence per update:
  INIT → SYNC → TRIP_STATUS → MAP_OVERVIEW ×13 → PANORAMIC_MAP ×90 → SYNC
- **Sub-type 1 — TRIP_STATUS** (one packet per card update):
  ```
  0a <len> 00 <seq> 01 <DirectionTurn> <x0> <x1> <y> 00
    <totalDuration_utf8> 00 <totalDistance_utf8> 00 <roadName_utf8> 00 <turnDistance_utf8> 00 <speed_utf8> 00
  ```
  Decoded prefix from snoop: `01 03 c8 00 12 00` = sub-cmd TRIP_STATUS,
  DirectionTurn=Right(0x03), x=[0xc8,0x00], y=0x12, null separator.
  Five null-separated text fields follow (the Swift implementation confirms
  the 5th field is speed).
  Observed: `"26 min" \0 "2.2km" \0 "Church Road " \0 "46m" \0 "0.0km/h" \0`
  — 48 bytes total.

  DirectionTurn enum values (from ayroblu Swift implementation, 0x01–0x23):
  StraightDot=0x01, Straight=0x02, Right=0x03, Left=0x04,
  SlightRight=0x05, SlightLeft=0x06, SharpRight=0x07, SharpLeft=0x08,
  UTurnLeft=0x09, UTurnRight=0x0a, Merge=0x0b, plus roundabout variants
  (0x0c–0x23). Full list in
  [external-protocol-wiki-notes.md](external-protocol-wiki-notes.md).
  The companion app classifies manoeuvres via `classifyManoeuvre()` in
  `nav_icon_generator.dart`, parsing both `navIconSource` and instruction
  text for direction keywords.
- **Sub-type 2 — MAP_OVERVIEW (direction icon)** (`02`):
  `0a <len> 00 <seq> 02 <bandCount> 00 <bandNum> 00 <RLE chunk>` — 9-byte
  header + up to 185 bytes of RLE payload per band. Typically 13 bands for
  a 136×136 pixel icon. The image is **two layers** (image + overlay)
  concatenated = 4,624 raw bytes. Overlay is all-zeros for direction icons.
  **RLE format**: simple `<count> <byte>` pairs, count capped at 255.
  Confirmed from ayroblu/bazel-demo Swift source (`runLengthEncode()`).
  **Pixel layout**: row-major, LSB-first bit packing (NOT column-major as
  previously assumed). Pixel (x, y) is at bit `(x % 8)` of byte
  `(y * 17 + x ~/ 8)`. `toBytes()` packs 8 consecutive bools per byte,
  bit 0 (LSB) = first pixel in the group.
  The companion app scrapes the Google Maps notification icon PNG
  (`navIconPngBase64`), decodes to 136×136 monochrome via alpha threshold,
  RLE-encodes, pads to 13 bands, and frames as MAP_OVERVIEW packets.
  Geometric arrow generation exists as fallback.
- **Sub-type 3 — PANORAMIC_MAP (route map)** (`03 5a`):
  `0a c3 00 <seq> 03 5a 00 <row> <~187 bytes>` — 90 rows (`5a` = 90) for a
  488×136 pixel map. Data is **unencoded** raw bitmap (not RLE).

Notes:
- all three sub-types (TRIP_STATUS + MAP_OVERVIEW + PANORAMIC_MAP) are
  **required** for the firmware to render a card — text-only or dummy-data
  cards are rejected with "Navigation service lost"
- the firmware requires a **continuous 1-second SYNC poller** (`0x04`)
  running for the entire navigation session. Without it, the firmware
  times out after a few seconds. The official app sends 86 SYNC packets
  over a 70-second nav session at exactly 1-second intervals.
- `0x50` mode control is required before the first INIT
- fire-and-forget writes (`sendData`) are the correct transport — the
  firmware does not ack `0x0a` commands
- sending 108 packets (~20KB) to both legs simultaneously requires pacing
  and per-leg transport care to avoid BLE buffer overflow and connection drops
- the current confirmed debug transport in the companion app is an
  **interleaved per-leg fire-and-forget replay**:
  packet `i` to right, wait 10 ms, packet `i` to left, wait 20 ms, and
  pause 50 ms every 10 packet pairs. Broadcast mode could starve a leg;
  full sequential per-leg replay was stable but introduced a visible
  multi-second eye gap

## Dashboard data slots: `0x1e` TX

Source:
- 2026-04-28 layouts capture, Phases 1–2 (dashboard cycling + quicknote
  sync) — full write-up in [FINDINGS-layouts.md](FINDINGS-layouts.md)

Observed reality (`Confirmed` for note content push):

- TX `0x1e` pushes titled content into the firmware's dashboard grid slots.
  The firmware renders the layout; the host only supplies the data.
- Short form (refresh / activate widget): `1e 06 00 <seq> 01 01`
- Content form:
  ```
  1e <len> 00 <seq> 03 01 00 01 00 <slot_index> 01 <title_len> <title_utf8> <body_len> 00 <body_utf8>
  ```
- Observed payloads:
  - "Test Note 2" + "This is a test quick note."
  - "Keyword Research" + "Focus on the keyword: Banana Chocolate."
  (both confirmed against the on-screen dashboard rendering)

Notes:
- `0x1e` is heavily overloaded — it appears in three distinct roles:
  TX dashboard content push (this section), TX QuickNote audio
  request/ack, and RX QuickNote audio stream. See "QuickNote protocol
  family" below for the full `0x1e` disambiguation table.
- the `0x06` three-step transaction family handles the transactional
  framing around dashboard updates; `0x1e` carries the actual slot content.

## Display mode control: `0x50`

Source:
- 2026-04-28 layouts capture — fires at every mode transition

Observed reality (`Confirmed`):

- TX `0x50 06 00 00 01 01` — identical 6-byte packet fired before every
  mode entry (transcription, navigation, return to idle).
- The payload is constant regardless of which mode follows; the mode is
  implicit in which data opcode (`0x52` or `0x0a`) arrives next.
- Likely means "clear display and prepare for structured content."

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
  `29 65 <pct> 00 ...`, but a polling path is not required for live readings.
  Note: the JohnRThomas wiki claims byte 3 of the `0x29` response is an auto
  flag; two empirical probes on firmware 1.6.6 returned byte 3 = `0x00`
  regardless of auto state — see `docs/external-protocol-wiki-notes.md`
  ("0x29 brightness get") for the full analysis and open questions.

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

## `0x06` transaction family

`0x06` is a general-purpose transactional wrapper. The firmware accepts a
consistent three-step structure for multiple operations; the sub-codes in
step 2 identify the payload type. Two variants are currently known.

### Variant A — Note management: delete / reorder (`0x06 ... / 0x22` ack)

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

### Variant B — Time-set (`0x06 01` payload)

Source:
- current companion app `Proto.setTimeAndWeather()` (commit dc9d959, 2026-05-18)
- not observed in HCI captures; derived from shipped app code

Observed reality (`Confirmed`, shipped code):

- the companion app sends a three-step `0x06` transaction to both legs on
  connect to sync the wall-clock time with the glasses:
  ```
  TX  06 07 00 <seq1>   06 00 00                              — request
  TX  06 16 00 <seq2>   01 <epoch32-LE> <epoch64-LE> <4 bytes>  — payload (22 bytes total)
  TX  06 0c 00 <seq3>   03 01 00 01 00 00 00 01               — finalise
  ```
- the `seq` counter increments across all three steps
- the `0x22` ack observed for note management has not been confirmed for
  time-set (no capture evidence; behaviour consistent with note-management
  framing)

**Epoch encoding (important):** both `epoch32` and `epoch64` carry
**local wall-clock time encoded as if it were UTC** — i.e. the UTC epoch
plus the local timezone offset in milliseconds, so that the firmware can
treat the value as a simple seconds-since-midnight counter without needing
timezone metadata. This is NOT a true UTC timestamp. `epoch32` is a
`uint32` little-endian seconds value; `epoch64` is an `int64` little-endian
milliseconds value. Both encode the same instant.

Example computation (`Proto.setTimeAndWeather()`):
```dart
final localOffsetMs = now.timeZoneOffset.inMilliseconds;
final localSec     = (now.millisecondsSinceEpoch + localOffsetMs) ~/ 1000;  // epoch32
final localMs      = now.millisecondsSinceEpoch + localOffsetMs;             // epoch64
```

Notes:
- the same `0x06` three-step framing is used for note management (Variant A
  above), confirming this is a general transactional pattern, not specific
  to notes
- prior to the 2026-05-18 fix, the app sent `now.millisecondsSinceEpoch`
  (true UTC) which caused the glasses clock to display UTC time rather than
  local time

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
- `F5 12` is also emitted as a passive push ~15 s after connect, carrying
  the firmware's current level before any host write; see
  [FINDINGS-battery+brightness.md](FINDINGS-battery+brightness.md)
  § "`F5 12` on-connect timing"
- the ambient light sensor is on the right temple (confirmed via live
  testing — covering the right arm changes applied brightness; covering the
  left arm has no effect); see FINDINGS-battery+brightness.md §
  "Ambient light sensor is on the right arm"
- the JohnRThomas wiki claims `0x29` response byte 3 is an auto flag; two
  empirical probes on firmware 1.6.6 returned byte 3 = `0x00` — see
  [external-protocol-wiki-notes.md](external-protocol-wiki-notes.md)
  § "0x29 brightness get" for the analysis

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
- the companion app sends `0x25` per leg every 2 seconds (matching the
  official app's observed p50 cadence), starting a per-leg timer immediately
  on connect rather than sharing a single broadcast timer

## QuickNote protocol family

Sources:
- 2026-04-28 recon HCI snoop (`logs/quicknote/btsnoop_hci.log`) — official
  Even Realities app traffic; parsed as
  `logs/bluetooth/traffic.csv` / `logs/bluetooth/summary.txt`
- 2026-05-08 / 2026-05-09 live device testing — custom companion app on
  firmware 1.6.6, right-temple long-press, multiple cycles
- Full evidence write-up: [FINDINGS-quicknote.md](FINDINGS-quicknote.md)

The QuickNote path is entirely separate from the left-temple Even AI path.
Both ultimately carry LC3 audio, but they use different opcodes, different
triggering handshakes, and different stream framing. See "Comparison with
left-temple Even AI" at the end of this section.

The opcode `0x1e` is overloaded across three distinct uses:

| Direction | Sub-code / form | Meaning |
|-----------|-----------------|---------|
| TX host→glasses | `1e <len> 00 <seq> 03 01 ...` | Dashboard slot content push (see "Dashboard data slots" above) |
| TX host→glasses | `1e 06 00 <seq> 02 <idx>` | QuickNote audio request |
| TX host→glasses | `1e 06 00 <seq> 04 01` | QuickNote audio received acknowledgement |
| RX glasses→host | `1e c8 00 <seq> 02 <field> 00 <seq+1> 00 01 <payload>` | QuickNote audio stream chunk |
| RX glasses→host | `1e 06 00 <seq> 04 00` | QuickNote stream-end confirmation |

Disambiguate by direction and the second byte: `0xc8` (or any value in the
audio-length range) signals an audio chunk; `0x06` with payload `04 00` or
`04 01` is a control frame.

---

### Right-temple long-press release: `0x21`

`Confirmed` (2026-05-08, live device, multiple cycles)

The `0x21` frame fires on **release** of a sufficiently long right-temple
press. There is no corresponding press-down event (contrast with the
left-temple `F5 17` press-down / `F5 18` release pair).

Two payload variants have been observed:

#### 15-byte variant (single-note release)

```
21 0f 00 <seq> 01 01 01 <8 bytes note data>
```

Observed in the 2026-04-28 recon (single right-press cycle, official Even
Realities app). Byte 1 = `0x0f` = 15 (total frame length). This appears
to be a "just saved this specific note" release.

Example: `21 0f 00 0a 01 01 01 ec 16 f1 69 ac c2 41 cc`

Byte map:

| Bytes | Value | Meaning |
|-------|-------|---------|
| 0 | `21` | Opcode |
| 1 | `0f` | Frame length (15) |
| 2 | `00` | Constant |
| 3 | `0a` | Sequence |
| 4–6 | `01 01 01` | Constant prefix |
| 7–14 | `ec 16 f1 69 ac c2 41 cc` | Note UID / data |

The 8-byte tail at bytes 7–14 matches the UID structure used in the `0x06`
note-management transactions (see "Note management" section). `Suspected`:
this field is the UID of the just-saved note.

#### 42-byte variant (notes-list metadata dump)

```
21 2a 00 <seq> 01 <count> <count × (1-byte index + 8 bytes data)>
```

`Confirmed` (2026-05-08, live device). Byte 1 = `0x2a` = 42 (total frame
length). This variant is emitted by firmware 1.6.6 on the custom companion
app at every right-temple long-press release, regardless of display state.
The firmware interprets it as a **notes-list metadata dump**: a complete
enumeration of all currently stored notes.

Example: `21 2a 00 17 01 04 01 f7 ce 93 65 ed c4 be e4 02 90 cf 93 65 f8
22 06 e3 03 cc cf 93 65 5e 38 18 1a 04 36 d0 93 65 3a 90 44 a2`

Byte map:

| Bytes | Value | Meaning |
|-------|-------|---------|
| 0 | `21` | Opcode |
| 1 | `2a` | Frame length (42) |
| 2 | `00` | Constant |
| 3 | `17` | Sequence (increments per press: `0x13`, `0x15`, `0x16`, `0x17` observed) |
| 4 | `01` | Constant |
| 5 | `04` | Note count (4 stored notes in this sample) |
| 6 | `01` | Index of first record |
| 7–14 | `f7 ce 93 65 ed c4 be e4` | Record 1 data — 4-byte timestamp-like field + 4 bytes UID |
| 15 | `02` | Index of second record |
| 16–23 | `90 cf 93 65 f8 22 06 e3` | Record 2 data |
| 24 | `03` | Index of third record |
| 25–32 | `cc cf 93 65 5e 38 18 1a` | Record 3 data |
| 33 | `04` | Index of fourth record |
| 34–41 | `36 d0 93 65 3a 90 44 a2` | Record 4 data |

The repeating `xx xx 93 65` pattern across records is consistent with
Unix timestamps (seconds since epoch, little-endian, upper bytes `93 65` =
2026-era timestamps). This supports the interpretation that each record
carries a creation timestamp and a 4-byte note UID.

**Circular 4-slot buffer** (`Suspected`): the firmware appears to maintain
a fixed 4-slot circular buffer. Indices are `01..04`. Across multiple
recording sessions, the same-indexed slot changes its 8-byte data while
other slots remain constant — consistent with oldest-slot replacement on
each new note. "Circular" is inferred from this pattern across a single
live session; direct observation of slot wrap-around (note 5 overwriting
note 1) has not yet been captured.

**Diff-based new-note detection** (`Confirmed`, 2026-05-08): to identify
which note was just recorded, compare the current 42-byte payload against
the previously stored one. The record whose 8-byte data changed is the
newly recorded note. Do not assume "highest index = newest" — the circular
buffer means the newest slot may have any index.

**Which variant will you see?** (`Suspected`): the 15-byte variant was
observed only in the 2026-04-28 recon with the official Even Realities
app. The 42-byte variant was observed exclusively in 2026-05-08 live
testing with the custom companion app. Whether the firmware selects the
variant based on app state, connection flags, firmware version, or some
other factor is not yet known.

---

### Host-initiated audio request handshake

`Confirmed` (2026-05-08, re-analysis of 2026-04-28 recon TX traffic)

**The firmware does NOT stream audio unsolicited.** After the `0x21`
release, the host must explicitly request audio. Without this request, the
firmware sends nothing.

The full handshake, observed in the 2026-04-28 recon capture:

| Step | Dir | Delay from `0x21` | Hex | Meaning |
|------|-----|-------------------|-----|---------|
| 1 | RX | 0 ms | `21 0f 00 0a 01 01 01 ec 16 f1 69 ac c2 41 cc` | Right-press release (`0x21`, 15 bytes) |
| 2 | **TX** | +11 ms | **`1e 06 00 41 02 01`** | **Host requests audio for note index 01** |
| 3 | RX | +63 ms | `1e c8 00 00 02 31 00 01 00 01 <190 bytes>` | First audio chunk (seq 0x00) |
| … | RX | … | 47 more `1e c8` chunks | seq 0x01..0x2f |
| 4 | RX | +358 ms | `1e 5a 00 30 02 31 00 31 00 01 <80 bytes>` | Trailing chunk, shorter (seq 0x30) |
| 5 | **TX** | +386 ms | **`1e 06 00 42 04 01`** | **Host acknowledges audio received** |
| 6 | RX | +430 ms | `1e 06 00 42 04 00` | Glasses confirm cycle closed |

**Audio request frame structure:**
```
1e 06 00 <seq> 02 <noteIndex>
```
- `1e` = opcode (same `0x1e` channel as the audio)
- `06` = total frame length (6 bytes)
- `00` = constant
- `<seq>` = host's monotonically incrementing sequence counter; observed
  starting at `0x41` in the recon. The firmware appears to accept any
  value.
- `02` = "send audio" sub-command
- `<noteIndex>` = the 1-based index of the note to retrieve. Use `01`
  after a 15-byte `0x21` (only one note context). For a 42-byte `0x21`,
  use the index of the slot whose data changed (diff detection).

**Acknowledgement frame structure:**
```
1e 06 00 <seq> 04 01
```
Sent by the host after the audio stream is complete. The firmware responds
with `1e 06 00 <seq> 04 00` to confirm the cycle is closed.

---

### Audio stream: `0x1e c8 ...` chunks

`Confirmed` (2026-04-28 recon capture, confirmed against 2026-05-08 live
device — audio decoded to speech)

Every audio chunk has the form:

```
1e c8 00 <seq1>  02 <field5>  00 <seq2>  00 01  <190 bytes audio payload>
```

| Byte(s) | Example | Meaning |
|---------|---------|---------|
| 0 | `1e` | Opcode |
| 1 | `c8` | `0xc8` = 200 for full-size chunks. **This byte is the total chunk length in bytes**, not a fixed magic constant. The trailing (shorter) chunk uses `0x5a` = 90. |
| 2 | `00` | Constant |
| 3 | `seq1` | Monotonic sequence 0x00..0x30 across a cycle |
| 4 | `02` | Constant |
| 5 | `31` | Field of unknown meaning — `0x31` in 2026-04-28, `0x61` in an earlier capture. Possibly a session ID or codec variant. Does not affect decoding. |
| 6 | `00` | Constant |
| 7 | `seq2` | Equals `seq1 + 1` (so 0x01..0x31) |
| 8–9 | `00 01` | Constant |
| 10..end | — | Audio payload (190 bytes for full chunks; shorter for the trailing chunk) |

**Byte 1 serves double duty:** it is the total chunk length AND an implicit
"is this an audio chunk" signal. Any `0x1e` frame where byte 1 is outside
the plausible audio-length range (e.g. `0x06` for control frames) is not
an audio chunk and signals stream end.

**Stream-end detection:** watch for any `0x1e` notification where byte 1
is NOT in the audio-chunk range (approximately `0x40..0xc8`). In the recon
capture this was `1e 06 00 42 04 00`. A 500 ms watchdog timeout is an
additional safety net.

**Stream statistics** (2026-04-28 recon, one complete cycle):
- 48 audio chunks total (47 full + 1 trailing)
- 47 × 190 + 80 = 9,010 payload bytes
- ~295 ms from first to last `0xc8` chunk
- Consistent with a ~3–5 second recording at LC3 compression ratios
- For a typical 3–8 second note: expect 30–55 chunks

---

### Audio codec and frame slicing

`Confirmed` (2026-05-08, successfully decoded to speech)

- **Codec:** LC3 (same codec as the live-mic `0xF1` path)
- **Sample rate:** 16 kHz, mono, 16-bit PCM after decode
- **LC3 frame size: 200 bytes** — this matches the live-mic `0xF1` path
  (which slices at `value.copyOfRange(2, 202)`, i.e. 200-byte frames)
- **BLE chunk payload: 190 bytes** per full chunk (200-byte BLE frame minus
  the 10-byte header)

**Critical:** LC3 frame boundaries do NOT align with BLE chunk boundaries.
Each BLE chunk carries 190 bytes of payload, but each LC3 frame is 200
bytes. The correct decode procedure is:

1. Concatenate all payload bytes (stripping the 10-byte header from each
   chunk) into a single byte array.
2. Slice the concatenated array at 200-byte intervals.
3. Decode each 200-byte slice as one LC3 frame.

Slicing at 190-byte intervals (following chunk boundaries) produces
audible clicks because each "frame" straddles two real LC3 frames.

---

### Diff-based note detection

`Confirmed` (2026-05-08, live device)

When the 42-byte `0x21` variant is in use, the host cannot assume that the
highest-indexed slot is the newest recording. The circular buffer may write
to any slot. To find the just-recorded note:

1. Cache the previous `0x21` payload on every release.
2. On the next `0x21` release, compare the 8-byte data for each slot
   against the cached version.
3. The slot whose 8-byte data differs from the cached value is the new
   recording.
4. Use that slot's index as `<noteIndex>` in the audio request frame.

---

### Comparison with left-temple Even AI flow

| Aspect | Left temple (Even AI) | Right temple (QuickNote) |
|--------|----------------------|--------------------------|
| Press-down event | `F5 17` (RX) | None |
| Release event | `F5 18` (RX) | `0x21` (RX) — on release only |
| Host triggers mic | `0x0e 01` (TX) — sent on `F5 17` | `1e 06 00 <seq> 02 <idx>` (TX) — sent on `0x21` |
| Audio stream | `0xF1 <seq> <LC3>` (RX) | `0x1e c8 00 <seq> ... <LC3>` (RX) |
| Host ends mic | `0x0e 00` (TX) — sent on `F5 18` | `1e 06 00 <seq> 04 01` (TX) — sent after stream ends |
| Codec | LC3, 200-byte frames | LC3, 200-byte frames |
| Recording locus | Live — mic streams in real time | Pre-recorded — firmware stores on-glasses, streams on request |

Both paths use the LC3 codec at 200-byte frames. The key architectural
difference is that the Even AI path streams audio live from the mic as the
user speaks, whereas QuickNote records on-glasses and transfers the
complete audio buffer only when the host explicitly requests it.

See also:
- [FINDINGS-quicknote.md](FINDINGS-quicknote.md) — full evidence write-up
  including raw frame tables, chunk counts, and open questions
- [even-g1-event-mapping.md](even-g1-event-mapping.md) — event catalogue
