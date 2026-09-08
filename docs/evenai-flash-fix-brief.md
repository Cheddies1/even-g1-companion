# Brief: eliminate the "Even AI is listening" flash on screen clear

> **Document type:** Implementation brief (for Codex or equivalent)
> **Audience:** Implementing agent
> **Status:** Ready to start. Phase 0 is instrumentation — do not skip it.
> **Evidence basis:** [FINDINGS-evenai-flash-on-clear.md](FINDINGS-evenai-flash-on-clear.md), derived from the G1 firmware decompilation. No device confirmation yet.

## Goal

Stop the firmware's "Even AI is listening" screen from flashing during our
display clear, and replace the `0x50 + 0x18` clear — whose documented mechanism
is wrong — with one built on how the firmware actually behaves.

Done looks like: 20 consecutive clears from each of Glance, Chat and Navigate
with zero observed flashes, and a log line per clear recording the firmware
screen state we cleared from.

## Context

### What exists

`Proto.clearDisplay()` in `lib/services/proto.dart` sends
`0x50 06 00 00 01 01` then `0x18`, both via `BleManager.sendData` (broadcast,
no ack checking). `Proto.exit()` sends bare `0x18` per leg via
`BleManager.request` and treats `data[1] == 0xc9` as success.
`Proto.showTitleCard()` calls `clearDisplay()` after a delay.

`clearDisplay()` is suppressed while `_quickNoteCaptureActive` is set, to avoid
killing an in-flight QuickNote audio stream. **Preserve that guard exactly.**

### What the firmware actually does

Read [FINDINGS-evenai-flash-on-clear.md](FINDINGS-evenai-flash-on-clear.md)
first. The four load-bearing facts:

1. Screen id `0x10` is the Even AI screen (`ui_task_handler.c` → `ui_even_ai_task`).
2. Our `0x4E` sends with `screenStatus = 0x71` can park `0x10` in the
   firmware's pending-screen slot, depending on a firmware state byte we do not
   observe. Sends with `screenStatus` upper nibble `0x40` park `8` instead.
3. `0x18`'s teardown is asynchronous — it raises a redraw flag per surface
   while the state it redraws from is still being mutated, guarded by a
   non-atomic mutex the clear path waits on but never takes.
4. `0x50` is a **master-only dashboard lock**, not display-mode control. It does
   not clear anything and the left lens rejects it outright.

Consequences that change the code:

- The `0x18` ack (`0xC9`) is emitted **before** any teardown work, so
  `Proto.exit()`'s success return is not evidence the screen cleared. Do not
  add new logic that trusts it.
- `0x18` does nothing at all when the firmware screen id is `0` or `1` — the
  exit guard returns `screen_id > 1`.
- Opcode `0x39` is a per-lens readback returning the current screen id
  (`0x00` when idle, `0xFF` on a length mismatch). It is answered locally, not
  relayed, so it reports the lens you asked. See
  [firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) § 3.

### What has been tried before

The `0x50 + 0x18` combo is recorded in `worklist-history.md` (2026-05-09) as
the ghost-screen fix, on the theory that `0x50` "closes the active mode so
`0x18` exits cleanly". That mechanism does not exist. The combo most likely
helped only by adding wire delay before `0x18`. Treat the existing sequence as
an accident of timing, not a design to preserve.

## Constraints

- **Do not remove the `_quickNoteCaptureActive` suppression** in
  `clearDisplay()`. It prevents killing a live QuickNote audio stream.
- **Do not change the `0x4E` header builder's default `screenStatus`.** `0x71`
  is correct for normal text sends. Only the *terminal* pre-clear send changes.
- Keep `Proto.exit()`'s existing signature and per-leg request behaviour.
  Other call sites depend on it.
- No new packages. No changes to `BleManager.kt` or any native code.
- All new logging via `AppLog` with `tag: 'GlanceClear'`; per-clear detail at
  `AppLog.debug`, state transitions and anomalies at `AppLog.info`.
- Do not touch the `0x0a` nav or `0x52` streaming lifecycles in this work. The
  `0x50`-before-INIT question is a separate worklist item
  (`nav-0x50-necessity`) and Navigate is mid-cleanup.
