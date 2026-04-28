# G1 BLE — layout / rendering mode findings

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

**Chat mode can stream the LLM response word by word** instead of rendering
a block of text all at once. The protocol is simple:
1. Send `52 06 00 00 01 01` to enter streaming mode
2. For each word/phrase update, send a `0x52` text frame for the current line
3. Interleave cursor-update frames (the 14-byte `0x52 0e ...` pattern)
4. Send `0x53` keepalives every ~5 s while active

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

**Sub-type 2 — direction icon bitmap** (`02 0d`):
```
0a c2 00 <seq> 02 0d 00 <row> <~188 bytes bitmap data>
```
~13 packets at 194 bytes each — a turn-direction icon (right arrow, etc.)
rendered as bitmap rows. Similar framing to the existing BMP path but
chunked within the `0x0a` family rather than using `0x15/0x16/0x20`.

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

### Priority 1 — Navigation via `0x0a` text data

Replace the current BMP-per-frame Navigate path with a single structured
text packet per instruction update. Eliminates the split-eye sync problem,
reduces payload from ~5 KB to ~48 bytes, and lets the firmware handle the
rendering. The direction icon and map bitmaps can be added later as an
enhancement.

### Priority 2 — Chat streaming via `0x52`

Replace the current "render a block of text" Chat response path with
word-by-word streaming. The user already described this as desirable
("like my current chatmode where I currently just pass a block of text").
The `0x52` protocol maps directly to streaming LLM output.

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
