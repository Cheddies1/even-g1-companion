# External protocol notes — JohnRThomas wiki, Gadgetbridge, ayroblu (2025–2026)

> **Document type:** G1 reference — external comparison
> **Audience:** Anyone integrating with or reverse-engineering the Even Realities G1
> **Evidence basis:** Cross-reference against external sources: JohnRThomas wiki, Gadgetbridge `even-g1-custom-drawing-experiment` branch, ayroblu/bazel-demo Swift implementation (not capture-based)

Artifact:

- `JohnRThomas/EvenDemoApp` wiki page: `Even-Realities-G1-BLE-Protocol`
- URL: `https://github.com/JohnRThomas/EvenDemoApp/wiki/Even-Realities-G1-BLE-Protocol`
- Last noted edit on the page: `Dec 30, 2025` (per the GitHub wiki header)

This document is a **pointer + gap list** for later investigation. It is not a
new source of truth and should not override the app’s “trusted behaviour” list
in `AGENTS.md` or our live-test-derived findings in:

- `docs/even-g1-event-mapping.md`
- `docs/protocol-reference.md`
- `docs/FINDINGS-*.md`

## What the wiki seems strongest on (relative to our current docs)

### `0x22` status packet hypotheses

The wiki proposes concrete field layouts for at least two `0x22` “Status”
message variants (including dashboard/pane mode + page-ish fields). In our app,
we currently treat `0x22` as a dashboard-family packet and mostly log it rather
than decoding it.

Why this matters:

- If we ever want to do something smarter with dashboard state (unread counts,
  pane/page inference, low-power hints), `0x22` is a plausible place to start.

Suggested follow-up:

- Add a debug-only (`COMPANION_VERBOSE_LOGS=true`) decoder attempt for the
  `0x22` shapes against our captured logs, and explicitly mark it “hypothesis”
  until validated.

### `0x26` touch/settings family breadth

The wiki lists multiple `0x26` “Hardware Set” subcommands and labels
`0x26 … 05` as “Set Double Tap Action”.

What we already have:

- We already use and have live-confirmed `0x26 06 00 <seq> 05 <value>` as the
  persisted “double-tap action” setting, and we document the confirmed values
  in `docs/protocol-reference.md`.

Potential value:

- The wiki’s additional `0x26` subcommand catalogue might help us prioritise what
  to investigate next (without re-deriving everything from snoops).

### `0x29` brightness get (readback)

The wiki documents a “Brightness Get (0x29)” request/response shape as
`29 65 <level> <auto>`, claiming byte 3 is an auto-brightness flag.

**Empirical probe results (firmware 1.6.6):** Two separate probes against
current firmware returned byte 3 = `0x00` in both cases, even after
auto-brightness had been enabled via the official app and via the companion
app. This leaves two interpretations open:

- The wiki is wrong about byte 3's meaning; or
- The firmware does not persist the auto state across BLE disconnect — it
  resets to OFF on every fresh connect regardless of what was last written.

The existing capture data does not let us distinguish between these. Byte 3
is therefore **unverified** on firmware 1.6.6. The level byte (byte 2) is
consistent with the `F5 12` echo and appears reliable.

For this app's handling, see `current-architecture.md` — “Authoritative
settings model” — which moots the reconcile question by re-pushing on every
connect.

Cross-reference: `docs/protocol-reference.md` — “Brightness: `0x01 <level>
<auto>` and `F5 12 <level>`”.

## Areas where our docs appear ahead (and the wiki is TODO / missing detail)

The wiki has many high-level “Operations” sections that are still `TODO` (text
rendering, image display, AI dictation, navigation, notifications, etc.).

In contrast, we already have working, capture-backed notes for several newer
rendering/control families beyond `0x4E` text and BMP, including:

- `0x52` live streaming text (cursor-style incremental)
- `0x0a` navigation structured card
- `0x1e` TX dashboard data slot injection
- `0x50` display mode control

Those are documented in:

- `docs/protocol-reference.md`
- `docs/FINDINGS-layouts.md`

## Event mapping differences to treat cautiously

The wiki includes labels such as:

- `F5 01` = “TouchPad Single Tap”
- `F5 1E` / `F5 1F` = dashboard open/close (double tap)

We should not treat these as product-ground-truth for this app because:

- Live testing (as of `2026-04-28`) has **not** confirmed reliable app-visible
  single taps in the states we care about.
- Our current model treats `F5 1E` / `F5 1F` as “dashboard/state follow-ons”
  (and we explicitly document additional follow-ons like `F5 30/31` in
  `AGENTS.md`).

Action:

- If we ever revisit these mappings, do it via fresh captures + live testing,
  and keep the “trusted behaviour” list authoritative.

## Additional external references (found 2026-04-28)

### Gadgetbridge `even-g1-custom-drawing-experiment` branch

- Repo: `codeberg.org/jrthomas270/Gadgetbridge` branch
  `even-g1-custom-drawing-experiment`
- Contains a comprehensive `G1Constants.java` with named constants for most
  command and event families. Not all constants are used in the implementation
  — several rendering-related sections are stub/TODO.

Key value for us:

