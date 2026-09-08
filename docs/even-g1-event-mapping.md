# Even G1 Event Mapping

> **Document type:** G1 reference
> **Audience:** Anyone integrating with or reverse-engineering the Even Realities G1
> **Evidence basis:** HCI snoop captures + live testing, firmware 1.6.6; structural cross-check against the firmware decompilation

This file captures the current working understanding of `F5` gesture and state
events observed from the Even G1 glasses.

It is intentionally split by behaviour category and confidence so we do not
overstate what has been confirmed.

## Document role

This is the current event-behaviour mapping document.

It is intentionally separate from:
- [protocol-reference.md](protocol-reference.md): wire-level BLE command catalogue
- [investigation-notes.md](investigation-notes.md): broader exploratory notes and hypotheses
- [firmware-decomp-notes.md](firmware-decomp-notes.md): firmware decompilation — structural cross-check only, no behavioural evidence
- [python-sdk-comparison-notes.md](python-sdk-comparison-notes.md): comparison/reference only

## Scope

- Source of truth is currently:
  - isolated manual test runs
  - Flutter/native debug logs
  - observed behaviour on the glasses
- This is a working mapping, not a finished protocol specification.
- Event meanings may be firmware-dependent.

## Confidence labels used here

Three tiers, consistent with [protocol-reference.md](protocol-reference.md):

- `Confirmed`: observed in current app/device testing or HCI snoop captures
- `Suspected`: plausible and partially aligned with testing, but not fully pinned down
- `Firmware-source`: read out of the decompiled firmware — good for structure and for
  corroborating a negative, never a substitute for observing the behaviour
- `Vendor-claimed only`: preserved from demo/vendor material or Python SDK labels; not confirmed against current firmware

## How the firmware builds an `F5` frame

`Firmware-source` (2026-09-07, `deal_event_to_phone.c`). The outbound frame is
assembled as `F5 <event_code>` with the internal event code passed through
**verbatim** on the default path, then sent with a fixed 21-byte length. So the
premise of this whole document — that F5 sub-codes are a flat enumeration of
firmware-internal event ids — is structurally correct rather than just a
convenient model.

Three event codes are special-cased into acknowledgement frames instead
(`<opcode> C9 <state>` for `0x0D`, `0x0F`, `0x4E`), which is where the
firmware's generic `0xC9` success code shows up. A handful carry a value byte
fetched from firmware state at send time — `F5 0A`, `F5 0E`, `F5 0F`, `F5 12`.

The emitter runs off an internal message queue: `ble_process_req_dispatch.c`
calls it when the queued message type is `0xf5`. So "does this gesture reach
the phone?" reduces to "does its handler enqueue an `0xf5` message?" — which
is why single clicks produce nothing (see `F5 01` below).

See [firmware-decomp-notes.md](firmware-decomp-notes.md).

## Firmware vs App behaviour model

The G1 operates in three layers: (1) firmware-native behaviour that exists
even without a phone connection (tilt detection, QuickNote, some touch
semantics); (2) persisted configuration written by the official app and stored
on-device across disconnects (e.g. "dashboard on tilt"); and (3) app-driven
BLE behaviour where the connected app acts as transport layer, content
provider, and feature-override layer (text rendering, bitmap rendering,
notification rendering, voice paths).

