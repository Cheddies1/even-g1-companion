# Firmware decompilation notes — `JohnRThomas/even_realities_decomp`

> **Document type:** G1 reference — external comparison
> **Audience:** Anyone integrating with or reverse-engineering the Even Realities G1
> **Evidence basis:** Ghidra decompilation of the G1 firmware binary (app core + net core). Not capture-based, not live-tested.

Artifact:

- Repo: `https://github.com/JohnRThomas/even_realities_decomp`
- Read at commit `f571782`, "Raw Export 08/03/2026"
- Self-reported coverage at that export: 2,948 total functions, 2,565 labelled (87%); 871 app-specific functions, 521 labelled (60%)
- Net core is stock nRF DFU sample — no custom Even Realities code in it

## Why this source is different from the others

Every other external reference we track is another **sender**:

- the JohnRThomas wiki (`external-protocol-wiki-notes.md`)
- Gadgetbridge `G1Constants.java`
- ayroblu/bazel-demo Swift
- fahrplan, openclaw-glasses, MentraOS (`g1-companion-apps-comparison-notes.md`)
- the vendor Python SDK (`python-sdk-comparison-notes.md`)

This one is the **receiver**. It is the code that parses what we send. Where a
sender-derived claim and this decompilation disagree about *packet structure*,
the decompilation should win.

Two things it is not:

- **Not authoritative on behaviour.** It tells us what the parser accepts and
  where fields are stored. It does not tell us what actually renders, or what
  the firmware does under real timing and BLE conditions. Live device testing
  still outranks it for anything observable.
- **Not byte-exact by default.** It is a decompilation. Ghidra's pointer
  arithmetic and its string-scanning loops produce off-by-ones. Trust
  **field order, field types, and size caps** ahead of any specific offset I
  have quoted, and validate offsets against our own snoops before shipping.

The unexpectedly valuable part is that the decompiler preserved the firmware's
`printk` format strings, so we get Even Realities' own internal names for
fields, sub-commands and error conditions.

## Confidence labels used here

Same hierarchy as [protocol-reference.md](protocol-reference.md), with one addition:

- `Firmware-source` — read directly out of the decompiled parser. Strong on
  structure, silent on behaviour.

## The dispatch map

Four files carve up the whole command space. This is the single most useful
thing in the repo — it bounds the protocol.

| File | Opcodes |
|------|---------|
| `src/app/ble_process_put_req.c` | `0x01`–`0x27` (host writes) |
| `src/app/ble_process_get_req.c` | `0x29`–`0x3f` (host readbacks) |
| `src/app/ble_process_req_dispatch.c` | `0x47`–`0x56` |
| `src/app/master_process_put_req.c` | inter-leg (SPI) forwarding subset |

Anything outside those ranges is not a host-facing command.

Two structural rules that apply across most families:

1. **Bytes 1–2 are a little-endian total length and the firmware validates
   them.** On mismatch it logs `packet length error, input data length = %d,
   packet data length = %d` and **drops the packet entirely**. This is a
   silent-failure mode we should assume for any hand-built packet that renders
   nothing.
2. **`0xC9` is the firmware's generic success code**, not something specific to
   `0x0E` mic-enable as our vendor-derived notes imply. `deal_event_to_phone.c`
   emits `<opcode> C9 <state>` acks for at least `0x0D`, `0x0F` and `0x4E`.

## Reconciliation against our existing findings

### Confirmed — keep, and promote where noted

**`0x06 0x01` time-sync payload layout.** The firmware reads a `uint32` at
offset 5 and a 64-bit value across offsets 9–16, and logs
`origin ms timestamp = %lld, origin second timestamp = %d`. That is an exact
match for what `Proto.setTimeAndWeather()` already sends, including the
epoch32-then-epoch64 ordering. The dual-timestamp design is real, not
cargo-culted.

