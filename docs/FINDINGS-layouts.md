# G1 BLE — layout / rendering mode findings

> **Document type:** G1 reference
> **Audience:** Anyone integrating with or reverse-engineering the Even Realities G1
> **Evidence basis:** HCI snoop captures + live testing, firmware 1.6.6

Source: `btsnoop_hci.log` (7.8 MB, 2026-04-28 20:13–20:32 UTC), official Even
Realities Android app, firmware 1.6.6. Wall-clock annotations in
`wall clock dashboard.md`. Screenshot of the rendered dashboard in
`dashboard-2014-example.png`.

---

## TL;DR — three new rendering protocols discovered

| Mode | TX opcode | Sub-types | What it is |
|------|-----------|-----------|------------|
| Live streaming text | **`0x52`** | `02 02` + text | **Word-by-word incremental text rendering with cursor.** The exact protocol the official app uses for live transcription. Known test phrase "The quick brown fox..." appears byte-for-byte in the payloads, growing word by word. |
| Navigation card | **`0x0a`** | `01` text, `02` icon, `03` map | **Structured hybrid card: text data slots + bitmap chunks.** The firmware has a card template; the host fills text fields (ETA, distance, road name, turn distance) as null-separated strings in ONE 48-byte packet, then sends icon + map bitmaps in chunks. |
| Dashboard data slots | **`0x1e`** / **`0x06`** | structured | **The firmware renders a fixed grid layout; the host pushes slot content** (date, weather, note titles/bodies, stock data) via `0x1e` writes with title + body structure. `0x06` handles the transactional framing. |
| Mode control | **`0x50`** | constant | **Display mode initialiser.** Identical 6-byte packet `50 06 00 00 01 01` fires before every mode entry (transcribe, navigation). Likely "prepare display for structured content." |

The companion app currently uses only `0x4E` (text blocks) and `0x15/0x16/0x20`
(full-screen BMP). These three new paths offer **dramatically better rendering**
for the three use cases the user cares most about: Chat (streaming text),
Navigate (structured card without BMP sync issues), and a future QuickNote/
dashboard feature.

---

## `0x52` — Live streaming text

### When it fires

Only during Phase 3 (live transcription): 397 TX writes over ~4 min.
Interleaved with `0xf1` RX audio (glasses → host mic stream) and `0x53`
keepalive frames.

### Packet structure

**Mode init** (first packet):
```
52 06 00 00 01 01
```
Identical structure to `0x50` — likely "start transcription display mode."

**Text update** (alternating with cursor-update frames):
```
52 <len> 00 <seq> 02 02 00 <line> 00 <flags> 00 00 <text_utf8> 0a
```
- `<len>` = total payload length
- `<seq>` = monotonically incrementing sequence number
- `02 02` = constant mode identifier ("streaming text")
- `<line>` = which display line this updates (01 = line 1, 02 = line 2, ...)
- `<flags>` = cursor/confirmed state (01 00 when line is "confirmed/done",
  00 00 while still typing)
- `<text_utf8>` = the full current text of that line, UTF-8
- `0a` = line terminator

**Cursor update / line clear** (interleaved):
```
52 0e 00 <seq> 02 02 00 01 00 00 00 00 0a 0a
```
Short 14-byte frame, appears to mark the cursor position or clear old
content before the next text update.

### Observed text growth (test phrase)

```
seq 03:  "The"
seq 05:  "The quick"
seq 09:  "The quick brown"
seq 0d:  "The quick brown fox"
seq 11:  "The quick brown fox jumped over"
seq 13:  "The quick brown fox jumped over the"
seq 17:  "The quick brown fox jumped over the lazy"
seq 1a:  "The quick brown fox jumped over the lazy dog"
seq 1c:  "The quick brown fox jumped over the lazy dog."
```

Each text update re-sends the FULL current line (not just the delta). The
firmware replaces the entire line content on each update. When a second line
starts ("Testing 1, 2, 3..."), line 1 holds the previous sentence and line 2
grows incrementally.

