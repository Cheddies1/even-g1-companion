# Even G1 Event Mapping

This file captures the current working understanding of `F5` gesture and state
events observed from the Even G1 glasses while testing this app.

It is intentionally split by behavior category and confidence so we do not
overstate what has been confirmed.

## Document role

This is the current event-behaviour mapping document.

It is intentionally separate from:
- [protocol-reference.md](protocol-reference.md): raw vendor/demo command reference
- [investigation-notes.md](investigation-notes.md): broader exploratory notes and hypotheses
- [python-sdk-comparison-notes.md](python-sdk-comparison-notes.md): comparison/reference only

## Scope

- Source of truth is currently:
  - isolated manual test runs
  - Flutter/native debug logs
  - observed behavior on the glasses
- This is a working mapping, not a finished protocol specification.
- Event meanings may be firmware-dependent.

## Firmware Vs App Behavior Model

We now have strong evidence that the glasses operate in three layers:

1. firmware-native behavior
2. persisted configuration
3. app-driven behavior over BLE

### 1. Firmware-native behavior

This is behavior that appears to exist on the glasses even without an active
phone connection.

Confirmed examples:

- touch and hold gestures still do something when disconnected
- tilt detection exists on-device
- some feature entry points appear to be owned by firmware rather than created
  by the demo app

### 2. Persisted configuration

Some settings appear to be written by the official app and stored on the device
itself, persisting across disconnects.

Confirmed example:

- "dashboard on tilt" is a persisted device setting
- when disabled in the official app, it stays disabled even while disconnected
- when disabled, tilt produces no visible dashboard behavior
- disabling dashboard-on-tilt suppresses the firmware UI reaction, not the
  underlying tilt event emission

### 3. App-driven behavior

The Flutter demo app acts as a transport layer and content provider on top of
the device's own firmware behavior.

Confirmed examples:

- text rendering
- notification rendering
- bitmap rendering
- the app's current voice path labeled "Even AI"

## Confirmed Behavior

- tilt detection is firmware-side
- "dashboard on tilt" is a persisted device setting
- left hold:
  - when disconnected -> shows Bluetooth disconnected
  - when connected -> enters the app's current voice path
- right hold:
  - works even when disconnected
  - likely activates a firmware-native QuickNote feature
  - is not currently implemented in the demo app
- double left tap:
  - when a feature is active, it produces `F5 00`
  - behavior matches close active feature / return home
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
- Confidence: medium-high
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
- Confidence: high (`Confirmed`)
- Evidence:
  - during isolated left-hold testing, `F5 18` is followed by
    `EvenAI.get.recordOverByOS()`
  - in the 2026-04-28 taps capture, paired with `F5 17` press-down on every
    left long-press: e.g. `14:10:05 F5 17` → `14:10:08 F5 18`,
    `14:19:00 F5 17` → `14:19:08 F5 18`. Never observed without a preceding
    `F5 17`.
- Notes:
  - right long-press (QuickNote) does **not** fire `F5 17`/`F5 18`; it uses
    the `0x21` family instead (see the right-hold section below)

### `F5 00`

- Meaning: close active feature / return home
- Confidence: high
- Evidence:
  - when a feature is visibly active on the glasses
  - sending `Hello from EvenDemoApp`
  - then double-left-tapping
  - consistently produces `F5 00`

### `F5 01`

- Meaning: app-routed paging event in code, but not confirmed from current
  device testing
- Confidence: low for real firmware behavior, high for current code path
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

### Suspected

#### Right-hold QuickNote path

- Meaning: firmware-native QuickNote flow
- Confidence: high for firmware-native behavior, medium for packet interpretation
- Evidence:
  - right hold works even while disconnected and reports a note/listening style
    behavior on-device
  - in this demo app, right hold does not trigger the implemented Even AI start
    path
  - repeated connected runs show the strongest app-visible signal on release as
    command `0x21` on the right leg
  - therefore QuickNote appears to use a different packet family from the
    app-handled Even AI `F5` start/stop flow

#### `R21`