**`0x0a` sub-command numbering.** `param_3[4]` is the sub-command and the
switch runs 0–6, matching the Gadgetbridge `NavigationSubcommand` names we
adopted. `spec_ble_command_hook.c` names the opcode
`BLE_REQ_PUT_NAVIGATION_INFO`.

**`0x0a` x/y bounds.** Bounds-checked against `0x1E8` (488) and `0x88` (136),
logging `app send x/y parameter overstep!!!`. Confirms the 488×136 display
geometry from an independent direction.

**`0x1e` sub-command 3 is note content.** Firmware logs
`Quick Note Title =%s, QuickNote TEXT =%s` and `title length = %d, text
length = %d`. Our "dashboard slot content push" reading of
`1e <len> 00 <seq> 03 01 ...` is right; the firmware just calls the records
quick notes rather than dashboard slots. fahrplan's use of these as generic
widget slots is a repurposing, not a separate feature.

**Empty note payload deletes.** `received empty quick note data, delete quick
note num.%d` — sending a note with no content is the delete path. Worth
knowing before we go looking for a delete opcode.

**Multi-packet note assembly is order-checked.** `There is a packet order
error, current packet order = %d, expected package order = %d`. Chunked note
writes must arrive in order; the firmware will not reassemble out of order.

**`F5` sub-code == internal firmware event id.** `deal_event_to_phone.c`
builds the outbound frame as `F5 <event_code>` with the event code passed
through verbatim on the default path, then sends it with a fixed 21-byte
length. The premise of
[even-g1-event-mapping.md](even-g1-event-mapping.md) — that F5 sub-codes are a
flat enumeration of firmware-internal events — is structurally correct.

It is driven off an internal message queue:
`ble_process_req_dispatch.c` calls the emitter when the queued message type is
`0xf5`. So "does this gesture reach the phone?" is really "does its handler
enqueue an `0xf5` message?".

**`F5 0F` is a getter-sourced value byte.** Built as `F5 0F <FUN_00033760()>`,
same shape as `F5 0E`. Consistent with our case-battery reading.

**`F5 12 <level>` is a state-byte push.** Built as `F5 12 <byte at +0x759>` —
a stored value, which is why it echoes the applied level rather than the
requested one.

**Single taps are absorbed by the firmware**, and now we know why.
`touch_key_thread.c` classifies each gesture into a key-event type
(`DAT_200084f8`: 1 = single click, 2-6 = the others) and `key_event_thread.c`
dispatches it. Single click goes to firmware-local actions and master→slave
sync — `master send calendar key single click ,timestamp = %d`,
`Click event does not respond, close Quicknote to prevent exceptions`. It does
not enqueue an outbound `0xf5` message, which is what `deal_event_to_phone.c`
requires to emit an `F5` frame.

That is a direct structural match for the negative result in
[FINDINGS-taps.md](FINDINGS-taps.md), where the glasses visibly cycled
notes/notifications while emitting nothing on BLE: single click is wired to
the local dashboard and the other temple, not to the host. `Firmware-source`,
corroboration rather than proof — 40% of app functions are still unlabelled —
but keep the guardrail.

### Corrected — our docs were wrong

**`0x0a` TRIP_STATUS: `y` is a `uint16`, and there is no null separator.**

We documented the prefix as `<DirectionTurn> <x0> <x1> <y> 00`, reading `y` as
one byte followed by a separator. The firmware reads two `uint16` values:

```
*(ushort *)(param_3 + 6)  -> x, bounds-checked against 0x1E8 (488)
*(ushort *)(param_3 + 8)  -> y, bounds-checked against 0x88  (136)
```

The first string starts immediately after, at offset 10. Our own captured
prefix `01 03 c8 00 12 00` reads as sub-cmd `01`, direction `03`, x = 200,
y = 18 — the byte we called a "null separator" is the high byte of `y`. Same
bytes on the wire, wrong field model. Fixed in
[protocol-reference.md](protocol-reference.md).

