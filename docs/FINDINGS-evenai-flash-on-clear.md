# "Even AI is listening" flashed during screen clear - firmware-source hypothesis and device result

> **Document type:** G1 findings
> **Audience:** Anyone working on the display clear path or the `0x4E` text renderer
> **Evidence basis:** Ghidra decompilation of the G1 firmware (`JohnRThomas/even_realities_decomp`, commit `f571782`), read against our own clear implementation, plus three instrumented device runs on 2026-09-08 (S24 Ultra, firmware 1.6.6). The source identified the mechanism; the device runs corrected which field matters, killed three candidate fixes, and established a 2/2 predictor. No host-side fix was found — see "Fixes: what was tried".

## The symptom

Intermittently, clearing the display flashes the firmware's "Even AI is
listening" screen for roughly one frame before the screen blanks. Not reliably
reproducible. Long-standing, never solved, previously written off as "one of
those things". Also reported by other third-party G1 apps.

Believed absent from the official Even Realities app — see
"[Why the official app avoids it](#why-the-official-app-avoids-it)".

## Summary

Four firmware facts support a race hypothesis:

1. **Screen id `0x10` is the Even AI screen.** `ui_task_handler.c` dispatches
   id `0x10` to `ui_even_ai_task`.
2. **Our `0x4E` text sends keep us on the Even AI surface.** ~~The `0x4E`
   handler writes `field20_0xc8[0x13] = 0x10`~~ — that is the *pending* slot
   and turned out to be the wrong field (see Run 1). What matters is that the
   *live* id `field20_0xc8[0xd]` reads `0x10` on every clear we sampled,
   because we render everything with `screenStatus 0x71`.
3. **The `0x18` clear path checks screen state without holding the lock that
   protects it.** The guard waits for a non-atomic software mutex to be free,
   reads the screen id, and returns without taking it.
4. **The clear is asynchronous.** Teardown sets a global "refresh needed" flag
   per dirty surface; the display thread renders whenever it next runs.

The device runs below refined this. The `0x4E` pending slot turned out to be
the wrong field — `0x39`, `case 0x18` and `__ui_task_handler` all use the
*live* screen id `field20_0xc8[0xd]`, and that reads `0x10` on every clear
because our `0x71` text sends keep us on the Even AI surface. The flash is a
transient re-render of that surface on the **master (right) lens** during the
`0x18` teardown. Confirmed predictor: whenever the right lens still reports
`0x10` after the clear, the flash appears (2/2). No host-side fix was found —
see "Fixes: what was tried".

**And our existing mitigation never worked the way we documented it.** `0x50`
is not display-mode control — it is a master-only dashboard lock that does not
touch the display. Run 2 removed it entirely and the flash persisted, so it was
neither a cause nor a mitigation; the `0x50 + 0x18` combo recorded as the
2026-05-09 ghost-screen fix was not fixing this.

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

## Device results — 2026-09-08

Three instrumented runs against an S24 Ultra on firmware 1.6.6, reading
per-lens screen state via `0x39` around every clear. **Conclusion: cause
characterised, no host-side fix found.**

### Run 0 — the instrument was wrong

The first run read the wrong byte. `readScreenState` took
`response.data[1]`, which is the length byte echoed back from our own request
(`39 04 00 00`). Every response was `39 04 00 00 00 10`, so the app logged
`0x04` on every clear and we spent hours concluding the flash "did not
correlate with screen state". The status byte is **index 5**, and it read
`0x10` — Even AI — on both lenses, every time.

Two artefacts followed from this: the `0xff` malformed-header guard could never
fire (it tested the echoed length), so "none returned `0xff`" was not header
validation; and the earlier terminal-`0x41` experiment was judged purely by eye
with no working state measurement behind it.

The response layout is now documented inline in `readScreenState`.

### Run 1 — terminator and teardown, 11 mode switches

Each clear sampled `0x39` three times: before, after a terminal `0x4E` with
`screenStatus = 0x41`, and after the `0x18`.

| # | post-terminator | POST-clear | Flash |
|---|---|---|---|
| 1–4 | `10/10` | `00/00` | clean |
| 5 | `00/10` | `00/00` | clean |
| 6 | `10/10` | `00/00` | clean |
| **7** | `10/10` | **`00/10`** | **FLASH** |
| 8 | `10/10` | `00/00` | FLASH |
| 9 | `00/10` | `00/00` | clean |
| 10 | `10/10` | `00/00` | FLASH |
| 11 | `10/10` | `00/00` | FLASH |

**Killed: the terminal `0x40` route.** post-terminator read `0x10` in 9 of 11.
The two exceptions had abnormally slow read intervals (580 ms and 647 ms versus
~250 ms typical), so they look like BLE read artefacts. The `0x4E` handler
writes `field20_0xc8[0x13]` (pending) and `*(0x1010)`; `0x39`, `case 0x18`'s
branch and `__ui_task_handler` all use `field20_0xc8[0xd]` (live). Different
fields. The terminator cannot change which teardown branch `0x18` takes.

**Killed: the unconditional state leak.** POST-clear read `0x00` in 10 of 11,
so the screen id does normally get reset. The original claim — that
`FUN_000800ca` leaves it set — is wrong *as an unconditional statement*.

**Confirmed: pre-clear is `0x10` on both lenses, all 11 times.** Our `0x4E`
sends use `screenStatus 0x71` continuously, so the firmware has us parked in
the Even AI surface whenever text is displayed. This is the underlying
exposure.

### Run 2 — `0x50` removed, 8 mode switches

Terminator dropped (proven inert, and its round trips perturbed the timing).
`0x50` skipped, because it was the last host-side variable that is itself
master-only — the firmware accepts it only on the master lens and it arms a
k_timer — and the flash is right-eye-only.

