# Even Demo App Investigation Notes

This note captures the broader understanding of the app gained during the
initial build fixes, BLE investigation, and device testing.

It is intended as a practical working summary, not a polished architecture
document.

## Updated System Model

The glasses are not behaving like a dumb peripheral.

The current evidence supports a three-layer model:

1. firmware-native behavior
2. persisted device configuration
3. app-driven BLE behavior

### Firmware-native behavior

The glasses appear to contain their own:

- input handling
- touchbar semantics
- tilt detection
- some feature logic

Examples:

- right-hold appears to activate QuickNote-like behavior even when disconnected
- left-hold when disconnected shows a firmware-level Bluetooth disconnected
  message
- tilt detection exists whether or not the demo app is connected

### Persisted device configuration

Some settings appear to be written by the official Even app and then stored on
the glasses.

Strong example:

- "dashboard on tilt" appears to persist on-device
- disabling it in the official app continues to affect behavior when the phone
  is no longer connected
- disabling it suppresses the visible firmware UI reaction, not the underlying
  tilt event emission seen by the connected app

### App-driven BLE behavior

The demo app is best understood as:

- a transport layer
- a content provider
- optionally a feature override layer when the firmware routes a connected event
  into the app

Examples:

- text, bitmap, and notification rendering
- the app's current Even AI path
- connection/session management over BLE

## Build And Environment Notes

The project was made to build and run on Windows with Flutter 3.41.x and
Java 17 using a minimal compatibility pass.

### Build fixes already applied

- [android/gradle.properties](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/gradle.properties)
  - removed `-XX:MaxPermSize=512m`
  - reason: Java 17 rejects that JVM option
- [android/settings.gradle](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/settings.gradle)
  - Android Gradle Plugin updated from `8.1.0` to `8.1.1`
  - reason: Flutter required at least `8.1.1`
- [pubspec.yaml](/c:/Users/EddieJohnson/projects/EvenDemoApp/pubspec.yaml)
  - `fluttertoast` updated to `^8.2.14`
  - reason: older version referenced removed Flutter Android APIs and broke the
    build

### Current build status

- The app now builds, installs, launches, and talks to the glasses.
- AGP and Kotlin warnings still appear, but they are warnings rather than the
  active blocker.

## What The App Can Already Do

Confirmed working during testing:

- scan for Even G1 glasses
- detect left/right device pairs
- connect to both legs over BLE
- show connection state in the Flutter UI
- send text to the glasses
- send notifications to the glasses
- send bitmap content to the glasses
- receive touch and other `F5` notifications from the glasses
- receive mic audio packets from the glasses during the implemented voice flow
- open a minimal custom Flutter dashboard from tilt-up and close it with
  double-tap

## What The App Cannot Yet Reliably Do

- it does not expose a full, explicit BLE lifecycle beyond scan/connect from the
  demo UI
- it does not implement a complete reconnect strategy
- it does not implement a separate QuickNote feature path
- it does not currently push recognized speech text back into Flutter
- it does not appear to close GATT cleanly from the existing
  `disconnectFromGlasses` stub
- it does not currently support app-visible single-tap navigation for dashboard
  or generic text flows
- it does not currently support manual touch-based paging for `TextService`

## Key Behavior Findings

- tilt detection is firmware-side
- dashboard-on-tilt is a persisted on-device setting
- disabling dashboard-on-tilt suppresses the firmware UI reaction, not the
  underlying tilt event emission
- `F5 02` is now high-confidence tilt up / head-up trigger
- `F5 03` is now high-confidence return-to-center after raised tilt
- newer isolated dashboard runs suggest a stronger firmware-dashboard model:
  - `F5 02` = dashboard open / tilt-up start
  - `F5 30` = dashboard open confirmed / state-up
  - `F5 03` = dashboard close / tilt-down start
  - `F5 31` = dashboard close confirmed / state-down
- raw `0x22` is now confirmed as a dashboard-related packet family
  - currently observed on the right leg only
  - current repeated payload is `22 0a 00 00 01 00 00 01 04 00`
  - payload semantics remain unknown
- left hold behaves as a firmware entry point into a connected feature:
  - disconnected -> shows Bluetooth disconnected
  - connected -> enters the app voice path
- right hold appears firmware-native and QuickNote-related
- right hold should now be treated as a firmware-native QuickNote flow
- the strongest app-visible QuickNote signal currently appears on release as
  command `0x21` on the right leg
- double-left-tap closes the active feature and returns home
- single left/right taps are not reaching the app in the tested dashboard and
  generic text flows
- triple tap likely forwards a separate event family and appears related to
  silent mode
- current tilt logs show `F5 02` and `F5 03` on the right leg only
- that asymmetry may reflect firmware reporting behavior, not a genuinely
  right-only physical capability

## High-Level Architecture

### Flutter side