**`0x06` is not a three-step transactional wrapper.**

We documented `0x06` as "a general-purpose transactional wrapper" with a
request / payload / finalise structure, on the strength of the official app
always sending three frames in a row. It is not. Byte 4 is a **content-type
sub-command** and the three frames are three unrelated pushes:

| Byte 4 | Firmware meaning |
|--------|------------------|
| `0x01` | time / date sync (plus display-format and weather fields — see below) |
| `0x02` | acknowledged and ignored; no payload parse |
| `0x03` | schedule / calendar records |
| `0x04` | stocks |
| `0x05` | news |
| `0x06` | dashboard display mode + "custom display Area value" |
| `0x07` | citywalk |

So the sequence our app sends on connect is: set dashboard display mode
(`0x06`), sync the clock (`0x01`), then **push an empty calendar list**
(`0x03`) — not "begin, payload, commit". The third frame
(`06 0c 00 <seq> 03 01 00 01 00 00 00 01`) is a schedule push with zero
records. It is harmless, but it is not a finalise step and removing it would
not break the clock sync.

Consequence: the `0x22` ack we observed for note management should not be
expected for time-set, because there is no transaction to ack. Our doc already
hedged that; the reason is now clear.

**And one further consequence, which is the sharpest thing this reconciliation
turned up.** Our `0x06` "Variant A — note management delete / reorder" is the
same three frames as "Variant B — time-set": identical lengths
(`07` / `16` / `0c`), identical byte-4 sub-commands (`0x06` / `0x01` / `0x03`),
byte-for-byte identical third frame. Under the corrected model that is the
routine display-mode + clock + empty-schedule sync, captured *during* a note
delete/reorder rather than caused by it.

So the "8-byte note UID" we read out of the payload is very likely timestamp
data — bytes 5–12 are exactly where `epoch32` and the low half of `epoch64`
sit, and the bytes recorded straight after (`d4 9d 01 00`) carry the
high-word signature of a 2026-era epoch-milliseconds value.

If that holds, note delete/reorder has no known opcode, and the firmware's own
delete path for note content is a `0x1e` write with empty content
(`received empty quick note data, delete quick note num.%d`) — not a `0x06`
transaction. Flagged in [protocol-reference.md](protocol-reference.md) with a
re-parse action rather than rewritten, because settling it needs the original
2026-04-28 Phase 4 capture, not more source reading.

**`0x1e` is less overloaded than we thought, and `0x06` is more.**

Our `0x1e` disambiguation table stays correct as written. But the note about
`0x06` handling "the transactional framing around dashboard updates" is wrong
and has been removed — `0x06` carries its own structured content types, and
they are richer than the note slots.

### Discarded

**"The firmware does not ack `0x0a` commands."** Too strong. There is no
positive ack, and fire-and-forget remains the right transport, but the parser
does post an error frame carrying `<sub-command> | error flag` on both a
length mismatch and every oversize-string case. Whether that surfaces on BLE
or only on the inter-leg IPC channel is unresolved from source alone —
`post_to_host` is the same call used for master/slave sync. Reworded rather
than deleted; do not build on it until we look for it in a snoop.

**"`0x29` response byte 3 does not exist / is meaningless."** Our two
empirical probes returned `0x00` and we were close to writing the field off.
The firmware reads two distinct stored fields:

```
case 0x29:  *param_3 = param_1[0xed5];   // byte 2 — brightness level
            bVar2    = param_1[0xf9c];   // byte 3 — separate stored field
```

**Superseded 2026-09-08 — the wiki was right.** A closer read of
`master_process_put_req` confirms byte 3 is the auto-brightness flag. Opcode
`0x01` (brightness set) takes `param_2[4]` as level and `param_2[5]` as auto,
and writes the auto byte to `param_1[0xf9c]` — exactly the field `0x29` returns
as byte 3. Same field, one written by the setter and read by the getter.