The user observed: "text appears word by word after I say the words",
"screen does not clear until full", "wrapping as if a typewriter with the
first line of text disappearing off the top of the screen in real time",
"there is a pulsing cursor to the left of the screen and the time above it",
and "the clock also updates in real time." All consistent with the observed
protocol.

### `0x53` keepalive

20 occurrences at ~5 s cadence during transcription. Likely a "still active"
keepalive that prevents the firmware from timing out the display mode. The
companion app would need to emit these while streaming.

### Implications for the companion app

**Fully implemented and confirmed working** (2026-05-01). Chat mode
streams the LLM response word by word via a paced `StreamingRenderQueue`.
The protocol steps:
1. Send `50 06 00 00 01 01` to prime the display
2. Send `52 06 00 00 01 01` to enter streaming mode
3. For each word/phrase update, send a line-1 marker (`\n`) + line-2 text
   frame — the host manages scrolling (see below)
4. Send `0x53` keepalives every 5 s while active

**Official app line model (`Confirmed`, 2026-05-01):** the official app
uses only two line indices: line 1 as a cursor/status marker (a regular
text packet with `\n` content, NOT a special cursor frame), and line 2
for ALL text content. Every update sends both packets. No confirmed-flag
management is needed.

**Firmware display characteristics (`Confirmed`, 2026-05-01):** 3 visible
text rows, ~43 characters per row (proportional font). The firmware does
NOT auto-scroll — it wraps text at its display width and respects embedded
`\n` as line breaks, but stops rendering when text exceeds the visible
area. Character-wraps mid-word at the display boundary.

**Host-managed scrolling:** the companion app wraps text with `\n` at
~43-char word boundaries, then keeps only the last 3 lines (matching the
3 visible rows). As new content wraps to a 4th line, the oldest line is
trimmed. Visual effect: text grows word by word on the bottom row; when
it fills, the top row drops off and new content starts at the bottom.

**Pacing:** 2 words every 200 ms (~450 WPM effective with BLE overhead).
Backend chunks are decoupled — they append to a target buffer; the queue
drains independently. Queue keeps draining after backend completes until
all words are displayed, then signals completion.

**Previous incorrect approaches:** (1) multi-line indices 1-4 with
host-managed wrapping — firmware only rendered 1-2 lines near the cursor;
(2) single line 2 without `\n` — firmware filled visible area and stopped;
(3) single line 2 with `\n` but no tail trimming — firmware does not
auto-scroll; (4) "cursor frame" sent separately — it is actually just the
line-1 text packet; (5) `_capForPacket` 230-char truncation — unnecessary,
the BLE stack handles larger packets.

---

## `0x0a` — Navigation card

### When it fires

Only during Phase 4 (navigation): 284 TX writes over ~70 s.

### Packet structure — three sub-types

**Sub-type 1 — structured text data** (one packet per card update):
```
0a <len> 00 <seq> 01 03 c8 00 12 00
  <eta_utf8> 00
  <distance_utf8> 00
  <road_name_utf8> 00
  <turn_distance_utf8> 00
```

The observed payload decoded:
```
"26 min" \0 "2.2km" \0 "Church Road " \0 "46m" \0
```

This matches EXACTLY what the user saw on the glasses: "Church road, right
arrow 46m 26m 2.2km". The fields are null-separated UTF-8 strings, all in
ONE ~48-byte packet. The firmware renders them into the navigation card
template using its built-in font and layout.

**Sub-type 2 — direction icon bitmap** (`02`):
```
0a <len> 00 <seq> 02 <bandCount> 00 <bandNum> 00 <RLE chunk>
```
13 bands (9-byte header + up to 185 bytes RLE payload each) for a 136×136
monochrome icon. RLE format: simple `<count> <byte>` pairs, count max 255.
Pixel layout: row-major, LSB-first bit packing. Image is two layers
(image + overlay) = 4,624 raw bytes; overlay all-zeros for direction icons.
Confirmed from ayroblu/bazel-demo Swift source. The companion app now
scrapes the Google Maps notification icon PNG and converts it to this
format; geometric arrows serve as fallback.

