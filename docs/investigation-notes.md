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

Despite older vendor/demo notes and some code paths, single left/right taps
are not reliable app-visible input in the tested flows.

Current best explanation:
- single taps are handled locally in firmware in every observed state
- the app should not rely on them for core product behavior

The 2026-04-28 taps capture pushed this from "best explanation" to a strong
negative result. Single taps were tested with:
- idle / no display content (left and right, three each)
- dashboard up with notes list visible (right taps cycling notes)
- dashboard up with notifications list visible (left taps cycling)

In every case the firmware visibly responded on the glasses (notes /
notifications cycled) but no BLE event fired. See
[FINDINGS-taps.md](FINDINGS-taps.md).

### Double taps (newly identified path)

Double-tap as a host-side input has historically been impossible because the
firmware only fired `F5 00` on double-tap-to-close-active. The 2026-04-28
capture identified `F5 20` as a "feature opened via double-tap" event — fired
when a double-tap triggers the configured action in the official Even
Realities app.

Follow-up live testing pinned down the semantics: `F5 20` is the
**generic "double-tap delegates to host" event**. It fires whenever the
configured double-tap action is a host-handled feature (mic / network /
text rendering required). It does not fire for firmware-native actions or
for "None":

| official-app double-tap action | `F5 20` fires? | reason                  |
|--------------------------------|----------------|-------------------------|
| Transcribe                     | yes            | host-handled            |
| Translate                      | yes            | host-handled            |
| Teleprompter                   | yes            | host-handled            |
| Dashboard                      | no             | firmware-native         |
| None / Close active feature    | no             | only `F5 00`, when applicable |

The companion app routes `F5 20` to
`CompanionController.handleDoubleTapModeSwitch` for a passive mode cycle.
This works as long as the user keeps the official-app double-tap action set
to one of the host-handled features. The on-glasses overlay for the
configured action still appears briefly when the cycle fires.

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
- some battery/state labels (the Python SDK's `0x09` "Glasses fully charged"
  and `0x0f` "Cradle fully charged" labels are stale: in current firmware
  byte 2 carries an actual percentage rather than a binary "charged" flag)
- lack of meaningful `R21` QuickNote modeling

## Legacy demo code interpretation

The old vendor/demo app and README are useful reference material, but they often mix:
- raw command structure
- vendor claims
- product assumptions

That material should be preserved as reference, but not treated as automatically true for current firmware.

## What remains unknown

Still not mapped confidently:
- some background/state `F5` values such as `11`, `14`, `15`, `32` (the latter
  is hex `0x32`, distinct from the newly-mapped `F5 20` which is hex `0x20`)
- detailed meaning of `0x22` payload fields
- exact firmware stop semantics for mic/capture in the current app path
- the `0x06` family used for note management (delete / reorder) needs a
  matching list-all opcode before it could drive any in-app note management
- decoding of the `0x1e` post-release quicknote stream — structure is clear,
  codec almost certainly LC3 but not yet confirmed end-to-end
- the third (and possibly fourth) head-up category byte (`0x08 06 00 00 04
  ...` was seen in baseline traces but the corresponding setting hasn't been
  identified)

Recently resolved:
- battery percentage and wear state are now mapped — see the "Battery and wear
  state" sections in [even-g1-event-mapping.md](even-g1-event-mapping.md) and
  [protocol-reference.md](protocol-reference.md). The full write-up lives in
  [FINDINGS-battery+brightness.md](FINDINGS-battery+brightness.md).
- `F5 06`, `F5 07`, `F5 08`, `F5 0A`, `F5 0B`, `F5 0F`, `F5 12` are no longer
  unknown: wear state, transitioning, cradle states, glasses %, case %, and
  brightness echo respectively.
- `F5 18` left long-press release is now Confirmed (paired with `F5 17`
  press-down).
- `F5 20` newly identified — generic "double-tap delegates to host" event.
  Fires for any host-handled configured double-tap action (Transcribe,
  Translate, Teleprompter all confirmed); does not fire for firmware-native
  actions (Dashboard) or None. Used in the companion app as a mode-cycle
  trigger.
- `F5 04` / `F5 05` triple-tap silent-mode toggle is now Confirmed.
- single taps are confirmed firmware-only (negative result, robust enough to
  stop investing in this path).
- **Settings opcodes**: `0x08` (head-up family) and `0x26` (touch family)
  decoded from the 2026-04-28 settings capture. Both follow the same shape
  as the brightness command. Now wired into the app's Settings page so the
  user can persist tilt-up and double-tap behaviours from the companion
  rather than the official app.
- **Quicknote post-release stream**: every `0x21` release is followed by a
  chunked binary burst on opcode `0x1e c8 ...` whose volume scales with
  recording duration. Strongly consistent with encoded audio — the BLE path
  the user wants for "DIY quicknotes" / hosted transcription. Documented;
  decoding is left as future work.
- **Note management family**: `0x06 ... / 0x22 ack` three-step transaction
  used by the official app for delete / reorder. The 8-byte note UID it
  carries is the same shape as the trailing block in `R21` payloads.

## Why this file exists

This file is the place for:
- firmware/app mental model
- experimental findings
- uncertainty
- things worth testing next

It should remain more flexible and hypothesis-friendly than the current-behaviour or architecture docs.