So the two empirical probes returning `0x00` need a different explanation:
either auto was genuinely off at probe time, or the readback answered for the
wrong leg. A re-probe should set auto on and query both legs.

One further correction: this note originally said the response is assembled by
"forwarding the request over SPI to the **other temple**". That is more than
the source supports. `FUN_00019d14` logs `spim tx` / `spim ret` around the call
and the handler is named `master_process_put_req`, but whether the struct it
reads holds the peer's state or local state is not established. There is
separately an ESB path for temple-to-temple traffic (`sync_to_slave`,
`local_esbm_ipc_service_recv` / `local_esbs_ipc_service_recv`).

Full working in
[firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) § 5. See
also [external-protocol-wiki-notes.md](external-protocol-wiki-notes.md).

## New — not in any of our docs

### `0x06 0x01` has five trailing fields, and we are already sending them

Our packet ends `... <epoch64> 00 00 00 00 02`. Every one of those bytes lands
in firmware state:

| Offset | Firmware destination | Reading |
|--------|---------------------|---------|
| `0x11` | ctx +4 | weather icon |
| `0x12` | ctx +5 | temperature |
| `0x13` | ctx +0x5d | temperature unit (C/F) |
| `0x14` | ctx +0x5e | 12/24-hour time format |
| `0x15` | ctx +0x5f | read only when total length > `0x15`; **triggers a redraw when the value changes** |

This is a genuine three-way triangulation rather than a decomp-only claim:

- the **JohnRThomas wiki** gives the order as
  `... <epoch64_ms> <weather_icon> <temp_c> <c_f_flag> <24h_flag> 00`, already
  quoted in the `navigate-cleanup` worklist item
- **fahrplan** (`models/g1/time_weather.dart:158-185`) builds the same payload
  with `weatherIcon`, `temp`, `unit`, `is12h`, plus a `WeatherIcons` enum of
  firmware-native codes at `time_weather.dart:4-20`
- the **firmware parser** stores those four offsets into four distinct fields,
  and the two it puts at `+0x5d` / `+0x5e` are exactly the region the display
  log branches on for `centigrade degree` / `Fahrenheit` and 24/12-hour

Two sender-side sources agreeing on field order, and the receiver agreeing on
field count and on which two are format flags, is about as good as this gets
without a device. Treat the mapping as `Suspected` with high confidence and
confirm with one on-device probe.

One loose end: the wiki has the sixth byte (`0x15`) as `00`; our app sends
`0x02`. Since that byte triggers a firmware redraw when it changes, it is
worth knowing what it is before extending the packet.

This turns `time-weather-0x06-extend` from a guess into a four-byte probe.

### `0x06` has native structured widget types

`0x03` schedule, `0x04` stocks, `0x05` news, `0x07` citywalk. These are not
note slots — they are firmware-native record types with their own fields,
their own multi-packet assembly, their own index management and their own
firmware-rendered layouts. The schedule one is the interesting one:

```
schedule title : %s , time : %s , location : %s , schedule_validity : %d
schedule record num = %d
schedule total record num = %d
Action ID = 1, Received schedule multiple initialization packets, currently the first packet of data
```

Supporting firmware: `setCalenadrIndex.c`, `cleanCalenadrIndex.c` (sic),
`init_dashboard_info.c`, `DashBoard_Reflash.c`, `ui_DashBoard_task.c`, and
`simulator_ancs_calendar_schedule_trigger.c`.

Stocks and news have the same shape — `stock code name`, `stock company name`,
`stock price`, `stock price change`, `stock change rate`, `stock change
status`; `news source`, news text, news change rate — with `setNewsIndex.c` /
`setStocksIndex.c` / `cleanNewsIndex.c` / `cleanStocksIndex.c` behind them.

This matters for `dashboard-widgets-v1`, which currently plans to serialise
everything into four `0x1E` note slots following fahrplan. Calendar events are
a first-class firmware record. See that worklist item for the resulting
decision point.

