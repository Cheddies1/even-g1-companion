# "Even AI is listening" flashed during screen clear — root cause from firmware source

> **Document type:** G1 findings
> **Audience:** Anyone working on the display clear path or the `0x4E` text renderer
> **Evidence basis:** Ghidra decompilation of the G1 firmware (`JohnRThomas/even_realities_decomp`, commit `f571782`), read against our own clear implementation. **No device testing yet** — the mechanism is a race and has not been reproduced under instrumentation.

## The symptom

Intermittently, clearing the display flashes the firmware's "Even AI is
listening" screen for roughly one frame before the screen blanks. Not reliably
reproducible. Long-standing, never solved, previously written off as "one of
those things". Also reported by other third-party G1 apps.

Believed absent from the official Even Realities app — see
"[Why the official app probably avoids it](#why-the-official-app-probably-avoids-it)".

## Summary

Four firmware facts combine into a race:

1. **Screen id `0x10` is the Even AI screen.** `ui_task_handler.c` dispatches
   id `0x10` to `ui_even_ai_task`.
2. **Our `0x4E` text sends park `0x10` in a pending-screen slot.** The `0x4E`
   handler branches on the `screenStatus` upper nibble; our value (`0x71`)
   reaches a branch that writes `field20_0xc8[0x13] = 0x10`.
3. **The `0x18` clear path checks screen state without holding the lock that
   protects it.** The guard waits for a non-atomic software mutex to be free,
   reads the screen id, and returns without taking it.
4. **The clear is asynchronous.** Teardown sets a global "refresh needed" flag
   per dirty surface; the display thread renders whenever it next runs.

If the display thread services a refresh while the pending slot still holds
`0x10`, `__ui_task_handler` dispatches `ui_even_ai_task` and the Even AI
surface renders for one frame. Timing-dependent, hence "sometimes".

**And our existing mitigation does not work the way we documented it.** `0x50`
is not display-mode control — it is a master-only dashboard lock that does not
touch the display. The `0x50 + 0x18` combo most likely helped only by adding
wire delay ahead of `0x18`, which shifts the race window. That is consistent
with the bug never fully going away.

## The evidence

### Screen id → task map

From `ui_task_handler.c` — the screen-id dispatch, `switch(param_2)`:

| id | task | | id | task |
|----|------|---|----|------|
| `0` | idle | | `0x0c` | QuickNote |
| `1` | wait_blow_head | | `0x0e` | `ui_onboarding_task` |
| `3` | set by `exit_silent_mode` | | `0x0f` | `ui_raster_height_task` |
| `4` | `ui_ancs_notificaton_task_0` | | **`0x10`** | **`ui_even_ai_task`** |
| `5` | `ui_new_message_come_on_task` | | `0x11` | `ui_set_imu_pitch_task` |
| `6` | `__ui_DashBoard_task` | | `0x12` | `ui_prompt_info_task` |
| `7` | `__ui_bitmap_task` | | `0x13` | `ui_transcribe_info_task` |
| `9` | `ui_teleprompter_task` | | `0x14` | `ui_even_ai_v2_info_task` |
| `0x0a` | `ui_navigation_task` | | | |
| `0x0b` | `ui_translate_task` | | | |

The live screen id is `field20_0xc8[0xd]` (equivalently `ctx + 0xd5`) and is
also what the `0x39` readback returns — see
[firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) § 3.

Writers: `update_persist_task_status`, `update_temp_task_status`,
`update_persist_task_status_to_idle` (→ `0`),
`update_persist_task_status_to_wait_blow_head` (→ `1`), `exit_silent_mode`
(→ `3`), `enter_silent_mode` (→ `0`), `slave_display_thread`.

### `0x4E` writes the Even AI id into the pending slot

`field20_0xc8[0x13]` is a pending / next-screen slot. Both `0x18` exit routines
zero it as their second action, which is what identifies it as pending state
rather than live state.

The `0x4E` handler (`ble_process_req_dispatch.c` case `0x4e`) branches on
`param_3[4] & 0xf0` — the upper nibble of the `screenStatus` byte:

```c
bVar16 = param_3[4] & 0xf0;
pGVar6 = __get_dashboard_state();
if (**(char **)&pGVar6->field_0x1010 == '\x06') {
  if (bVar16 == 0x40) goto LAB_000228ce;
}
else if (bVar16 != 0x30) {
  if (bVar16 == 0x40) {
LAB_000228ce:
    **(undefined1 **)&pGVar6->field_0x1010 = 8;
    pGVar6->field20_0xc8[0x13] = 8;          /* pending = 8 */
  }
  else {
    if (6 < **(byte **)&pGVar6->field_0x1010) {
      if ((param_3[4] & 0xf0) == 0x40) goto LAB_000228ce;
      if ((param_3[4] & 0xf0) == 0x50) { uVar10 = 9; ... }
    }
  }
  goto LAB_00022826;                          /* pending untouched */
}
/* reached when (state==6 && upper != 0x40) or (state != 6 && upper == 0x30) */
**(undefined1 **)&pGVar6->field_0x1010 = 7;
uVar10 = 0x10;
...
pGVar6->field20_0xc8[0x13] = uVar10;          /* pending = 0x10 — EVEN AI */
```