- [lib/views/home_page.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/views/home_page.dart)
  - home screen / demo harness UI
  - now exposes explicit scan/reconnect and hello-text actions
- [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart)
  - main Flutter BLE wrapper
  - owns connection status, discovered pair list, and incoming event handling
- [lib/services/proto.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/proto.dart)
  - protocol-level send helpers
- [lib/services/evenai.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/evenai.dart)
  - app's only implemented voice-feature flow
- [lib/services/text_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/text_service.dart)
  - text rendering path
- [lib/controllers/bmp_update_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/controllers/bmp_update_manager.dart)
  - bitmap transfer/chunking logic

### Native Android side

- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
  - BLE scanning
  - pairing left/right devices by channel number
  - GATT connection and notification setup
  - BLE characteristic receive handling
  - LC3 audio decode entry point
- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)
  - Flutter method/event channel bridge
- [android/app/src/main/kotlin/com/example/demo_ai_even/model/BleDevice.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/model/BleDevice.kt)
  - per-leg write handling
- [android/app/src/main/kotlin/com/example/demo_ai_even/model/BlePairDevice.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/model/BlePairDevice.kt)
  - left/right session container
- [android/app/src/main/cpp/liblc3.cpp](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/cpp/liblc3.cpp)
  - native LC3 decode support

## Connection Flow

The current connection flow is simple and mostly scan-based.