| # | POST-clear | Flash |
|---|---|---|
| 1–4 | `00/00` | clean |
| **5** | **`00/10`** | **FLASH** |
| 6 | `00/00` | clean |
| 7 | `00/00` | clean |
| 8 | `00/00` | FLASH |

**Killed: `0x50` as a cause.** The flash arrived at switch 5 of 8 without it,
versus switch 7 of 11 with it. Too small a sample to compare rates, but clearly
not the cause.

Also killed: "the retained state affects the *next* render". Switch 6 was clean
despite switch 5 leaking.

### The one correlation that held

| direction | result |
|-----------|--------|
| POST-clear `R=0x10` → flash | **2 / 2** (run 1 switch 7, run 2 switch 5) |
| flash → POST-clear `R=0x10` | 2 / 6 |

Whenever the right lens retains `0x10` after the clear, the flash appears.
The converse usually fails, because the POST sample lands ~700 ms after the
`0x18` and most transients are over by then. So the read catches the tail of an
unusually long transient, not the mechanism itself.

Right lens is the master ([firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) § 4),
and the flash is right-eye-only — reported as consistently right-eye across
several dozen switches, with none seen with the right eye closed.

### Reconciled mechanism

The source finding survives, in weaker form. `FUN_000800ca` genuinely does not
call `update_persist_task_status_to_idle` — it is the only `0x18` teardown path
that omits it. But the screen id usually ends up at `0x00` anyway, so a
secondary path must normally reset it. `low_speed_peripheral_dispatch_thread.c`
is among the other `to_idle` callers, and cleanup riding a low-priority
periodic thread would explain an occasional miss on one lens.

So: `0x18` from screen `0x10` wipes the framebuffer without resetting the
screen id; a secondary path normally resets it within a few hundred ms;
occasionally it is slow on the master, and a redraw in that window dispatches
`__ui_task_handler(0x10)` → `ui_even_ai_task` → one frame of
"Even AI is listening / Release to finish recording" in the right eye.

`Suspected` — this ties the source to the data and fits every observation
(right-eye-only, intermittent, the 2/2 predictor, and identical traffic
producing different outcomes), but the secondary-path attribution is not
directly observed.

### Why the official app avoids it

`Suspected`, and the best-supported version of this claim we have. Our `0x4E`
sends use `screenStatus 0x71` for everything, so `0x39` reads `0x10` on every
single clear — we are always tearing down out of the Even AI surface. The
official app drives the Even AI status lifecycle (`0x30` displaying, `0x40`
complete, `0x50` manual) and spends most of its time on other surfaces, so it
rarely hits this teardown path at all.

MentraOS logged the same symptom as unsolvable. That is right in practice; this
document is the "why".

## Fixes: what was tried, and where it was left

| Candidate | Outcome |
|-----------|---------|
| Terminal `0x4E` with `screenStatus` upper nibble `0x40` | **Disproved.** Writes the pending slot, not the live screen id. |
| Gate the clear on `0x39` | **Not a predictor.** Pre-clear is `0x10` on every clear, flashing or not. |
| Remove `0x50` from the clear path | **No effect.** Eliminated as a cause. |
| Detect-and-repair: re-send `0x18` when POST-clear reports `0x10` | **Not pursued.** Catches ~1/3 of events and costs two BLE round trips on every clear, for a one-frame cosmetic glitch. |
| Drive the full Even AI status lifecycle (`0x31` renders, `0x41` terminator) | **Untested.** The only remaining avenue. Would change every text render in the app; not proportionate to the symptom. |

**Left unfixed deliberately.** `Proto.clearDisplay()` is back to its original
`0x50 + 0x18` sequence. `0x50` was left in place despite being inert here,
because removing it showed no measured benefit and this path has regressed
before (`worklist-history.md`, 2026-05-09). The broader question is tracked as
`nav-0x50-necessity`.

Two things were kept from the investigation:

- the `readScreenState` byte-offset fix, with the response layout documented
- `Proto.postClearStateProbe`, default `false` — the three-point `0x39`
  sampling, retained for any future run

## What this cost, and the two mistakes worth remembering

Most of the day went on two measurement errors, not on the firmware:

1. **Wrong byte offset.** The brief said "the status byte is the screen id"
   without pinning the index. The instrument read the echoed request length for
   several hours and produced a confident, wrong negative result.
2. **Instrumented the wrong event.** The first design sampled state *before* a
   clear to explain a transient that happens *during and after* it. A
   pre-clear sample could not have detected the thing it was meant to detect.

Both produced clean-looking data that pointed the wrong way. When a source-read
hypothesis is being tested, pin the exact byte offsets and check that the
instrument can observe the predicted event before trusting a negative.

## Open questions

- Why do most flashes show a clean `00/00` POST read? Presumed transient
  shorter than the ~700 ms sample delay, but unconfirmed.
- Which path normally resets the screen id after `FUN_000800ca`, and is it
  really the low-speed periodic thread?
- Would driving the `0x30`/`0x40` Even AI status lifecycle keep us off screen
  `0x10` entirely?

## Related docs
- [firmware-decomp-display-relay.md](firmware-decomp-display-relay.md) — the `0x39` readback, lens roles, `0x4E` acks
- [firmware-decomp-notes.md](firmware-decomp-notes.md) — the decompilation source and its limits
- [protocol-reference.md](protocol-reference.md) — `0x4E` header and `screenStatus` values
- [FINDINGS-layouts.md](FINDINGS-layouts.md) — where `0x50` was first characterised
- [evenai-flash-fix-brief.md](evenai-flash-fix-brief.md) — implementation brief