The branch is built around the demo-era Even AI status values documented in
[protocol-reference.md](protocol-reference.md): `0x30` displaying, `0x40`
display complete, `0x50` manual mode, `0x60` network error, `0x70` text show.

**We send `screenStatus = 0x71`**, i.e. upper nibble `0x70`, which is none of
the Even AI values. Tracing it:

- **text-surface state == 6** → the inner `if (bVar16 == 0x40)` fails, control
  falls past the `else if`, and we land on the fallthrough → **pending =
  `0x10`, Even AI**
- **text-surface state != 6** → `bVar16 != 0x30` is true → not `0x40`, not
  `0x50` → `goto LAB_00022826`, pending untouched

So whether a text send parks Even AI in the pending slot depends on a firmware
state byte (`field_0x1010` offset 0) that we neither set nor observe. That is
the "sometimes".

`Firmware-source`, and the control-flow read is the part most exposed to Ghidra
misnesting — treat the exact condition as needing device confirmation, and the
existence of the `pending = 0x10` branch as solid.

### The clear path checks screen state without holding it

Both `0x18` exit routines begin with the same guard:

```c
bool FUN_0002da10(int param_1)
{
  while (DAT_20019a6a != '\0') { sleep_33_seconds(); }
  return 1 < *(byte *)(param_1 + 0xd5);        /* screen_id > 1 */
}
```

`DAT_20019a6a` is a **hand-rolled, non-atomic mutex** around screen-state
transitions. `update_temp_task_status`, `update_persist_task_status` and
`update_persist_task_status_to_idle` all follow the same pattern:

```c
while (DAT_20019a6a != '\0') { sleep_33_seconds(); }
DAT_20019a6a = 1;
...
DAT_20019a6a = 0;
```

Test-and-set with a gap between the test and the set — two threads can both
pass the check.

The exit guard is worse: it **waits** for the flag but never **takes** it. It
waits, reads the screen id, returns. Between that read and the exit routine
acting on it, another thread can change the screen state. Classic TOCTOU, in
the exact path our clear calls.

Two further consequences of that guard:

- **`0x18` is a no-op when the firmware thinks it is idle.** `screen_id > 1`
  means ids `0` (idle) and `1` (wait_blow_head) return `false` and the exit
  does nothing at all. Some of our clears never do anything.
- **The `0x18` ack proves nothing.** `case 0x18` sends `0xC9` as its *first*
  action, before reading the screen id and before any teardown. Our
  `Proto.exit()` validates `data[1] == 0xc9` and treats that as success.

### `0x18` has an Even-AI-specific teardown path

```c
case 0x18:
  _local_13c = CONCAT11(0xc9,bVar2);
  (**(code **)(param_1 + 0xc))(&local_13c,0x14);       /* ack 0xC9 first */
  pGVar14 = __get_dashboard_state();
  if ((pGVar14->field20_0xc8[0xd] == 0xb) ||           /* Translate */
     (pGVar14 = __get_dashboard_state(), pGVar14->field20_0xc8[0xd] == 0x10)) {   /* EVEN AI */
    FUN_000800ca(iVar29,0);
  }
  else {
    pGVar14 = __get_dashboard_state();
    if ((*(char *)pGVar14 == '\x02') &&
       (pGVar14 = __get_dashboard_state(), pGVar14->field20_0xc8[0xd] == '\x06')) {
      sleep(0x32);                                     /* deliberate delay on DashBoard */
    }
    FUN_0007ff66(iVar29,0);
  }
  break;
```

Even AI (`0x10`) and Translate (`0x0b`) get their own teardown routine. The
other branch contains a **hardcoded `sleep(0x32)`** when the current screen is
the DashBoard — Even Realities papered over a race here rather than fixing it,
which is corroborating evidence that this area is racy by construction.

### The clear is asynchronous

Both teardown routines walk per-surface dirty flags and call `FUN_00030458()`
for each one it finds set. That function does nothing but raise a global flag:

```c
undefined4 FUN_00030458(void)
{
  if ((DAT_20003052 != '\x01') &&
     ((cVar1 = FUN_00033d5c(), cVar1 == '\x01' ||
      (pGVar2 = __get_dashboard_state(), *(char *)pGVar2 == '\x01')))) {
    DAT_20003052 = '\x01';
  }
  return 0;
}
```

