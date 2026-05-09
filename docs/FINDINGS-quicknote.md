# FINDINGS — QuickNote audio stream

Capture: `logs/quicknote/btsnoop_hci.log` (2026-04-28, ~14:21 wall-clock / 20:22 UTC).
Parsed via `logs/bluetooth/parse_btsnoop.py` → `logs/bluetooth/traffic.csv`,
`logs/bluetooth/summary.txt`.

## Headline

**The host must actively request the audio stream.** The firmware does NOT
stream audio unsolicited after a `0x21` release. Re-analysis of the recon TX
traffic (2026-05-08) revealed the official Even Realities app sends
`1e 06 00 <seq> 02 01` to the right leg ~11 ms after `0x21`, which triggers
the `0x1e c8` audio stream. Without this TX, the firmware sends no audio.
This mirrors the left-press flow where the host sends `0x0e 01` to enable
the mic for `0xF1` LC3 streaming.

**End-of-stream signal: an `0x1e` notification with a non-`0xc8`
sub-code arrives ~70 ms after the last `0xc8` chunk.** In this capture, that
follow-up was a 6-byte `1e 06 00 42 04 00`. Watch for any `0x1e <not 0xc8>`
on the same connection to terminate the buffer cleanly. Trailing `0xc8` chunk
is shorter than the rest (90 B vs 200 B) — useful as a secondary hint, not as
the primary trigger.

## Capture context — only 1 of 3 cycles produced a stream

The user reported 3 long-press-right cycles. The capture contains exactly
**one** `0x21` release frame (at `20:22:05.337Z`, 15 bytes
`21 0f 00 0a 01 01 01 ec 16 f1 69 ac c2 41 cc`) and **one** `0x1e c8 ...`
audio stream. The other two long-presses didn't fire `0x21` — most likely
they were too short for the firmware to commit them as QuickNote captures
(consistent with prior observations on FINDINGS-taps.md). For the purposes
of buffer-flush logic this single, complete cycle is sufficient.

## The cycle, frame by frame

| ts (UTC) | opcode | len | hex (truncated) | role |
|----------|--------|-----|-----------------|------|
| 20:22:05.337 | `0x21` | 15  | `21 0f 00 0a 01 01 01 ec 16 f1 69 ac c2 41 cc` | release |
| 20:22:05.400 | `0x1e` | 200 | `1e c8 00 00 02 31 00 01 00 01 ...` | first audio chunk (seq 0x0000) |
| ...          | ...    | ... | (47 more 200-byte `1e c8` chunks)              | seq 0x0001..0x002f |
| 20:22:05.695 | `0x1e` | 90  | `1e 5a 00 30 02 31 00 31 00 01 ...`            | trailing audio chunk (seq 0x0030) |
| 20:22:05.767 | `0x1e` | 6   | `1e 06 00 42 04 00`                            | post-stream notification |

Total: **48 audio chunks**, **9,090 payload bytes** (47 × 200 + 90),
**~358 ms** wall from `0x21` to the post-stream notification, **~295 ms**
from first to last `0xc8` chunk.

## Chunk framing

Every `0x1e c8` chunk has the form:

```
1e c8 00 <seq1>  02 31 00 <seq2>  00 01  <payload>
```

- byte 0  = `0x1e` opcode
- byte 1  = `0xc8` sub-code (= 200 — *coincidentally* equal to the typical
            chunk size, but here it is acting as a sub-code, not a length)
- byte 2  = `0x00` constant marker
- byte 3  = `<seq1>`, monotonic 0x00..0x30 across the cycle
- byte 4  = `0x02` constant
- byte 5  = `0x31` (this differs from a prior capture which showed `0x61` —
            field meaning still TBD, possibly a session/codec id)
- byte 6  = `0x00` constant
- byte 7  = `<seq2>`, equals `<seq1> + 1` (so 0x01..0x31)
- bytes 8–9 = `00 01` constant
- bytes 10..end = audio payload

