# Python SDK Comparison Notes

This note summarizes the comparison between:

- [EvenDemoApp](..)
- `eveng1_python_sdk`

Both appear to target the same Even G1 hardware family and broadly the same
BLE/UART protocol, but they should not be treated as equally authoritative on
every event meaning.

The Python SDK is useful as:

- a structural reference
- a protocol clue source
- a state-model example

It is not a substitute for live testing against the current firmware.

## Document role

This file is a comparison/reference document.

Use alongside:
- [even-g1-event-mapping.md](even-g1-event-mapping.md) for current trusted mappings
- [protocol-reference.md](protocol-reference.md) for raw vendor/demo protocol notes
- [investigation-notes.md](investigation-notes.md) for broader exploratory findings

## Overall Conclusion

The Python SDK helps confirm some higher-level protocol concepts:

- `0xF5` as the main state/interaction event family
- `0x25` as heartbeat
- dual-leg BLE connection patterns
- the existence of silent-mode and dashboard-related interaction concepts

However, some of its event labels appear interpretive or stale relative to the
current firmware behavior observed during live Flutter testing.

Most importantly:

- the Flutter investigation is currently ahead of the Python SDK on the
  right-hold / QuickNote path
- specifically, the repeated `R21` packet family observed on right-hold release
  is not meaningfully modeled in the Python SDK

## Python Mappings That Align With Live Testing

These Python mappings line up well enough with our current real-device evidence.

### `F5 00`

- Python SDK meaning:
  - double tap
- Live testing:
  - confirmed close active feature / return home
- Assessment:
  - aligned

### `F5 02` / `F5 03`

- Python SDK meaning:
  - dashboard open/close start
- Live testing:
  - `F5 02` = tilt up / heads-up trigger
  - `F5 03` = return to center / heads-down-from-raised-state
- Assessment:
  - broadly aligned at a product level
  - our live naming is more precise than the Python SDK wording

### `F5 04` / `F5 05`

- Python SDK meaning:
  - silent mode on / off
- Live testing:
  - triple tap produces new `F5 04` / `F5 05` events
  - firmware behavior suggests triple tap toggles silent mode
- Assessment:
  - likely aligned
  - still not fully confirmed end-to-end

### Heartbeat `0x25`

- Python SDK:
  - explicit heartbeat family with monitoring
- Flutter app:
  - confirmed heartbeat send/ack traffic in real logs
- Assessment:
  - aligned

### General `0xF5` state categorization

- Python SDK:
  - treats `0xF5` as the main interaction/state family
- Flutter app:
  - all major gesture/state investigation has centered on `0xF5`
- Assessment:
  - aligned

## Python Mappings That Remain Unconfirmed

These are plausible, but we do not yet have enough live evidence to treat them
as protocol truth.

### Dashboard confirmation events `F5 1E` / `F5 1F`

- Python SDK:
  - labels these as open/close dashboard confirmed
- Live testing:
  - not observed in our current runs
- Assessment:
  - unconfirmed

### Physical-state mappings in the Python SDK

- Python SDK:
  - maps several `F5` values to wearing/cradle/charging style physical states
- Live testing:
  - some of those codes overlap with behavior we still consider ambiguous
- Assessment:
  - useful as hypotheses, not yet confirmed

### Dashboard packet family `0x22`

- Python SDK:
  - explicitly watches for dashboard-category packets
- Live testing:
  - we have not yet built a strong Flutter-side picture of `0x22`
- Assessment:
  - very worth watching, but currently unconfirmed from our investigation

## Python Mappings We Currently Reject Or Treat As Speculative

These are the places where our live investigation suggests the Python SDK is
not reliable enough to copy directly.

### `F5 01` as single-tap paging

- Python SDK meaning:
  - single tap
- Flutter app code:
  - currently routes `F5 01` as paging/navigation
- Live testing:
  - repeated single left/right tap tests in dashboard mode and generic text
    mode did not surface app-visible `F5 01`
- Assessment:
  - treat as speculative for current firmware and current tested modes
  - do not assume single taps are app-visible

### Generic interpretation of all interaction events as app-consumable

- Python SDK implication:
  - many interaction events can be tracked uniformly from `0xF5`
- Live testing:
  - some important behaviors appear firmware-local and are not forwarded in a
    usable way to the app
- Assessment:
  - too optimistic as a universal model

### QuickNote modeled as just another `F5` interaction

- Python SDK:
  - does not appear to provide a meaningful dedicated QuickNote packet model
- Live testing:
  - right-hold QuickNote is best explained by a release-time `R21` packet family
    plus optional `F5 18`-style end-state signaling
- Assessment:
  - Python SDK is incomplete here

## Where The Flutter Investigation Is Ahead

This is the most important difference between the two references.

### Right-hold / QuickNote

The Flutter investigation has established the strongest current model for the
QuickNote path:

- right-hold should be treated as firmware-native QuickNote behavior
- the strongest repeatable app-visible signal is `R21` on the right leg
- it appears consistently after right-hold release
- it appears in both spoken-note and silence runs
- it likely represents metadata/history/record summaries rather than transcript
  text
- `F5 18` may accompany release, but is not enough by itself to model QuickNote

The Python SDK does not appear to model this `R21` family in a meaningful way.

That means:

- our Flutter-side live investigation is currently ahead of the Python SDK on
  this part of the protocol

## Architectural Ideas Worth Borrowing Later

Even where the Python SDK is not fully correct on event meaning, it still has
some useful architecture patterns.

### 1. Central state manager

Worth borrowing conceptually:

- a dedicated state layer for:
  - connection state
  - physical state
  - last interaction
  - device state
  - heartbeat timing
  - silent mode

Why:

- the Flutter app currently mixes raw event handling and feature behavior too
  closely inside `BleManager`

### 2. Raw event routing by packet family

Worth borrowing conceptually:

- route raw packet families separately:
  - `0xF5`
  - `0x21`
  - `0x22`
  - `0x25`
  - others

Why:

- this would keep diagnostics and feature handling cleaner
- especially useful for `R21` and any future dashboard packet work

### 3. Reconnect and connection verification

Worth borrowing conceptually:

- bounded reconnect attempts
- reconnect delay
- per-side disconnect handling
- post-connect verification via heartbeat or service readiness

Why:

- the Python SDK is clearly more mature than the Flutter demo app here

### 4. Status/dashboard diagnostics

Worth borrowing conceptually:

- richer status visibility:
  - last interaction
  - physical state
  - silent mode
  - connection quality
  - last heartbeat

Why:

- this would make the Flutter app a better hardware test harness

## What Not To Borrow Blindly

- do not copy Python event labels directly into Flutter without live validation
- do not assume `F5 01` is a reliable single-tap signal
- do not assume all dashboard behavior is driven by app-visible packets
- do not assume QuickNote is covered by the Python SDK's current abstractions

## Best Use Of The Python SDK Going Forward

Use it as:

- a reference for packet families
- a source of architectural ideas
- a comparison point for reconnect/state-handling improvements

Do not use it as:

- definitive truth for current firmware event meanings
- proof that unobserved events must exist in the Flutter app

## Practical Summary

The Python SDK is most helpful for:

- reconnect strategy ideas
- centralized state tracking
- packet-category separation
- silent-mode and dashboard concept hints

The Flutter investigation is stronger for:

- current-firmware gesture interpretation
- tilt-driven dashboard behavior
- `F5 00` close behavior
- the `R21` QuickNote path