### New readback opcodes

From `ble_process_get_req.c`, named by the firmware's own log strings:

**Fully pinned 2026-09-08** — the complete map, plus which cases answer
locally and which go through the relay, is in
[firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) § 3.
Summary:

| Opcode | Firmware name |
|--------|---------------|
| `0x29` | `BLE_REQ_GET_BRIGHTNESS` |
| `0x2a` | `BLE_REQ_GET_ANTI_SHAKE_ENABLE` |
| `0x2b` | `BLE_REQ_GET_DISPLAY_MODE` |
| `0x2c` | `BLE_REQ_GET_DEVICE_INFO` (the request carries the host platform byte) |
| `0x2d` | `BLE_REQ_GET_M_N_S_MAC` |
| `0x32` | `BLE_REQ_GET_WAKEUP_ANGLE` |
| `0x33` | `BLE_REQ_GET_GLASSES_SN` |
| `0x34` | `BLE_REQ_GET_DEVICE_SN` |
| `0x35` | `BLE_REQ_GET_ESB_CHANNEL` |
| `0x36` | notification counts |
| `0x38` | ANCS enable state |
| `0x39` | system status / current running app — **per-lens, answered locally** |

`0x2f` / `0x30` / `0x31` have no cases. `0x2e`, `0x37` and `0x3a`–`0x3f` are
unnamed.

Two notable ones. `0x2b GET_DISPLAY_MODE` means the `0x50` display-mode state
is readable, so a host could resynchronise after a reconnect instead of
assuming. And `0x39` is the only readback that reports the queried lens's own
screen state — the closest thing to "what is this lens showing".

### `0x2c` `GET_DEVICE_INFO` — the request declares the host platform

**Corrected 2026-09-08:** this is `BLE_REQ_GET_DEVICE_INFO`, not a standalone
platform-declaration opcode. The platform byte rides in the request.


```
raw_data[1] == 1  ->  Android
raw_data[1] == 2  ->  iOS
```

Stored and branched on. Worth checking whether our app sends this at all; if
the firmware defaults to the iOS branch it may be waiting on ANCS-shaped
behaviour we never provide.

### `F5 0A` battery percentage is synthesised near full charge

`deal_event_to_phone.c` does not pass the raw gauge value through for event
`0x0a`. It remaps:

- raw `< 0x5d` (93) — passed through unchanged
- raw `0x5d`–`0x60` (93–96) — remapped upward through 94–98 depending on a
  second flag
- raw `> 0x60` (96) — clamped to `0x64` (100)

So anything we display in the 94–100% band is a firmware-constructed value,
not a measurement. `Firmware-source`. Consistent with our capture reading
`0x64` at "100%", and worth remembering before anyone investigates "why does
it sit at 100% for so long".

### `0x09` — teleprompter

`spec_ble_command_hook.c` names opcode `0x09` `BLE_REQ_PUT_TELEPROMPTER_INFO`,
alongside a full `ui_teleprompter_task.c` (33 KB, one of the larger UI tasks).
`ui_translate_task.c`, `ui_transcribe_info_task.c` and
`draw_template_translate_screen.c` are the sibling modes. Three
firmware-rendered display surfaces we have never touched.

### `BLE_REQ_PUT_COUNTDOWN_TIMER`

Exists in `ble_process_put_req.c`. A firmware-native timer needs no display
work from us.

### `spec_ble_command_hook.c` is an on-device command simulator

It synthesises `BLE_REQ_PUT_NAVIGATION_INFO` and
`BLE_REQ_PUT_TELEPROMPTER_INFO` payloads from cJSON objects built in firmware
(`cJSON_AddNumberToObject(obj, "enable", 1)`, `"direction", 2`, …). The
glasses can drive their own navigation lifecycle with no phone attached.

