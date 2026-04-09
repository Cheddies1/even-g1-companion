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

- Meaning: stop voice flow / record over
- Confidence: medium-high
- Evidence:
  - during isolated left-hold testing, `F5 18` is followed by
    `EvenAI.get.recordOverByOS()`

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
  - in Flutter, [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart#L182)
    routes:
  - left -> feature previous
  - right -> feature next
- Notes:
  - repeated device testing did not surface `F5 01` from single left/right taps
    in dashboard mode or generic text rendering mode
  - current best hypothesis is that tap scrolling/navigation in official feature
    modes is often handled locally in firmware and not forwarded to this demo
    app in the tested flows

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
  - observed packet length is repeatedly `42`
  - packet structure appears stable across captures
  - both spoken-note and silence runs still produce `R21`
- Notes:
  - `R21` likely does not contain raw recognized speech transcript text
  - more likely candidates are metadata, identifiers, timestamps, or note record
    summaries
  - a small counter/index-looking field appears to increment across captures

#### `F5 04`

- Meaning: likely triple-tap / silent-mode-related event
- Confidence: low-medium
- Evidence:
  - observed during triple-tap testing
  - user-observed firmware behavior indicates triple tap toggles silent mode

#### `F5 05`

- Meaning: likely companion triple-tap / silent-mode-related event
- Confidence: low-medium
- Evidence:
  - observed during triple-tap testing
  - appears in the same gesture family as `F5 04`

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

- Meaning: secondary tilt/head-up state event
- Confidence: low-medium
- Evidence:
  - appears during idle runs with no deliberate touch input
  - appears more like posture/state than direct button interaction
  - now seems less likely to be the primary tilt trigger itself

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
    in [utils/constants.py](/c:/Users/EddieJohnson/projects/eveng1_python_sdk/utils/constants.py)
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
    in [utils/constants.py](/c:/Users/EddieJohnson/projects/eveng1_python_sdk/utils/constants.py)
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
    [utils/constants.py](/c:/Users/EddieJohnson/projects/eveng1_python_sdk/utils/constants.py)
- Notes:
  - payload meaning is still unknown
  - current logs show this on the right leg only
  - do not infer field semantics yet

## Unknown

These event IDs have been observed but are not yet mapped with enough confidence
to assign a meaning:

- `F5 06`
- `F5 07`
- `F5 08`
- `F5 11`
- `F5 12`
- `F5 14`
- `F5 15`
- `F5 32`

## Current Code Notes

The current Flutter app only actively handles a small subset of `F5` events in
[lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart#L169):

- `0` -> exit/home
- `1` -> page/navigation routing in app code
- `2` -> custom Flutter dashboard open
- `3` -> custom Flutter dashboard starts auto-close countdown on return to center
- `30` -> currently logged as dashboard open confirmed / state-up
- `31` -> currently logged as dashboard close confirmed / state-down
- `23` -> start voice flow
- `24` -> stop voice flow

Important caveat:

- the current diagnostic labels in [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart#L213)
  are still provisional
- they should not be treated as protocol truth
- runtime behavior and isolated logs are more trustworthy than the current label
  names

There is currently no QuickNote-specific implementation in the app codebase.

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
  [lib/services/text_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/text_service.dart)
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