**Sub-type 3 — route map bitmap** (`03 5a`):
```
0a c3 00 <seq> 03 5a 00 <row> <~190 bytes bitmap data>
```
Many packets (typically 30-50) — the small route/street map shown on the
right side of the navigation card. Very sparse (mostly zeros with occasional
set bits) — consistent with a simplified monochrome road rendering.

### Control frames

- `0a 06 00 <seq> 00 01` — "enter navigation display mode"
- `0a 06 00 <seq> 04 01` — "status ready" / "prepare for card data"

### Implications for the companion app

**The Navigate mode can push structured text data in a single ~48-byte
packet** instead of rendering a full-screen BMP (~5 KB with CRC and
multi-packet transfer). This eliminates the per-leg BMP sync issue that
causes split-eye divergence.

Practical approach:
1. Send `0a 06 00 XX 00 01` to enter nav mode
2. Parse Google Maps notification fields (the app already does this)
3. Build one `0a ... 01 03 ...` text packet with the null-separated fields
4. Optionally send a direction icon via sub-type `02` (could reuse the
   existing Maps-provided manoeuvre icon)
5. Optionally send a route map via sub-type `03` (or skip it — the text
   card alone is useful)

The direction icon and map are OPTIONAL — the firmware likely renders the
text fields regardless. The existing Navigate BMP path could be replaced
entirely with this structured-data approach.

---

## `0x1e` TX — Dashboard data slots

### When it fires

Throughout Phase 1 (dashboard cycling) and Phase 2 (quicknote sync):
26 TX writes total. These push content into the firmware's dashboard grid.

### Observed payloads with ASCII decode

```
"Test Note 2" + "This is a test quick note."
"Voice Note Summary" + "Recording long notes through quick notes feature."
"Keyword Research" + "Focus on the keyword: Banana Chocolate."
```

### Packet structure

**Short form** (6 bytes) — refresh / activate widget:
```
1e 06 00 <seq> 01 01
```

**Content form** — push a titled item into a dashboard slot:
```
1e <len> 00 <seq> 03 01 00 01 00 <slot_index> 01 <title_len> <title_utf8> <body_len> 00 <body_utf8>
```

The `03 01 00 01 00` prefix identifies the "quick notes" widget context.
`<slot_index>` is the note position (01, 02, 03, 04...). The firmware
renders the title and body in the dashboard grid's right panel.

### Implications

The companion app could push its own content into the dashboard's note
slots — short summaries, reminders, or status text — without owning the
entire dashboard layout. The firmware handles all the rendering.

---

## `0x50` — Display mode control

Four occurrences, all identical: `50 06 00 00 01 01`. Timestamps:

| time       | what follows |
|------------|--------------|
| 20:24:03   | transcription mode starts (0x52 text stream) |
| 20:26:59   | second transcription session starts |
| 20:28:58   | navigation mode starts (0x0a card data) |
| 20:30:28   | return to idle after nav ends |

This is a **display mode initialiser** — it primes the firmware's renderer
for the mode that follows. The companion app should send it before entering
`0x52` streaming text or `0x0a` navigation card mode.

The fact that the payload is IDENTICAL for both transcription and navigation
suggests the mode is implicit in which data opcode follows, not in the `0x50`
payload itself. `0x50` might simply mean "clear display, stand by for
structured content."

---

## Confirmed from the screenshot

The `dashboard-2014-example.png` shows a firmware-native grid:

- **Left panel**: date ("Tue, 28/04"), weather ("13c"), large clock ("20:14"),
  notification bell + count ("0"), calendar icon + "No Data Selected"