The trailing chunk uses byte 1 = `0x5a` (= 90) — i.e. **the second byte is
the chunk length, not a fixed `0xc8` sub-code**. This is the most useful
single-byte interpretation: the second byte is the *total chunk length
including header*. Full-size chunks happen to be 200 (`0xc8`); the final
chunk is shorter and reports its actual length.

This means the byte-1 field doubles as a length and as an implicit
"is-this-an-audio-chunk" signal. Frames where byte 1 is *not* a sane
audio length (e.g. `0x06` for the post-stream notification) are not audio
chunks and end the stream.

## Recommended buffer-flush logic (native Kotlin BleManager)

State machine on `0x1e` RX:

1. While capture inactive: ignore `0x1e` audio chunks (no `0x21` seen recently).
2. On `0x21` RX (right-side, any length ≥ 7): open a new QuickNote buffer,
   record the 8-byte note-UID tail (bytes 7–14 of the `0x21` payload) for
   future use, start timeout watchdog (500 ms). The buffer opens on both
   the 15-byte and 42-byte `0x21` variants — length ≥ 7 is the only guard.
3. On subsequent `0x1e` RX while buffer is open:
   - If byte 1 == `0xc8` (or, more robustly, byte 1 is in the typical
     audio range, e.g. ≥ 0x40): strip the 10-byte header and append the
     payload to the buffer. Reset the timeout watchdog.
   - Else: **flush** the buffer (this is the post-stream notification).
4. On any non-`0x1e` opcode arriving while buffer is open: **flush**
   (defensive — unlikely to happen mid-stream but cheap to handle).
5. On timeout (no `0x1e` for > 500 ms while buffer is open): **flush**
   (safety net for malformed end-of-stream). 500 ms is the implemented
   watchdog timeout.

Concrete primary trigger:

```kotlin
fun onRx1e(frame: ByteArray) {
    val subOrLen = frame[1].toInt() and 0xff
    if (quickNoteBuffer.isOpen) {
        if (subOrLen == 0xc8 || (subOrLen in 0x40..0xc8 && frame.size > 10)) {
            quickNoteBuffer.appendPayload(frame, headerLen = 10)
        } else {
            quickNoteBuffer.flushAndDispatch()
        }
    }
    // else: log and ignore — not in capture
}
```

The `0x40..0xc8` window is a guess for the trailing-chunk size; refine
once we capture more cycles with longer notes (a 30 s recording will have
many more chunks and likely surface the real lower bound).

## Host-initiated audio request handshake (discovered 2026-05-08)

Re-analysis of the recon TX traffic revealed the full handshake. The audio
stream does NOT start spontaneously after `0x21`. The host must request it.

| Step | Dir | Timestamp (recon) | Hex | Meaning |
|------|-----|-------------------|-----|---------|
| 1 | RX | 20:22:05.337 | `21 0f 00 0a 01 01 01 ec 16 f1 69 ac c2 41 cc` | Right-press release (`0x21`, 15 bytes) |
| 2 | **TX** | 20:22:05.348 | **`1e 06 00 41 02 01`** | **Host requests audio** (11 ms later) |
| 3 | RX | 20:22:05.400–.695 | `1e c8 ...` × 48 chunks | Audio stream (~295 ms) |
| 4 | **TX** | 20:22:05.723 | **`1e 06 00 42 04 01`** | **Host acknowledges audio received** |
| 5 | RX | 20:22:05.767 | `1e 06 00 42 04 00` | Glasses confirm cycle closed |

Structure of the host TX frames:
- `1e` = opcode (same 0x1e channel as the audio)
- `06` = frame length (6 bytes total)
- `00` = constant
- `<seq>` = host's outgoing sequence counter (0x41, 0x42 — monotonically increasing)
- `02 01` = "send audio" command / `04 01` = "audio received OK" command

The `<seq>` values in the recon started at `0x41`. Our code starts at `0x40`.
Whether the firmware cares about the exact starting value is an open question.

This mirrors the left-press (Even AI) flow:
- F5 17 (press-down) → host sends `0x0e 01` (mic enable) → `0xF1` LC3 stream
- F5 18 (release) → host sends `0x0e 00` (mic disable) → stream ends