- Broadcast writes stay broadcast. Do not convert `clearDisplay` to per-leg
  requests as a side effect.

## Expected behaviour

### Phase 0 — instrument (do this first, ship it, gather data)

Add `Proto.readScreenState(String lr)`:

- TX `0x39` with a correct 4-byte length-prefixed header. The firmware
  validates bytes 1–2 as a little-endian total length and returns `0xFF` in the
  status byte on mismatch — if you get `0xFF`, the header is wrong, fix it
  before interpreting anything else.
- Response is 6 bytes; the status byte is the screen id, `0x00` when idle.
- Return a nullable int; `null` on timeout or `0xFF`.

Then, in `clearDisplay()`, read both legs' screen state *before* clearing and
log it:

```
clearDisplay: pre-clear screen state L=0x?? R=0x??
```

Do not branch on it yet. Ship this, run it, and confirm from logs whether
flashes correlate with `0x10`. **The findings doc is a source read, not a
device result — this phase is what makes it a device result.**

### Phase 1 — terminal `0x40` send

Add an optional terminal text send that uses `screenStatus` upper nibble `0x40`
("Even AI display complete") instead of `0x70`, then call it from
`clearDisplay()` before the `0x18`.

- Reuse the existing `0x4E` builder; parameterise `screenStatus` rather than
  duplicating the builder.
- The payload should be the empty string or a single space — whatever the
  existing builder accepts without a zero-length body.
- Exact byte: `0x41` (upper `0x40` + lower `0x01` "display new content"),
  matching the existing `0x71` convention.

### Phase 2 — skip the no-op clear

If Phase 0 logs confirm the screen id is readable, skip the `0x18` when both
legs report `0` or `1`, since the firmware guard makes it a no-op. Log the skip.

Keep a `forceClear` escape hatch parameter defaulting to `false` for callers
that want the write regardless.

### Phase 3 — `0x50` decision

Replace the `0x50` in `clearDisplay()` with an explicit, named, tunable delay
(`_preExitDelay`, start at 50 ms) and remove the `0x50` write from the clear
path only.

If the flash returns when `0x50` is removed, that confirms it was buying delay,
and the explicit delay is the honest version. Record the result either way.
Do **not** remove `0x50` from the nav or streaming lifecycles.

## Acceptance criteria

- [ ] `Proto.readScreenState(lr)` returns a screen id for each leg on device, and does **not** return `0xFF` (which would mean a malformed header).
- [ ] Every `clearDisplay()` logs pre-clear screen state for both legs.
- [ ] Device data recorded in `FINDINGS-evenai-flash-on-clear.md`: does a flash correlate with a pre-clear screen id of `0x10`? Answer it explicitly, including if the answer is no.
- [ ] Terminal `0x40` send implemented and reachable from `clearDisplay()`.
- [ ] 20 consecutive clears from each of Glance, Chat and Navigate with zero observed flashes. Record the count and the modes tested; if any mode still flashes, say which.
- [ ] `_quickNoteCaptureActive` suppression still works — verify by clearing during a live QuickNote capture and confirming the audio still saves.
- [ ] Navigate and Chat both still function end to end (`0x50` untouched in their lifecycles).
- [ ] `flutter analyze` clean; existing tests pass.
- [ ] Findings doc updated with what device testing confirmed, corrected or killed. **If the mechanism turns out to be wrong, say so in the doc** rather than leaving the source-read hypothesis standing.

## Explicit non-goals

- Enumerating the full firmware screen-id list beyond what §"Screen id → task map" already has.
- Fixing the `0x50` requirement in the nav or streaming lifecycles.
- Any change to how normal text sends set `screenStatus`.
- Chasing the `field_0x1010` state byte through the decompilation. If Phase 0 shows no correlation with `0x10`, stop and report rather than going deeper into the source.

## If it does not reproduce

The flash is intermittent and may not appear in a test session. If 20 clears
per mode produce no flash *and* no `0x10` pre-clear readings, do not declare
victory — report that the mechanism is unconfirmed, leave Phase 0
instrumentation in place, and note that the sample was too small. A silent
"seems fine now" is the failure mode to avoid here, because that is exactly how
this bug survived the last fix.