- **Right panel**: "Test Note 2 | 1/2" + "This is a test quick note."

The text in the right panel matches the `0x1e` payloads byte for byte. The
date, weather, and clock in the left panel are likely maintained by the
firmware itself (or pushed via the `0x06` transactional family we already
know, with sub-commands for each field).

---

## What this means for the companion app

---

## Navigation card debugging results (2026-04-28 evening session)

### What we confirmed working

**The full official lifecycle renders successfully on the glasses.** A replay
of all 108 packets from the official app's snoop — including `0x50` mode
control, INIT, SYNC, TRIP_STATUS, all 13 RLE icon bands, all 90 map rows,
and trailing SYNC — produced a visible "Church Road / 46m / 26 min / 2.2km"
card on the right eye. The left eye lagged but eventually caught up.

**The firmware requires a continuous 1-second SYNC poller** to keep the
navigation session alive. The official app sends `0x0a 06 00 <seq> 04 01`
every 1 second for the entire duration of the navigation session. When the
poller stops (or runs too slowly), the firmware times out and shows
"Navigation service lost" after a few seconds.

### What failed and why

1. **Text-only cards (no icon/map):** "Navigation service lost" — the firmware
   requires all three sub-types (TRIP_STATUS + MAP_OVERVIEW + PANORAMIC_MAP)
   to consider a card "complete" before rendering.