If that is reachable — unknown, and it may be gated like the test-mode
commands below — it is a far better way to isolate nav rendering bugs than
replaying 108 packets over BLE. Worth a look during `navigate-cleanup`.

### Firmware text layout functions

The firmware's own text pipeline, relevant to `g1_text_layout.dart`:

- `gui_utf_Wordwrap_draw.c` — the actual word-wrap
- `gui_utf_draw_truncate.c`, `gui_utf_draw_align_right.c`,
  `gui_utf_draw_middle.c`, `gui_utf_draw_dark_light_split.c`,
  `gui_utf_draw_darkword_by_lines.c`
- `write_font.c`, `find_chinese_bitmap_by_unicode.c`
- `gui_string_draw.c`, `gui_utf_adv_draw_configure.c`

We already have the glyph-width table. This is the wrap *algorithm*, so the
43-char / 3-row model and the mid-word-break behaviour in
[protocol-reference.md](protocol-reference.md) can be checked against the
source rather than inferred from renders.

### Uncompressed mic exists but is gated

`set_mic_nocompress.c` toggles raw PCM instead of LC3, via a command shaped
`3a 01 03 01`. It refuses unless test mode is active:

```
warning: not test mode,disable setting
```

The gate is `DAT_2001abc2`, set by `enter_into_testmode.c` / `set_test_mode.c`.
Not a free win, and test mode is not somewhere to go casually. Recorded for
completeness — skipping the LC3 decode in Capture would be nice, but not at
this price.

### Navigation rendering internals

`navigation_direction_img_display.c`, `navigation_overview_map_display.c`,
`navigation_panoramic_map_display.c`, `ui_navigation_task.c`. If the
`PANORAMIC_MAP` question in `navigate-osm-research` needs to know what the
firmware actually does with those 90 rows, this is where it is written down.

## Still open after reading it

- Does the `0x0a` error frame reach BLE, or only the inter-leg channel?
- What is the field at brightness-context `+0xf9c` (`0x29` response byte 3)?
- Which of `0x11` / `0x12` in `0x06 0x01` is the weather icon and which is the
  temperature?
- Is `spec_ble_command_hook` reachable from a normal BLE session?
- Are the `0x06` schedule / stocks / news records renderable on 1.6.6 without
  the official app having set something up first?
- Exact opcodes for the unmapped `BLE_REQ_GET_*` names.
- **Action, not a question:** re-parse the 2026-04-28 settings capture Phase 4
  window against the corrected `0x06 0x01` field table, to settle whether
  "Variant A note management" is really just a time sync. Needs the capture,
  not more source reading. If confirmed, note delete/reorder has no known
  opcode and that should go back on the worklist as an unknown.

## How to keep using it

The repo is actively worked on — a raw re-export every few weeks, with
function-labelling coverage climbing. `helpers/ai/` contains their
AI-assisted labelling workflow (`FUNCTION_RENAME_WORKFLOW.md`,
`function_discovery_workflow.md`, `memory_map.md`) and
`helpers/ghidra_scripts/` the Ghidra side. `src/app/index.txt` maps every
address to its labelled name and file, which is the fastest way to diff two
exports and see what got named since last time.

Re-read when a protocol question is structural ("what are the fields") rather
than behavioural ("what does it do"). It will not answer the second kind.

## Related docs
- [firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) —
  follow-up source read: the inter-leg forwarding subset, the `0x4E` ack
  structure, the per-lens `0x39` state query, and which lens is the slave
- [protocol-reference.md](protocol-reference.md)
- [even-g1-event-mapping.md](even-g1-event-mapping.md)
- [external-protocol-wiki-notes.md](external-protocol-wiki-notes.md)
- [g1-companion-apps-comparison-notes.md](g1-companion-apps-comparison-notes.md)
- [FINDINGS-layouts.md](FINDINGS-layouts.md)
- [FINDINGS-taps.md](FINDINGS-taps.md)