- Meaning: likely QuickNote metadata/history or note-session summary packet
- Confidence: medium
- Evidence:
  - appears consistently after right-hold release in repeated runs
  - earlier captures observed packet length `42`
  - the 2026-04-28 taps capture observed length `15` for every right-hold
    release (`21 0f 00 <id> 01 01 01 <8 bytes>`). The byte at offset 3 looks
    like a quicknote id (non-sequential across captures), bytes 7–14 like
    a timestamp/UID. Either the firmware behaviour changed or the previous
    42-byte form was a different family member triggered in a state we
    haven't yet reproduced.
  - both spoken-note and silence runs still produce `R21`
  - the 2026-04-28 settings capture (Phase 3 quicknotes, see
    [FINDINGS-settings.md](FINDINGS-settings.md))
    additionally found that **immediately after every `R21` release the
    firmware emits a chunked binary stream on opcode `0x1e c8 ...`** —
    frame count scales with recording duration (~50 frames for 3 s
    silence vs ~100 for 10 s), framing `1e c8 00 <seq1> 02 61 00 <seq2>
    00 01 <~130 bytes>`. Bitrate (~11 kbit/s) and chunk-distribution are
    consistent with a low-bitrate voice codec — most likely the same LC3
    stream the live mic uses on `0xf1`, just on a different family. This
    is the BLE path that would let the companion app recreate the
    firmware's QuickNote feature with hosted transcription. Decode work
    is out of scope today; the cross-reference for future work is the
    existing LC3 path in
    [android/app/src/main/cpp/liblc3.cpp](../android/app/src/main/cpp/liblc3.cpp).
    Full protocol shape lives in
    [protocol-reference.md](protocol-reference.md) under "Quicknote
    post-release stream".
  - the 8-byte trailing block in the `R21` payload looks identical to the
    UID block used by the `0x06` note-management transactions (delete /
    reorder), suggesting `R21` is announcing the UID of the just-saved
    note — see "Note management" in
    [protocol-reference.md](protocol-reference.md).
- Notes:
  - `R21` likely does not contain raw recognized speech transcript text
  - more likely candidates are metadata, identifiers, timestamps, or note record
    summaries
  - a small counter/index-looking field appears to increment across captures

#### `F5 04`

- Meaning: triple-tap silent-mode enable
- Confidence: high (`Confirmed`)
- Evidence:
  - observed during triple-tap testing
  - 2026-04-28 taps capture: `F5 04` at `14:07:48` correlates with the user's
    annotated "accidental triple tap to silence" at `14:07:53`, paired with
    a re-activation `F5 05` at `14:07:52`

#### `F5 05`

- Meaning: triple-tap silent-mode disable
- Confidence: high (`Confirmed`)
- Evidence:
  - observed during triple-tap testing in the same family as `F5 04`
  - 2026-04-28 taps capture: paired with the matching `F5 04` enable
    immediately preceding it

#### `F5 20`

- Meaning: double-tap delegates to the host because the configured action is
  host-handled — fires for either temple when the official Even Realities
  app's "double-tap action" is set to a host-driven feature
- Confidence: high (`Confirmed`)
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
- Confidence: high
- Evidence:
  - repeated clean feature-close runs after text rendering

## Sensor / State Events

### Confirmed behavior without fixed event ID

- tilt detection is firmware-side
- dashboard-on-tilt is controlled by a persisted device setting
- when that setting is disabled in the official app, tilt can produce no visible
  dashboard behavior even without a phone connection
- disabling dashboard-on-tilt suppresses visible firmware UI behavior, not the
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
- Confidence: high
- Evidence:
  - emitted exactly when the glasses come out of the cradle and are donned
  - paired with a subsequent burst of `F5 0A` battery pushes while worn

#### `F5 07`

- Meaning: transitioning between worn and cradled (or vice versa)
- Confidence: high
- Evidence:
  - consistently appears between `F5 06` and `F5 08`/`F5 0B` boundary events
- Notes:
  - too transient to drive UI state directly; the app ignores it for wear-state
    classification

#### `F5 08`

- Meaning: in cradle, lid open
- Confidence: high
- Evidence:
  - emitted on cradle-open transitions and on initial connect when the glasses
    are sitting in an open cradle

#### `F5 0A <pct>`

- Meaning: glasses battery percentage push
- Confidence: high
- Evidence:
  - byte 2 carries a 0–100 value
  - matched the on-screen value in the official app exactly (100% during the
    capture; the byte was `0x64`)
  - pushed every ~1–2 s while the glasses are being worn; quiet otherwise
- Notes:
  - both temples emit this independently; the app accepts whichever arrives
    most recently

#### `F5 0B`

- Meaning: in cradle, lid closed
- Confidence: high
- Evidence:
  - emitted on cradle-close transitions

#### `F5 0E <flag>`

- Meaning: cradle charging cable state
- Confidence: medium
- Evidence:
  - byte 2 toggles between `0x00` and `0x01` paired with `F5 09` events
  - aligns with the Python SDK label "Cradle charging cable state changed"
- Notes:
  - the flag interpretation (0 = unplugged / 1 = plugged, or vice versa) is not
    yet validated against a deliberate plug/unplug capture

#### `F5 0F <pct>`

- Meaning: case (cradle) battery percentage push
- Confidence: high
- Evidence:
  - byte 2 carries a 0–100 value
  - matched the on-screen "Case 60%" value in the official app exactly
    (`0x3c` = 60)
  - pushed alongside other cradle state events; less frequently than `F5 0A`

#### `F5 12 <level>`