For the full model with examples and evidence, see
[investigation-notes.md § System model](investigation-notes.md#system-model).

## Confirmed behaviour

- tilt detection is firmware-side
- "dashboard on tilt" is a persisted device setting
- left hold:
  - when disconnected -> shows Bluetooth disconnected
  - when connected -> enters the app's current voice path
- right hold:
  - works even when disconnected
  - activates the firmware-native QuickNote recording feature
  - on release, the firmware emits `0x21` (notes-list metadata); the host
    must request audio via `1e 06 00 <seq> 02 <noteIndex>` — firmware does
    not stream unsolicited
  - fully documented in [protocol-reference.md](protocol-reference.md) §
    "QuickNote protocol family"
- double left tap:
  - when a feature is active, it produces `F5 00`
  - behaviour matches close active feature / return home
- `F5 02`:
  - high-confidence tilt up / head-up trigger
  - still emitted even when dashboard-on-tilt is disabled
- `F5 03`:
  - high-confidence return-to-center event after head-up
- single left/right taps are not app-visible in the tested dashboard or generic
  text flows
- triple tap likely emits a separate forwarded event family

## User Interaction Events

### Confirmed

#### `F5 17`

- Meaning: connected left-hold entry into the app's current voice path
- Confidence: Suspected
- Evidence:
  - during isolated left-hold testing while connected, `F5 17` is followed by:
  - `EvenAI.get.toStartEvenAIByOS()`
  - `Proto.micOn(...)`
  - incoming mic audio frames
- Notes:
  - the same hold gesture behaves differently when disconnected, which supports
    the idea that this is a firmware entry point into a connected feature path

#### `F5 18`

- Meaning: left long-press release (voice / Even AI stop)
- Confidence: Confirmed
- Evidence:
  - in the 2026-04-28 taps capture, paired with `F5 17` press-down on every
    left long-press: e.g. `14:10:05 F5 17` → `14:10:08 F5 18`,
    `14:19:00 F5 17` → `14:19:08 F5 18`. Never observed without a preceding
    `F5 17`.
  - current routing: handled by `companion_controller.dart` (`F5 18 routed in
    Glance mode`); the legacy `EvenAI.recordOverByOS()` handler that was the
    original demo response has been removed.
- Notes:
  - right long-press (QuickNote) does **not** fire `F5 17`/`F5 18`; it uses
    the `0x21` family instead (see the right-hold section below)

### `F5 00`

- Meaning: close active feature / return home
- Confidence: Confirmed
- Evidence:
  - when a feature is visibly active on the glasses
  - sending `Hello from EvenDemoApp`
  - then double-left-tapping
  - consistently produces `F5 00`

### `F5 01`

- Meaning: app-routed paging event in code, but not confirmed from current
  device testing
- Confidence: Vendor-claimed only for real firmware behaviour; the current app code does route it (see Notes)
- Evidence:
  - in Flutter, [lib/ble_manager.dart](../lib/ble_manager.dart#L182)
    routes:
  - left -> feature previous
  - right -> feature next
- Notes:
  - repeated device testing did not surface `F5 01` from single left/right taps
    in dashboard mode or generic text rendering mode
  - the 2026-04-28 taps capture (see
    [FINDINGS-taps.md](FINDINGS-taps.md))
    explicitly tested single taps in (a) idle with no display content and
    (b) dashboard up with a notes / notifications list visible. In **both**
    states the firmware visibly responded on the glasses (notes/notifications
    cycled) but **no** `F5 01` (or any other F5 event) fired. This is the
    strongest possible negative result for the "firmware forwards taps when
    there's a target" hypothesis.
  - current model: single taps are absorbed by the firmware in every observed
    state. The companion app should not be designed around them.
  - `Firmware-source` (2026-09-07) corroborates this, and explains the
    mechanism. `touch_key_thread.c` classifies the gesture into a key-event
    type (`DAT_200084f8`: 1 = single click, plus types 2-6 for the other
    gestures) and `key_event_thread.c` dispatches it. The single-click branch
    goes to firmware-local actions and master→slave sync — the thread logs
    `master send calendar key single click ,timestamp = %d` and
    `Click event does not respond, close Quicknote to prevent exceptions`.
    Nothing on that branch enqueues an outbound `0xf5` message, which is what
    `deal_event_to_phone.c` needs in order to emit an `F5` frame.
  - That is a direct structural match for the capture result: the firmware
    *did* visibly respond on the glasses (notes/notifications cycled) while
    emitting no BLE event, because single click is wired to the local
    dashboard and to the other temple, not to the host. Corroboration rather
    than proof — the decompilation is only 60% labelled on app functions and
    another route out cannot be excluded — but it points the same way.
    **Guardrail stands.**

### Confirmed (promoted from Suspected post-implementation)

#### Right-hold QuickNote path

- Meaning: firmware-native QuickNote recording and retrieval flow
- Confidence: Confirmed
- Evidence:
  - right hold works even while disconnected and triggers on-device recording
  - confirmed separate from the Even AI `F5` start/stop family — uses `0x21`
    and `0x1e` opcode families exclusively
  - QuickNote v1 shipped 2026-05-09: full pipeline from right-hold through to
    Notes UI is implemented and confirmed end-to-end
  - full protocol documentation in
    [protocol-reference.md](protocol-reference.md) §
    "QuickNote protocol family"

#### `R21`

- Meaning: QuickNote notes-list metadata packet; emitted on right-hold release
- Confidence: Confirmed
- Evidence (historic captures, retained):
  - appears consistently after right-hold release in all repeated runs
  - earlier captures (pre-2026-04-28) observed packet length `42` — now
    confirmed as the 42-byte notes-list dump variant
  - the 2026-04-28 taps capture observed length `15` for every right-hold
    release (`21 0f 00 <id> 01 01 01 <8 bytes>`). The byte at offset 3 is
    the note index (non-sequential across captures, consistent with a
    per-slot ID); bytes 7–14 are a timestamp/UID block also seen in the
    `0x06` note-management transactions. Both the 15-byte (single-note) and
    42-byte (notes-list dump) variants are now fully decoded — see
    [protocol-reference.md](protocol-reference.md) §
    "QuickNote protocol family" for byte maps.
  - both spoken-note and silence runs produce `R21`
  - the 2026-04-28 settings capture (Phase 3 quicknotes, see
    [FINDINGS-settings.md](FINDINGS-settings.md))
    identified a chunked binary stream on `0x1e c8 ...` emitted after
    `R21`. Frame count scales with recording duration (~50 frames for 3 s
    silence vs ~100 for 10 s). This was the key discovery that led to the
    audio retrieval path investigation. **Important correction from earlier
    analysis:** the firmware does NOT stream audio unsolicited — the `0x1e
    c8` stream is triggered by a host TX request (`1e 06 00 <seq> 02
    <noteIndex>`). The framing previously noted (`1e c8 00 <seq1> 02 61 00
    <seq2> 00 01 <~130 bytes>`) underestimated payload size; confirmed
    chunk structure is a 10-byte header + 190-byte LC3 payload.
  - the 8-byte trailing block in the `R21` payload is confirmed as the UID
    of the just-saved note, consistent with the `0x06` note-management
    transactions — see "Note management" in
    [protocol-reference.md](protocol-reference.md).
- Notes:
  - `R21` does not contain raw speech transcript text — confirmed; it carries
    metadata (note index, slot count, UID, timestamps)
  - the small counter/index-looking field that increments across captures is
    the note slot index; the circular 4-slot buffer model is `Suspected` (see
    [protocol-reference.md](protocol-reference.md))

#### `F5 04`

- Meaning: triple-tap silent-mode enable
- Confidence: Confirmed
- Evidence:
  - observed during triple-tap testing
  - 2026-04-28 taps capture: `F5 04` at `14:07:48` correlates with the user's
    annotated "accidental triple tap to silence" at `14:07:53`, paired with
    a re-activation `F5 05` at `14:07:52`

#### `F5 05`

- Meaning: triple-tap silent-mode disable
- Confidence: Confirmed
- Evidence:
  - observed during triple-tap testing in the same family as `F5 04`
  - 2026-04-28 taps capture: paired with the matching `F5 04` enable
    immediately preceding it

#### `F5 20`

- Meaning: double-tap delegates to the host because the configured action is
  host-handled — fires for either temple when the official Even Realities
  app's "double-tap action" is set to a host-driven feature
- Confidence: Confirmed
- Evidence:
  - 2026-04-28 taps capture: two clean `F5 20` samples (one per temple), both
    correlated with a double-tap that opened transcribe-mode while the
    official app was set to **transcribe**
  - 2026-04-28 follow-up live testing confirmed the pattern across
    configurations:
    - **Transcribe** → `F5 20` fires → mode cycle works
    - **Translate** → `F5 20` fires → mode cycle works
    - **Teleprompter** → `F5 20` fires → mode cycle works
    - **Dashboard** → no `F5 20`. The firmware shows the dashboard locally
      even with the official app force-stopped, confirming it's a
      firmware-native action handled below the BLE boundary.
    - **None** ("close active feature") → no `F5 20`. Only `F5 00` fires,
      and only when there is an active feature to close.
- Notes:
  - the pattern is consistent: any official-app double-tap action that
    requires the host (mic / network / text rendering) emits `F5 20`; any
    action the firmware can fulfil locally is handled below the BLE boundary
  - 1–6 second latency between the physical tap and the BLE event was
    observed in the snoop, likely because the firmware fires `F5 20` once the
    feature-open animation completes rather than on the gesture edge
  - the on-glasses overlay for the configured action (e.g. Transcribe's
    listening prompt) still appears briefly even though the companion app
    repurposes the event for mode switching — there's no way to suppress it
    without a different protocol path
  - this app routes `F5 20` to
    [CompanionController.handleDoubleTapModeSwitch](../lib/services/companion_controller.dart),
    which cycles the companion mode and is debounced at 1500 ms. See
    [FINDINGS-taps.md](FINDINGS-taps.md)
    for the full capture-derived reasoning.

## Firmware Semantic Events

### Confirmed

#### `F5 00`

- Meaning: close active feature / return home
- Confidence: Confirmed
- Evidence:
  - repeated clean feature-close runs after text rendering

## Sensor / State Events

### Confirmed behaviour without fixed event ID

- tilt detection is firmware-side
- dashboard-on-tilt is controlled by a persisted device setting
- when that setting is disabled in the official app, tilt can produce no visible
  dashboard behaviour even without a phone connection
- disabling dashboard-on-tilt suppresses visible firmware UI behaviour, not the
  underlying tilt event emission

### Battery and wear state (confirmed via official-app HCI snoop)

These sub-codes were resolved by capturing the official Even Realities Android
app over BLE and matching observed payload bytes against the on-screen battery
percentages. The detailed write-up lives in
[FINDINGS-battery+brightness.md](FINDINGS-battery+brightness.md);
the corresponding raw protocol entries are in
[protocol-reference.md](protocol-reference.md).

The current Flutter ingestion lives in
[lib/services/device_status_service.dart](../lib/services/device_status_service.dart),
fed from the existing F5 dispatch in
[lib/ble_manager.dart](../lib/ble_manager.dart).

#### `F5 06`

- Meaning: glasses are being worn
- Confidence: Confirmed
- Evidence:
  - emitted exactly when the glasses come out of the cradle and are donned
  - paired with a subsequent burst of `F5 0A` battery pushes while worn

#### `F5 07`

- Meaning: transitioning between worn and cradled (or vice versa)
- Confidence: Confirmed
- Evidence:
  - consistently appears between `F5 06` and `F5 08`/`F5 0B` boundary events
- Notes:
  - too transient to drive UI state directly; the app ignores it for wear-state
    classification

#### `F5 08`

- Meaning: in cradle, lid open
- Confidence: Confirmed
- Evidence:
  - emitted on cradle-open transitions and on initial connect when the glasses
    are sitting in an open cradle

#### `F5 0A <pct>`

- Meaning: glasses battery percentage push
- Confidence: Confirmed
- Evidence:
  - byte 2 carries a 0–100 value
  - matched the on-screen value in the official app exactly (100% during the
    capture; the byte was `0x64`)
  - pushed every ~1–2 s while the glasses are being worn; quiet otherwise
- Notes:
  - both temples emit this independently; the app accepts whichever arrives
    most recently
  - **the value is synthesised near full charge** (`Firmware-source`,
    2026-09-07). `deal_event_to_phone.c` does not pass the raw gauge value
    through for event `0x0a`. Raw values below `0x5d` (93) are passed through
    unchanged; raw `0x5d`–`0x60` (93–96) are remapped upward through 94–98
    depending on a second state flag; anything above `0x60` (96) is clamped to
    `0x64` (100). So anything we display in the 94–100% band is a
    firmware-constructed value, not a measurement. This is consistent with the
    capture reading `0x64` at "100%", and it is the likely answer to "why does
    it sit at 100% for so long".

#### `F5 0B`

- Meaning: in cradle, lid closed
- Confidence: Confirmed
- Evidence:
  - emitted on cradle-close transitions

#### `F5 0E <flag>`

- Meaning: cradle charging cable state
- Confidence: Suspected
- Evidence:
  - byte 2 toggles between `0x00` and `0x01` paired with `F5 09` events
  - aligns with the Python SDK label "Cradle charging cable state changed"
- Notes:
  - the flag interpretation (0 = unplugged / 1 = plugged, or vice versa) is not
    yet validated against a deliberate plug/unplug capture

#### `F5 0F <pct>`

- Meaning: case (cradle) battery percentage push
- Confidence: Confirmed
- Evidence:
  - byte 2 carries a 0–100 value
  - matched the on-screen "Case 60%" value in the official app exactly
    (`0x3c` = 60)
  - pushed alongside other cradle state events; less frequently than `F5 0A`

#### `F5 12 <level>`

- Meaning: brightness state push (echoes the most recent brightness level)
- Confidence: Confirmed
- Evidence:
  - byte 2 mirrored the value most recently sent via the brightness command
    `0x01 <level> <auto>`
  - observed values 0–42 (`0x00`–`0x2a`) tracking the official app's brightness
    slider movement
  - this app now sends the same `0x01 <level> <auto>` command from the home
    screen Display section, and the `F5 12` echo is ingested by
    `DeviceStatusService` to drive the "Confirmed: N" indicator
- Notes:
  - the auto byte is not echoed back by the firmware; the app tracks it
    locally from the last sent value

### Confirmed

#### `F5 02`

- Meaning: dashboard open / tilt-up start
- Confidence: Confirmed
- Evidence:
  - isolated Run 5 with dashboard-on-tilt disabled
  - repeated pattern of tilt up followed by `F5 02`
  - no display/dashboard shown during the test
- Notes:
  - event still emits even when dashboard-on-tilt is disabled
  - observed on the right leg in current logs
  - the right-leg-only observation may reflect firmware reporting behaviour
    rather than a truly right-only physical capability
  - current best model is that this is the gesture/start edge, not the full
    dashboard-open confirmation by itself

#### `F5 03`

- Meaning: dashboard close / tilt-down start
- Confidence: Confirmed
- Evidence:
  - isolated Run 5
  - repeatedly follows `F5 02` after the head returns from the raised position
- Notes:
  - observed on the right leg in current logs
  - the right-leg-only observation may reflect firmware reporting behaviour
    rather than a truly right-only physical capability
  - current best model is that this is the gesture/start edge, not the full
    dashboard-close confirmation by itself

### Suspected

#### `F5 09`

- Meaning: cradle/charge substate paired with `F5 0E` cable state
- Confidence: Vendor-claimed only
- Evidence:
  - byte 2 toggles between `0x00` and `0x01`
  - emitted ~1 s before each `F5 0E` cable-state event with the matching value
  - originally hypothesised as a tilt/head-up state but the snoop pairing with
    `F5 0E` is more consistent with a cradle/charge substate
- Notes:
  - the exact 0/1 semantics are not yet pinned down

#### `F5 10`

- Meaning: secondary tilt/head-up state event or tilt payload update
- Confidence: Suspected
- Evidence:
  - recurring in idle runs
  - often carries a nontrivial payload such as `64 00 00 00 00 00`

#### `F5 30`

- Meaning: dashboard open confirmed / state-up follow-on event
- Confidence: Suspected
- Evidence:
  - repeatedly follows `F5 02` in isolated dashboard-up runs
  - appears on both legs shortly after the tilt-up start event
  - aligns with the Python SDK mapping `0x1E -> OPEN_DASHBOARD_CONFIRM`
    in `utils/constants.py`
 - Notes:
  - best treated as a firmware confirm/state event associated with up
  - not the primary gesture edge itself

#### `F5 31`

- Meaning: dashboard close confirmed / state-down follow-on event
- Confidence: Suspected
- Evidence:
  - repeatedly follows `F5 03` in isolated dashboard-down runs
  - appears on both legs shortly after the tilt-down start event
  - aligns with the Python SDK mapping `0x1F -> CLOSE_DASHBOARD_CONFIRM`
    in `utils/constants.py`
 - Notes:
  - best treated as a firmware confirm/state event associated with down
  - not the primary gesture edge itself

#### `0x22`

- Meaning: dashboard-related packet family
- Confidence: Suspected
- Evidence:
  - observed during isolated firmware-dashboard runs with the custom BMP
    dashboard disabled
  - current repeated payload seen on the right leg:
    `22 0a 00 00 01 00 00 01 04 00`
  - tends to appear after the dashboard-up sequence rather than the
    dashboard-down sequence
  - aligns with the Python SDK event category
    `0x22 -> DASHBOARD` in
    `utils/constants.py`
- Notes:
  - payload meaning is still unknown
  - current logs show this on the right leg only
  - do not infer field semantics yet
  - `Firmware-source` (2026-09-07): `0x22` has its own case in
    `ble_process_put_req.c`, so it is a genuine command family in the host
    write range rather than a stray dashboard artefact. The parser has not
    been read in detail yet — if we ever want dashboard state decoding, that
    case is the place to start, and it beats the wiki's field hypotheses as a
    source

## Rendering protocols (confirmed via official-app HCI snoop)

Three rendering paths beyond the existing `0x4E` text and `0x15/0x16/0x20`
BMP transfer were identified in the 2026-04-28 layouts capture — see
[FINDINGS-layouts.md](FINDINGS-layouts.md) for the full analysis and
[protocol-reference.md](protocol-reference.md) for packet structures:

- **`0x52` live streaming text** — word-by-word incremental text with cursor,
  used by the official app for live transcription. The companion app can use
  this for streaming Chat responses.
- **`0x0a` navigation card** — structured text data slots (ETA, distance, road
  name, turn distance) in one ~48-byte packet, plus optional icon/map bitmap
  chunks. Replaces the BMP-per-frame Navigate path.
- **`0x1e` TX dashboard data slots** — pushes titled content (note title +
  body) into the firmware's dashboard grid layout.
- **`0x50` display mode control** — primes the display before entering
  streaming text or navigation card mode.

## Unknown

These event IDs have been observed but are not yet mapped with enough confidence
to assign a meaning:

- `F5 11`
- `F5 14`
- `F5 15`
- `F5 32` — note this is hex `0x32` (= 50 decimal), distinct from the newly
  identified `F5 20` (hex `0x20` = 32 decimal). `F5 32` has not been observed
  in either of the recent snoop captures.

`F5 06`, `F5 07`, `F5 08`, `F5 0A`, `F5 0B`, `F5 0F`, `F5 12`, `F5 18`, and
`F5 20` were previously unknown / Suspected and have since been mapped — see
the "Battery and wear state" and User Interaction Events sections above.

## Current Code Notes

The current Flutter app only actively handles a small subset of `F5` events in
[lib/ble_manager.dart](../lib/ble_manager.dart#L169):

- `0` -> exit/home
- `1` -> page/navigation routing in app code
- `2` -> custom Flutter dashboard open
- `3` -> custom Flutter dashboard starts auto-close countdown on return to center
- `30` -> currently logged as dashboard open confirmed / state-up
- `31` -> currently logged as dashboard close confirmed / state-down
- `23` -> start voice flow
- `24` -> stop voice flow

Important caveat:

- the current diagnostic labels in [lib/ble_manager.dart](../lib/ble_manager.dart#L213)
  are still provisional
- they should not be treated as protocol truth
- runtime behaviour and isolated logs are more trustworthy than the current label
  names

The QuickNote pipeline shipped end-to-end in v1 (2026-05-09): right-hold
triggers firmware recording, `0x21` on release notifies the host, the host
requests audio via `0x1e`, LC3 audio is decoded to WAV, Whisper provides STT,
and the result is tidied and categorised into the Notes UI. See
[current-behaviour.md](current-behaviour.md) § "QuickNote" and
[current-architecture.md](current-architecture.md) § "QuickNote" for the full
app implementation.

## Custom Dashboard Notes

- a minimal Flutter-side dashboard flow has been proven:
  - `F5 02` opens the dashboard
  - `F5 03` does nothing
  - `F5 00` closes the dashboard
- the first sample notification renders successfully
- the dashboard remains visible after returning head position to center
- single left/right taps did not produce app-visible navigation events during
  dashboard testing
- current best hypothesis is that dashboard tap navigation, when it exists in
  official firmware behaviour, is firmware-local and not forwarded in this demo
  mode

## Text Rendering Notes

- generic text rendering in this app is currently timer-paged by
  [lib/services/text_service.dart](../lib/services/text_service.dart)
- it is not currently wired for touch-based manual paging
- this likely explains why long text sent from the demo app does not scroll via
  left/right taps the way official Even app features do

## QuickNote Notes

- right-hold is a firmware-native QuickNote flow, confirmed separate from the
  Even AI `F5` family
- on release the firmware emits `0x21` (notes-list metadata); the host must
  explicitly request audio via `1e 06 00 <seq> 02 <noteIndex>` — the firmware
  does not stream unsolicited
- `0x21` and `0x1e c8` are the primary protocol families; `F5` events are not
  part of the QuickNote path
- the full protocol is documented in
  [protocol-reference.md](protocol-reference.md) § "QuickNote protocol family"
- the app-side implementation is documented in
  [current-architecture.md](current-architecture.md) § "QuickNote"

## What We Know About The App

- The app supports:
  - BLE scan/connect
  - text rendering
  - bitmap rendering
  - notification rendering
  - Even AI voice-feature path
  - QuickNote: right-hold recording, audio retrieval, STT, tidy/categorise,
    Notes UI (3 tabs: Shopping, To Do, Notes) — shipped 2026-05-09
- See [current-behaviour.md](current-behaviour.md) for the full behavioural
  summary and [current-architecture.md](current-architecture.md) for the
  implementation detail.

## Recommended Next Logging Runs

To continue improving this map safely:

1. run one isolated gesture at a time
2. repeat the same gesture 3-5 times
3. avoid extra taps while locating the touch bar
4. record what visibly changed on the glasses
5. compare only the new `F5` events against the idle baseline

High-value remaining runs:

1. clean tilt-up
2. clean tilt-down
3. single left tap while a feature is active
4. single right tap while a feature is active
5. ~~right-hold QuickNote with minimal accidental taps~~ — **Completed** (2026-05-08/09):
   investigation informed the shipped QuickNote pipeline; see
   [FINDINGS-quicknote.md](FINDINGS-quicknote.md)

## Next Experiments

### Experiment 1 - Tilt With Dashboard Disabled

Goal:

- determine whether disabling dashboard stops only visible UI behaviour
- or also stops the underlying `F5` event emission

Why:

- we now know dashboard-on-tilt is a persisted device setting
- the next question is whether tilt remains observable to the app after the UI
  behaviour is disabled

Method:

1. disable dashboard-on-tilt in the official app
2. connect the demo app
3. perform controlled tilt up/down actions
4. capture and compare `F5` logs

### Experiment 2 - Right Hold While Connected — COMPLETED (2026-04-28 / 2026-05-08)

Goal:

- identify the event mapping for the QuickNote trigger
- determine whether the event is emitted to the app at all
- or whether the behaviour is handled entirely in firmware

Why:

- right hold clearly does something meaningful on-device
- the demo app currently does not turn that into a usable feature path

Method:

1. connect the demo app
2. perform a single clean right-hold
3. repeat 3 times
4. compare logs for repeatable deltas

**Outcome:** Right-hold release emits `0x21` on the right leg (notes-list
metadata). The event IS forwarded to the app. The `0x1e c8` audio stream is
available but only in response to a host TX request — firmware does not push
unsolicited. Full QuickNote pipeline shipped 2026-05-09. See
[FINDINGS-quicknote.md](FINDINGS-quicknote.md) for full investigation record.

### Experiment 3 - Right Hold Vs Left Hold Comparison — COMPLETED (2026-05-08)

Goal:

- confirm whether left hold and right hold share a protocol path or diverge
- validate the separation between the app's Even AI flow and firmware-native
  QuickNote behaviour

Why:

- this is the cleanest way to test whether QuickNote is just an unhandled event
  or a different subsystem

Method:

1. run a clean left-hold sequence
2. run a clean right-hold sequence
3. compare:
   - `F5` events
   - mic-open behaviour
   - audio streaming presence
   - feature-visible behaviour on the glasses

**Outcome:** Confirmed divergence. Left-hold triggers the Even AI `F5` start
flow with live `0xf1` LC3 mic streaming. Right-hold is a separate path: emits
`0x21` on release, no `F5` involvement, audio retrieved on demand via `0x1e`
host request. The two features use distinct opcode families and do not interact.