The analogous QuickNote flow:
- Long-press-right starts → firmware records on-glasses
- Long-press-right release → `0x21` arrives → host sends `1e 06 00 <seq> 02 01`
  → `0x1e c8 ...` audio stream → host sends `1e 06 00 <seq> 04 01` → done

## 0x21 42-byte variant (observed 2026-05-08, live device)

On-device testing with the custom app (not the official Even Realities app)
produced `0x21` frames of **42 bytes**, not 15 bytes. Every long-press-right
produced 42-byte events regardless of display state.

Sample: `21 2a 00 17 01 04 01 f7 ce 93 65 ed c4 be e4 02 90 cf 93 65 f8 22
06 e3 03 cc cf 93 65 5e 38 18 1a 04 36 d0 93 65 3a 90 44 a2`

Decoded structure:
- byte 0 = `0x21` opcode
- byte 1 = `0x2a` = 42 (total frame length)
- byte 2 = `0x00`
- byte 3 = sequence (incrementing per press: 0x13, 0x15, 0x16, 0x17 observed)
- bytes 4–6 = `01 04 01` where `04` = "4 records"
- bytes 7..41 = 4 records, each 8–9 bytes, indexed `01..04`, each containing
  a 4-byte timestamp-like field (`xx xx 93 65` pattern) + 4 bytes likely UID

This appears to be a **notes-list metadata dump** — the firmware telling the
host "you have 4 stored notes, here are their UIDs/timestamps". Contrast with
the recon's 15-byte event which was a "just saved this specific note" release.

**Open question:** will sending `02 01` after a 42-byte `0x21` trigger an
audio stream? Or does it only work after the 15-byte variant? Test pending
(code is in place via `Proto.quickNoteRequestAudio`; next session just needs
a hot-reload + long-press test).

## Surprises / open questions

- **Only 1 of 3 long-presses fired `0x21`.** Suggests a minimum-duration
  threshold in the firmware. Worth measuring once we instrument the app to
  log press duration alongside the `0x21` event.
- **Byte-5 of the chunk header is `0x31`** in this capture but was reported
  as `0x61` in prior docs. May be a session-codec id or a per-note variant.
  Doesn't affect buffering but is a future-investigation breadcrumb.
- **The trailing `1e 06 00 42 04 00`** is the only `0x1e 06` notification
  immediately after a stream. Sub-code `0x06` appears throughout the capture
  with various payloads — looks like a generic "status / counter" channel,
  not specific to QuickNote. Useful as a stream-end signal (because it's
  *anything not `0xc8`*), not because it specifically means "stream done".
- **Frame cadence is bursty, not steady.** Inter-frame gaps within the
  stream range from 1 ms to 30 ms. This is BLE delivery cadence (driven by
  connection interval), not audio framerate. Don't tune timeouts off
  inter-frame gap — tune off the post-stream gap.
- ~~No 0x1e TX from host during the cycle~~ — **superseded by the
  host-initiated handshake discovery (2026-05-08).** The host sends
  `1e 06 00 <seq> 02 01` to trigger the stream and `1e 06 00 <seq> 04 01`
  to acknowledge receipt. This was missed in the initial analysis because
  only RX traffic was reviewed; re-analysis of TX traffic confirmed it.
- **42-byte `0x21` variant and audio streaming** — as of 2026-05-09, the
  pipeline opens a QuickNote capture buffer on any right-side `0x21` of
  length ≥ 7 (covering both the 15-byte and 42-byte variants). Whether
  sending `02 <idx>` after a 42-byte release successfully triggers an audio
  stream on firmware 1.6.6 is pending live confirmation.

## Confidence

- Stream-end mechanism: **High** (single capture, but the mechanism is
  unambiguous).
- Chunk header layout: **High** (consistent across all 48 frames).
- Byte-5 field meaning: **Low** (single value, no comparison).
- Press-duration threshold: **Low** (only 1 of 3 fired; need more data).