2. **Dummy all-zero icon/map data:** Also "Navigation service lost" — the
   firmware validates the icon data (it's RLE-encoded, not raw bitmap).
   All-zero payloads are not valid RLE.

3. **Fire-and-forget (`sendData`) vs acked (`sendBoth`):** The firmware does
   NOT ack `0x0a` commands (confirmed: `send Timeout R0a of 250` on every
   attempt). `sendData` (fire-and-forget) is the correct transport.

4. **Removing `0x50` mode control:** The successful replay INCLUDED `0x50`.
   The Gadgetbridge project labels it `UNKNOWN` but it appears to be required
   as a display-mode preparation signal.

5. **3-second poller cadence:** Too slow. The firmware expects ~1-second
   cadence (86 SYNC packets over ~70 seconds in the snoop).

6. **BLE flooding:** Sending 108 packets with no pacing crashed the BLE
   connection (one leg disconnected). Adding 10ms delays every 10 packets
   resolved this.

### Left/right sync issue (open)

The replay sends to both legs simultaneously via `BleManager.sendData`
(which calls the native `requestData` broadcasting to both). With 108
packets in ~10 seconds, the right eye rendered first while the left lagged
significantly. Both eventually showed the card, but the left eye was
~5 seconds behind.

Possible causes to investigate:
- BLE write buffer contention: broadcasting 108 packets to both legs
  simultaneously may starve one side
- Per-leg sequential sending (right burst then left, or vice versa) might
  produce more reliable dual-eye sync
- The official app may send to each leg with its own pacing/flow control

### Replay transport experiments (2026-04-29 follow-up)

Three transport strategies were tested in the companion app without changing
the captured packet bytes:

1. **Broadcast** — unstable under the full 108-packet burst. Could starve or
   break one leg.
2. **Full sequential right-first / left-first** — stable, but each leg took
   roughly 4 seconds, so the second eye visibly rendered several seconds late.
3. **Interleaved per-leg replay** — current successful strategy. For each
   packet index `i`, send packet `i` to the right leg, wait 10 ms, send the
   same packet `i` to the left leg, wait 20 ms, and pause 50 ms every 10
   packet pairs. This proved both **fast and stable** in live testing.

Additional implementation notes from that follow-up:

- the replay path remains **fire-and-forget per leg**; `0x0a` commands are
  still unacked and should not use `sendBoth`
- `NavigateService` now guards against duplicate replay triggers while a replay
  is already in flight
- the Navigate idle prompt (`Open Google Maps / to start navigation`) is now
  delayed briefly on mode entry so it does not override the first real nav
  replay when the initial Maps notification arrives immediately after the mode
  switch

### What we now know the production implementation needs

1. **Full lifecycle per card update:** 0x50 + INIT + SYNC + TRIP_STATUS +
   MAP_OVERVIEW ×13 + PANORAMIC_MAP ×90 + SYNC (108 packets, ~20KB)
2. **1-second SYNC poller** running continuously while Navigate mode is active
3. **Proper per-leg pacing:** interleaved per-leg replay is now the confirmed
   debug transport; production code should preserve the same "do not starve a
   leg" principle when the replay bytes are replaced with dynamic packet
   building
4. **Real icon/map data** — dummy zeros don't work. Either:
   - replay captured icon data matched by turn direction, or
   - implement the RLE encoder (icon is 136×136, map is 488×136)
5. **The 0x50 mode control** is needed before the first INIT

### Investigation backlog for next session

- Determine the minimum icon/map data the firmware accepts (can we send a
  valid but simple RLE-encoded icon instead of the full captured data?)
- Check whether TRIP_STATUS updates (subsequent instructions) need the full
  lifecycle or just TRIP_STATUS + SYNC
- Implement the 1-second SYNC poller as a proper Timer in NavigateService

### Priority 1 — Navigation via `0x0a` text data — DONE

Navigate now uses the `0x0a` structured card protocol with interleaved
per-leg replay, dynamic `TRIP_STATUS`, dynamic `MAP_OVERVIEW` icons, and
a 1-second SYNC poller. The BMP pipeline is preserved but no longer active.

### Priority 2 — Chat streaming via `0x52` — DONE

Chat now streams assistant replies word by word via a paced
`StreamingRenderQueue` (`Confirmed`, 2026-05-01). The queue sends line 1
(marker with `\n`) + line 2 (all text, growing word by word) on every
tick. The host manages scrolling: text is wrapped with `\n` at ~43-char
word boundaries, and only the last 3 lines are kept (matching the
firmware's 3 visible rows). Pacing: 2 words every 200 ms.

### External cross-references (found during implementation)

Two additional open-source projects have partial Even G1 protocol
implementations that cross-validate and extend these findings:

- **Gadgetbridge** (`codeberg.org/jrthomas270/Gadgetbridge` branch
  `even-g1-custom-drawing-experiment`): `G1Constants.java` names all
  navigation sub-commands (INIT, TRIP_STATUS, MAP_OVERVIEW, PANORAMIC_MAP,
  SYNC, EXIT, ARRIVED) and confirms dashboard, hardware, and quicknote
  sub-command enumerations. Also reveals that `0x50` is labelled `UNKNOWN`
  by them too.

- **ayroblu/bazel-demo** (`github.com/ayroblu/bazel-demo` path
  `g1-app/g1protocol/`): working Swift navigation implementation confirming
  the TRIP_STATUS prefix bytes are `[sub-cmd, DirectionTurn_enum, x0, x1,
  y, null]` followed by five null-separated text fields (totalDuration,
  totalDistance, direction, distance, speed). MAP_OVERVIEW is 136×136
  RLE-encoded; PANORAMIC_MAP is 488×136 unencoded.

Full comparison in
[external-protocol-wiki-notes.md](external-protocol-wiki-notes.md).

### Priority 3 — Dashboard content injection via `0x1e`

Push summaries, reminders, or status items into the firmware's dashboard
note slots. The user's quicknote workflow ("add things to think about later")
could be driven entirely from the companion app without the official app.

### Future — QuickNote with hosted transcription

The full pipeline is now visible end-to-end: right-hold → `0xf1` mic audio
→ hosted STT → `0x1e` note content push → firmware dashboard renders it.
The companion app already has the mic decode path (LC3 → PCM) and the STT
path (OpenAI transcription). Wiring them to the `0x1e` note push would
recreate the official QuickNote feature entirely within the companion app.