1. Flutter requests a scan from [lib/ble_manager.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/ble_manager.dart).
2. Native scan logic in
   [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
   filters G1-style names and groups left/right devices by channel number.
3. Native reports a paired result back to Flutter as `foundPairedGlasses`.
4. Flutter shows the discovered pair list.
5. User selects a pair to connect.
6. Native opens two GATT sessions, one for each leg.
7. After service discovery:
   - notifications are enabled
   - MTU 251 is requested
   - bonding is requested
   - left/right ready flags are updated
8. Once both legs are ready, native reports `glassesConnected` back to Flutter.
9. Flutter marks the session connected and starts a periodic heartbeat.

## What Explains The "Already Connected" Feeling

During testing, the app could often use glasses that had previously been used by
the official Even app.

The most likely explanation is:

- the official app had already bonded or initialized the glasses
- after it closed, the glasses remained available to scan/connect
- this demo app then made its own BLE connections using the scanned addresses

Important detail:

- this demo app does not appear to restore devices from the bonded-device list on
  startup
- instead, it still relies on scanning and then connecting

## Reconnect Status

Reconnect support is currently minimal.

- there is no real auto-reconnect loop
- there is no restore-session path from bonded devices
- `disconnectFromGlasses` is effectively a stub in
  [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleManager.kt)
- the current practical reconnect flow is:
  - scan again
  - rediscover pair
  - reconnect manually

## UI Improvements Already Made

The home screen was lightly improved to make it usable as a BLE test harness.

Changes already made in
[lib/views/home_page.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/views/home_page.dart):

- explicit connection state display
- visible `Scan / Reconnect` button
- discovered pair list kept visible while disconnected/scanning
- visible `Send Hello Text` button when connected

These changes were intentionally UI-only and did not modify BLE or protocol
behavior.

## Minimal Dashboard Slice

A minimal custom dashboard flow has now been proven in Flutter and has since
been upgraded to use real Android notifications.

Behavior currently implemented:

- tilt up (`F5 02`) -> open dashboard and render time plus newest notification
- repeated tilt up (`F5 02`) -> advance through the recent notification feed
- return to center (`F5 03`) -> start the inactivity countdown
- double tap (`F5 00`) -> close dashboard
- inactivity timeout (~8 seconds, started on tilt-down) -> auto-close and clear
  the active screen

Firmware-side diagnostic note:

- when the official firmware dashboard is enabled and the custom dashboard
  renderer is disabled, the logs now show a repeated firmware sequence:
  - `F5 02` -> up/start
  - `F5 30` -> up confirmed/state-up
  - `0x22` -> dashboard packet family
  - `F5 03` -> down/start
  - `F5 31` -> down confirmed/state-down

Current limitation:

- single left/right taps did not produce app-visible events during testing, so
  notification paging could not yet be driven from touch input
- this suggests official-app tap navigation may rely on firmware-local handling
  or a different feature/protocol mode

Implementation note:

- see [docs/dashboard-feature-notes.md](/c:/Users/EddieJohnson/projects/EvenDemoApp/docs/dashboard-feature-notes.md)
  for the current product-slice behavior and Android notification ingestion
  details

## Voice / Speech Findings

The app has one implemented voice-oriented feature path and it is entirely framed
as "Even AI".

### What is implemented

- start voice flow from an `F5` event
- open the glasses mic using `Proto.micOn(...)`
- receive `VoiceChunk` packets from native BLE
- decode LC3 audio to PCM on Android
- stop voice flow and attempt to process recognized text
- render fallback text or reply text to the glasses

### What is missing

- there is no separate QuickNote feature path in the codebase
- native decoded PCM is not currently fed into a speech recognition pipeline
- recognized text is not being sent back into Flutter's
  `eventSpeechRecognize` channel even though the channel exists

### Practical result

- left-hold triggers the app's implemented voice path
- right-hold appears to be a firmware-native QuickNote path, but this demo app
  does not currently implement it
- repeated right-hold runs show `R21` after release as the most meaningful
  app-visible QuickNote packet
- `F5 18` may accompany release as a stop/end-state signal, but is not enough on
  its own to model the QuickNote flow
- when no recognition text arrives, the app falls back to:
  - `No Speech Recognized`

### Opportunity area

Right-hold QuickNote is a key opportunity area because it appears to exist on
the glasses already, but the current demo app does not yet expose or extend it
in a useful way.

### What `R21` probably is not

- `R21` is unlikely to be raw recognized speech transcript text
- both spoken-note and silence runs still produced `R21`
- the repeated fixed-length packet shape suggests metadata/history or note
  summary records instead

## Gesture And State Event Investigation

The current working `F5` event map is tracked separately in:

- [docs/even-g1-event-mapping.md](/c:/Users/EddieJohnson/projects/EvenDemoApp/docs/even-g1-event-mapping.md)

That file should be treated as the current event-focused companion to this
broader app note.

## Diagnostic Logging Added

To support isolated test runs, diagnostic-only logging was added earlier for:

- scan requested
- pair discovered
- connect requested
- left connected / right connected readiness
- both connected
- disconnect notifications
- `F5` event labeling in the Flutter receive path

These additions were intended only to improve visibility and were not meant to
change transport behavior.

## Core Plumbing Vs Demo UI

### Core plumbing

- Flutter BLE wrapper and protocol send path
- native BLE scan/GATT setup
- left/right session model
- text/bitmap/notification send logic
- voice-flow plumbing and mic packet handling

### Demo UI

- home screen
- feature list screen
- text/bitmap/notification demo pages
- Even AI list/history screens

## Current Best Understanding

The app is best understood as:

- a demo/test app for Even G1 BLE transport and rendering
- with one partially implemented voice path called Even AI
- layered on top of smarter glasses firmware that already owns some behaviors
- without a full production-ready connection lifecycle
- and without a complete implementation of all glasses firmware interaction modes

In practical product terms, the currently proven entry points into connected
app-driven behavior are:

- tilt up
- long hold left
- explicit launch from the phone UI

Double tap acts as a close/home control when a feature is active.

## Next Experiments

### Experiment 1 - Tilt With Dashboard Disabled

Goal:

- determine if disabling dashboard stops only the visible UI behavior
- or also stops the underlying `F5` emission

Why:

- we now know dashboard-on-tilt is a persisted setting
- this experiment tests whether tilt remains observable to the demo app even
  when the firmware UI behavior is suppressed

Current result:

- confirmed
- tilt events still emit even when the dashboard UI behavior is disabled
- current strongest mapping is:
  - `F5 02` -> tilt up / head-up trigger
  - `F5 03` -> return to center
- in current logs, these were reported from the right leg only

Method:

1. disable dashboard-on-tilt in the official app
2. connect the demo app
3. perform controlled tilt up/down actions
4. capture `F5` logs

### Experiment 2 - Right Hold While Connected

Goal:

- identify the event mapping for the QuickNote trigger
- determine whether it is emitted to the app
- or handled entirely in firmware

Why:

- right hold clearly does something meaningful on-device
- the current demo app does not turn that into a feature flow

Method:

1. run a single clean right-hold while connected
2. repeat 3 times
3. compare the logs

Current result:

- partially answered
- the primary packet family to watch is now `R21` on release rather than `F5`
  start events
- remaining question is what fields inside `R21` represent

### Experiment 3 - Right Hold Vs Left Hold Comparison

Goal:

- confirm whether both holds share any protocol path
- validate the separation between Even AI and QuickNote behavior

Why:

- left hold currently drives the app voice path
- right hold appears to be a different feature path
- comparing them cleanly will tell us whether QuickNote is just unhandled or
  fundamentally separate

Method:

1. run a clean left-hold sequence
2. run a clean right-hold sequence
3. compare:
   - `F5` events
   - mic-open behavior
   - audio streaming
   - visible glasses behavior

## Safe Next Steps

The safest next steps remain incremental:

1. keep documenting confirmed gesture/state mappings
2. avoid changing BLE transport unless there is a clear need
3. clean up diagnostic labels to match confirmed behavior
4. decide later whether to:
   - implement a proper QuickNote path
   - improve reconnect lifecycle
   - wire decoded audio into actual speech recognition
   - decode and classify `R21` QuickNote packets
   - decide which firmware entry points should become real app features