- Meaning: brightness state push (echoes the most recent brightness level)
- Confidence: high
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
- Confidence: high
- Evidence:
  - isolated Run 5 with dashboard-on-tilt disabled
  - repeated pattern of tilt up followed by `F5 02`
  - no display/dashboard shown during the test
- Notes:
  - event still emits even when dashboard-on-tilt is disabled
  - observed on the right leg in current logs
  - the right-leg-only observation may reflect firmware reporting behavior
    rather than a truly right-only physical capability
  - current best model is that this is the gesture/start edge, not the full
    dashboard-open confirmation by itself

#### `F5 03`

- Meaning: dashboard close / tilt-down start
- Confidence: high
- Evidence:
  - isolated Run 5
  - repeatedly follows `F5 02` after the head returns from the raised position
- Notes:
  - observed on the right leg in current logs
  - the right-leg-only observation may reflect firmware reporting behavior
    rather than a truly right-only physical capability
  - current best model is that this is the gesture/start edge, not the full
    dashboard-close confirmation by itself

### Suspected

#### `F5 09`

- Meaning: cradle/charge substate paired with `F5 0E` cable state
- Confidence: low-medium
- Evidence:
  - byte 2 toggles between `0x00` and `0x01`
  - emitted ~1 s before each `F5 0E` cable-state event with the matching value
  - originally hypothesised as a tilt/head-up state but the snoop pairing with
    `F5 0E` is more consistent with a cradle/charge substate
- Notes:
  - the exact 0/1 semantics are not yet pinned down

#### `F5 10`

- Meaning: secondary tilt/head-up state event or tilt payload update
- Confidence: medium
- Evidence:
  - recurring in idle runs
  - often carries a nontrivial payload such as `64 00 00 00 00 00`

#### `F5 30`

- Meaning: dashboard open confirmed / state-up follow-on event
- Confidence: medium-high
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
- Confidence: medium-high
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
- Confidence: medium
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
- runtime behavior and isolated logs are more trustworthy than the current label
  names

There is now a narrow QuickNote-related POC in the app codebase:
- idle-only mode switching based on right-leg `R21`
- current gate: `len == 42`
- current debounce: `1500ms`
- it does not depend on `F5`

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
  official firmware behavior, is firmware-local and not forwarded in this demo
  mode

## Text Rendering Notes

- generic text rendering in this app is currently timer-paged by
  [lib/services/text_service.dart](../lib/services/text_service.dart)
- it is not currently wired for touch-based manual paging
- this likely explains why long text sent from the demo app does not scroll via
  left/right taps the way official Even app features do

## QuickNote Notes

- right-hold should now be treated as a firmware-native QuickNote flow
- the most meaningful app-visible signal is not an `F5` start event
- the strongest repeatable signal occurs on release as command `0x21` on the
  right leg
- `F5 18` may accompany right-hold release as a stop/end-state signal
- but `F5` alone is not sufficient to model QuickNote
- `R21` is currently the primary packet family to watch

## What We Know About The App

- The app already supports:
  - BLE scan/connect
  - text rendering
  - bitmap rendering
  - notification rendering
  - one voice-feature path named "Even AI"
- The app does not currently implement:
  - a distinct QuickNote flow
  - speech recognition text flowing back into Flutter from native decoded audio

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
5. right-hold QuickNote with minimal accidental taps

## Next Experiments

### Experiment 1 - Tilt With Dashboard Disabled

Goal:

- determine whether disabling dashboard stops only visible UI behavior
- or also stops the underlying `F5` event emission

Why:

- we now know dashboard-on-tilt is a persisted device setting
- the next question is whether tilt remains observable to the app after the UI
  behavior is disabled

Method:

1. disable dashboard-on-tilt in the official app
2. connect the demo app
3. perform controlled tilt up/down actions
4. capture and compare `F5` logs

### Experiment 2 - Right Hold While Connected

Goal:

- identify the event mapping for the QuickNote trigger
- determine whether the event is emitted to the app at all
- or whether the behavior is handled entirely in firmware

Why:

- right hold clearly does something meaningful on-device
- the demo app currently does not turn that into a usable feature path

Method:

1. connect the demo app
2. perform a single clean right-hold
3. repeat 3 times
4. compare logs for repeatable deltas

### Experiment 3 - Right Hold Vs Left Hold Comparison

Goal:

- confirm whether left hold and right hold share a protocol path or diverge
- validate the separation between the app's Even AI flow and firmware-native
  QuickNote behavior

Why:

- this is the cleanest way to test whether QuickNote is just an unhandled event
  or a different subsystem

Method:

1. run a clean left-hold sequence
2. run a clean right-hold sequence
3. compare:
   - `F5` events
   - mic-open behavior
   - audio streaming presence
   - feature-visible behavior on the glasses
