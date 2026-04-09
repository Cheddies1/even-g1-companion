# Investigation Notes

This file keeps the broader exploratory findings, firmware/app model, hypotheses, and test-driven understanding that sit outside the current architecture and current user-visible behavior.

It is intentionally not the same thing as:
- [current-architecture.md](current-architecture.md)
- [current-behaviour.md](current-behaviour.md)
- [protocol-reference.md](protocol-reference.md)

## System model

The current evidence supports a three-layer model:

1. firmware-native behavior
2. persisted device configuration
3. app-driven BLE behavior

### Firmware-native behavior

The glasses are not behaving like a dumb peripheral.

Current evidence suggests firmware owns at least:
- input handling
- tilt detection
- some touch semantics
- some feature entry points
- some on-device UI behavior

Examples:
- right-hold QuickNote-like behavior works even when disconnected
- left-hold while disconnected shows a firmware Bluetooth-disconnected message
- tilt behavior exists even without the app connected

### Persisted configuration

Some settings appear to be written by the official app and stored on the device.

Strong example:
- “dashboard on tilt” persists on-device
- disabling it in the official app still affects behavior when disconnected
- disabling it suppresses the firmware UI reaction, not the underlying tilt event emission

### App-driven BLE behavior

The app behaves as:
- transport layer
- content provider
- feature override layer in some connected flows

Examples:
- text rendering
- notification rendering
- old demo voice path
- current companion-mode overlays

## Important findings

### Tilt / dashboard

Current best model:
- `F5 02` = dashboard-open / tilt-up start
- `F5 1E` / `30` = dashboard/state-up follow-on
- `F5 03` = dashboard-close / tilt-down start
- `F5 1F` / `31` = dashboard/state-down follow-on
- `0x22` = dashboard-related packet family

Notes:
- `F5 02` / `F5 03` were observed from the right leg in the clean tilt runs
- that asymmetry may reflect reporting behavior rather than a truly right-only capability

### Single taps

Despite older vendor/demo notes and some code paths, single left/right taps are not reliable app-visible input in the tested flows.

Current best explanation:
- some tap semantics are handled locally in firmware
- the app should not rely on them for core product behavior

### QuickNote

Current best model:
- right-hold QuickNote is firmware-native
- strongest app-visible signal is `R21` on release
- `R21` likely contains metadata/history/session summary rather than transcript text
- `F5 18` may accompany release, but is not enough to model QuickNote on its own

This remains an investigative area, not a finished app feature.

## Python SDK role

The sibling Python SDK is useful as:
- clue source
- comparison reference
- structural inspiration

It is not a source of truth.

Areas where it aligns well:
- dashboard-related `F5 02 / 03 / 1E / 1F`
- `0x25` heartbeat concept

Areas where caution is still required:
- single-tap assumptions
- many battery/state labels
- lack of meaningful `R21` QuickNote modeling

## Legacy demo code interpretation

The old vendor/demo app and README are useful reference material, but they often mix:
- raw command structure
- vendor claims
- product assumptions

That material should be preserved as reference, but not treated as automatically true for current firmware.

## What remains unknown

Still not mapped confidently:
- some background/state `F5` values such as `06`, `07`, `08`, `11`, `12`, `14`, `15`, `32`
- detailed meaning of `0x22` payload fields
- whether any stable battery percentage/status API exists
- exact firmware stop semantics for mic/capture in the current app path

## Why this file exists

This file is the place for:
- firmware/app mental model
- experimental findings
- uncertainty
- things worth testing next

It should remain more flexible and hypothesis-friendly than the current-behaviour or architecture docs.