So a clear is not "blank the screen". It is "mark several surfaces clean and
ask the display thread to redraw", repeatedly, while the state it will redraw
from is still being mutated. The display thread decides what to draw via
`__ui_task_handler`, keyed on screen id.

### The firmware also enters Even AI state on its own

Writers of screen id `0x10` are `msg_sync_thread.c`,
`local_esbs_ipc_service_recv.c` and `try_to_save_file.c` — message sync,
inter-lens ESB receive, and file save. **None is a host BLE command.**

So a QuickNote save or a sync from the other lens can put a lens into Even AI
screen state with no involvement from our app. Any sighting that does not
correlate with something we sent is likely this.

## `0x50` is a dashboard lock, not display-mode control

Correction to [protocol-reference.md](protocol-reference.md),
[FINDINGS-layouts.md](FINDINGS-layouts.md) and
[even-g1-event-mapping.md](even-g1-event-mapping.md), all of which described
`0x50` as display-mode control that primes or clears the display.

`ble_process_req_dispatch.c` case `0x50`, by its own log strings:

```
"received Dashboard lock command."
"master exec dashboard lock process."
"received error dashboard lock action command."
"slave received error dashboard lock command! can't exec"
```

- **Master-only.** The slave (left lens — see
  [firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) § 4)
  rejects it and logs an error. Our broadcast `0x50` is silently discarded on
  the left.
- Requires `param_3[4] == 1`. Our `50 06 00 00 01 01` satisfies this.
- On success sets `DAT_20007f50 |= 2` and starts a k_timer;
  `DashboardLockTimerExpiry_callback` clears the lock bits on expiry, logging
  `dashboard lock timeout,release`.
- If the lock bit is already set it returns immediately — repeat sends are
  no-ops.

It does not clear the display, close a mode, or prepare for structured
content. So the `0x50 + 0x18` combo recorded as the ghost-screen fix
(`worklist-history.md`, 2026-05-09) cannot work by the mechanism we wrote down.
The plausible reason it appeared to help is that `0x50` adds a BLE round trip
of delay before `0x18`, shifting the race window. That fits the observed
outcome: improved, never eliminated.

It also means the `0x50`-before-`0x0a`-INIT and `0x50`-before-`0x52`
requirements in our nav and streaming lifecycles are unexplained. They were
derived from capture replay, not from a known mechanism. Worth testing whether
either still works without it.

## Why the official app probably avoids it

`Suspected` — not established, and the most speculative part of this document.

The official app drives `0x4E` with the Even AI status values the branch is
built around (`0x30` displaying, `0x40` complete, `0x50` manual). A final send
with upper nibble `0x40` routes to `pending = 8` rather than `0x10`, leaving no
Even AI id to render. Our `0x71` reaches the `pending = 0x10` fallthrough
whenever the text-surface state is 6.

This would also explain the reports from other third-party apps: anything
driving `0x4E` with `0x7x` text-show statuses hits the same branch.

## Candidate fixes, cheapest first

1. **Send a terminal `0x4E` with `screenStatus` upper nibble `0x40`** before
   clearing. Routes to `pending = 8` instead of `0x10`. One byte, no new
   opcode, and it attacks the cause rather than the timing.
2. **Gate the clear on `0x39`.** Query per-lens screen state first: `0`/`1`
   means `0x18` will be a no-op and can be skipped; `0x10` means we are on the
   Even AI teardown path and should expect the flash.
3. **Drop or reposition `0x50`.** It is not clearing anything, it does not work
   on the left lens, and it arms a timer that overlaps teardown. If it is only
   buying delay, an explicit delay is honest and tunable.
4. **Stop trusting the `0x18` ack.** `0xC9` is emitted before any teardown
   work, so `Proto.exit()`'s success return is not evidence the screen cleared.

## Open questions

- What is the `field_0x1010` offset-0 state byte, and when is it 6? This
  decides how often the `pending = 0x10` branch is reached.
- Does the flash correlate with `0x39` reporting `0x10` at clear time? That
  would confirm the mechanism directly.
- Is the pending slot (`field20_0xc8[0x13]`) read by the display thread, or
  only consumed on exit? Confirming it feeds `__ui_task_handler` would close
  the last gap in the chain.
- Do `0x0a` nav and `0x52` streaming still work with no preceding `0x50`?

## Related docs
- [firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) — the `0x39` readback, lens roles, `0x4E` acks
- [firmware-decomp-notes.md](firmware-decomp-notes.md) — the decompilation source and its limits
- [protocol-reference.md](protocol-reference.md) — `0x4E` header and `screenStatus` values
- [FINDINGS-layouts.md](FINDINGS-layouts.md) — where `0x50` was first characterised
- [evenai-flash-fix-brief.md](evenai-flash-fix-brief.md) — implementation brief