- **`NavigationSubcommand`** names all six `0x0a` sub-commands:
  `INIT (0x00)`, `TRIP_STATUS (0x01)`, `MAP_OVERVIEW (0x02)`,
  `PANORAMIC_MAP (0x03)`, `SYNC (0x04)`, `EXIT (0x05)`, `ARRIVED (0x06)`.
  `SYNC` is a commit/render signal, not just a "ready" marker. The official
  app sends SYNC both before AND after the card data.
- **`DashboardSetSubcommand`** (`0x06` family): sub-commands for
  TIME_AND_WEATHER (0x01), WEATHER (0x02), CALENDAR (0x03), STOCKS (0x04),
  NEWS (0x05), MODE (0x06), CANVAS (0x07).
- **`DashboardQuickNoteSubcommand`** (`0x1e` family): sub-commands for
  audio metadata get, audio file get, note text edit, audio file delete,
  note status edit, note add.
- **`HardwareSubcommand`** (`0x26` family): confirms our DOUBLE_TAP_ACTION
  (0x05) and adds DISPLAY (0x02), LUM_GEAR (0x04), LUM_COEFFICIENT (0x06),
  LONG_PRESS_ACTION (0x07), HEAD_UP_MIC_ACTIVATION (0x08).
- **`EventId`** confirms all our F5 mappings and adds:
  `ACTION_LONG_PRESS (0x12)` — the intermediate event between hold (0x17)
  and release (0x18). Also `ACTION_DOUBLE_TAP (0x20)` is labelled as
  "strictly a double tap" rather than "transcribe".
- **`CommandId.UNKNOWN = 0x50`** — they don’t know what 0x50 does either.
- **`CommandId.TELEPROMPTER_CONTROL = 0x09`**, **`TRANSCRIBE_CONTROL = 0x0D`**,
  **`TRANSLATE_CONTROL = 0x0F`** — direct mode-entry opcodes we haven’t used.

### ayroblu/bazel-demo Swift G1 protocol implementation

- Repo: `github.com/ayroblu/bazel-demo` path `g1-app/g1protocol/`
- Contains a working Swift implementation of the G1 navigation protocol.

Key value for us:

- **TRIP_STATUS packet structure decoded**:
  `[null, seqId, 0x01, DirectionTurn_enum] + x_coords + [y, null] +
  totalDuration\0 + totalDistance\0 + direction\0 + distance\0 + speed\0`
  The `DirectionTurn` enum (0x01–0x23) maps to turn types: Straight (0x02),
  Right (0x03), Left (0x04), SlightRight, UTurnLeft, roundabout variants, etc.
  Our snoop showed `0x03` = Right for the Church Road instruction — matches.
  The `x`/`y` coordinates and DirectionTurn byte in our snoop prefix
  `01 03 c8 00 12 00` decode as: sub-cmd=0x01, turn=Right(0x03), x=[0xc8,0x00],
  y=0x12, null=0x00.
- **MAP_OVERVIEW is 136×136 pixels, RLE encoded** — not 108×108 as we assumed
  from the BMP service. RLE format confirmed as simple `<count> <byte>` pairs
  from the ayroblu Swift source (`runLengthEncode()` / `runLengthDecode()`).
  Pixel layout is **row-major, LSB-first** (NOT column-major as we initially
  assumed). Image is two layers (image + overlay boolean arrays concatenated
  via `(image + overlay).toBytes().runLengthEncode()`), total 4,624 raw bytes.
  The `toBytes()` packs bools LSB-first (bit 0 = first pixel in each group
  of 8). Band splitting: 185-byte chunks, 9-byte packet header per band.
- **PANORAMIC_MAP is 488×136, UNENCODED** — raw bitmap, not compressed.
- **SYNC/poller has a pollerSeqId byte**: `[0x0a, length, null, seqId, 0x04,
  pollerSeqId]`. Our implementation uses 0x01 for this byte.

## Investigation backlog derived from all comparisons

1. Validate or reject the wiki’s `0x22` field breakdown against our logs.
2. ~~Probe `0x29` brightness get on current firmware~~ — **PROBED**: byte 3
   (wiki-claimed auto flag) returned `0x00` on two probes even after auto was
   set ON; unresolved whether wiki is wrong or firmware resets auto on
   disconnect. Moot for this app — authoritative-settings model re-pushes on
   every connect anyway.
3. Cross-check the wiki’s `0x26` subcommand list against our `docs/FINDINGS-settings.md`
   and snoops to see if any high-impact settings are missing from our current
   mapping.
4. ~~Try using the proper DirectionTurn enum byte in TRIP_STATUS~~ — **DONE**:
   `classifyManoeuvre()` in `nav_icon_generator.dart` maps instruction text
   to `ManoeuvreType` enum (0x01–0x0b). Full DirectionTurn values confirmed
   from ayroblu Swift source.
5. ~~Investigate `0x0a` acked vs fire-and-forget~~ — **RESOLVED**: fire-and-forget
   (`sendData`) confirmed correct. Firmware does not ack `0x0a` commands.
6. Investigate whether SYNC needs a specific `pollerSeqId` value.
7. Try `TELEPROMPTER_CONTROL (0x09)`, `TRANSCRIBE_CONTROL (0x0D)`, and
   `TRANSLATE_CONTROL (0x0F)` as direct mode-entry alternatives to relying
   on the official app’s double-tap setting for `F5 20`.

