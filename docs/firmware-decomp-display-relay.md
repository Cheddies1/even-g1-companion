# Inter-leg relay, display acks, and per-lens state — firmware source read

> **Document type:** G1 reference — firmware source read
> **Audience:** Anyone debugging single-lens / blank-eye display behaviour, or designing display verification
> **Evidence basis:** Ghidra decompilation of the G1 firmware (`JohnRThomas/even_realities_decomp`, commit `f571782`). **No device testing.** Nothing here has been observed on hardware.

Companion to [firmware-decomp-notes.md](firmware-decomp-notes.md), which covers
the source and its limits. This file answers four specific questions raised
while investigating a blank lens, in the order they were asked.

Everything below is `Firmware-source`: reliable on structure and control flow,
silent on behaviour. Each section ends with what would actually confirm it on
device.

## Contents

1. [Which opcodes are in the forwarding subset](#1-which-opcodes-are-in-the-forwarding-subset)
2. [What the `0x4E` ack bytes mean](#2-what-the-0x4e-ack-bytes-mean)
3. [Per-lens display state in the readback range](#3-per-lens-display-state-in-the-readback-range)
4. [Which lens is the slave](#4-which-lens-is-the-slave)
5. [Corrections to earlier notes](#5-corrections-to-earlier-notes)
6. [Open questions and the probes that would settle them](#6-open-questions-and-the-probes-that-would-settle-them)

---

## 1. Which opcodes are in the forwarding subset

**Answer: `0x4E` is in it, `0x52` is not — and it does not matter, because
`0x4E`'s case carries no display content.**

### The gate

`master_process_put_req` (reached via `FUN_00019d14`) accepts three opcode
ranges. Anything outside them gets a literal ASCII `"error"` reply and the
firmware logs `tx error req_type head->req_type %d`:

- `0x01`–`0x27`
- `0x29`–`0x45`
- `0x47`–`0x56`

### The three switches

| Switch expression | Cases present | Resulting opcodes | Default |
|---|---|---|---|
| `opcode - 1` | `0 1 2 4 6 7 8 10 0xc 0xe 0x10 0x13 0x25` | `01 02 03 05 07 08 09 0B 0D 0F 11 14 26` | `return 0` |
| `opcode - 0x29` | `0 1 2 3 4 9 10 0xb 0xc 0xd 0xe` | `29 2A 2B 2C 2D 32 33 34 35 36 37` | `return 0` |
| raw opcode | `0x4a 0x4b 0x4c 0x4d 0x4e 0x4f` | `4A 4B 4C 4D 4E 4F` | `return 0` |

So `0x52` sits inside the accepted `0x47`–`0x56` range — it is **not** rejected
as a bad req_type — but it falls to `default: return 0`. A silent no-op with a
zero-length reply.

Note what else is absent from the first switch: `0x06`, `0x0A`, `0x1E`. The
large host content pushes (dashboard information, navigation card, notes) are
**not** in the forwarding subset. That is consistent with the capture evidence
that the official app writes those to both legs itself at near-identical
timestamps.

### `0x4E` is in the subset but relays no text

The case body reads **zero bytes** of the request payload (`param_2` appears
0 times in it):

```c
case 0x4e:
  *(undefined1 *)(*(int *)(param_1 + 0x1010) + 0x1e6) = 0;
  if (*(char *)(*(int *)(param_1 + 0x1010) + 7) == '\0') {
    *(undefined1 *)(*(int *)(param_1 + 0x1010) + 7) = 10;
  }
  *param_3 = 0xc9;
  if (**(int **)(param_1 + 0x1068) == 0x10) {
    return 1;
  }
  uVar13 = 0x10;
  goto LAB_0002d346;
```

A state poke and an ack. No text content crosses.

### What does cross between the temples

Two independent lines of evidence that the inter-leg link carries *state*, not
display payloads:

- `sync_to_slave.c` is an **ESB radio** path (Nordic Enhanced ShockBurst), not
  the `spim` path. Its log strings describe what it guards: `ESB send up
  package is changed`, `down package is receiving`, `even ai is changed or
  receiving`, `imu status is changed`, `package id is changed`. State sync with
  change detection.
- `slave_display_thread.c` reacts to **semantic wake reasons** and index
  syncs, not payloads: `BLE:wakeup:new-unread_msg`,
  `IMU:wakeup:new-notification`, `IMU:wakeup:onboarding`,
  `IMU:wakeup:uncomplete msg`, `received master send calendar index sync
  commmand ,timestamp = %d,exec index update %d`. Sibling functions follow the
  same shape — `master sync news index to slave`, `master sync quicknote index
  to slave`, `master sync stocks index to slave`,
  `SendDashBoardStartupModeInfoToSlave`, `SendDoubleTapCustomizeToSlave`,
  `SendPowerInfoToSlave`, `SendSystemLanguageInfoToSlave`.

Firmware-native surfaces sync semantically and each lens re-renders locally.
Host-pushed text is not part of that.

### Consequence

**The host must write display content to both legs.** A single-leg `0x4E`
write does not reach both lenses, and `0x52` is not acknowledged on the
forwarding path at all. Any fix for a blank lens on a host-pushed display
surface belongs in the leg-targeting logic, not upstream of it.

### What would confirm it on device

Write `0x4E` text to one leg only and look at both lenses. One line of test
code, and it settles the whole section.

---

## 2. What the `0x4E` ack bytes mean

**Answer: the byte after `C9` is the echoed sequence number, not a
received-vs-rendered discriminator. The signal you want is the status byte
itself — `0xC9` vs `0xCB`.**

### The deferred completion frame

`deal_event_to_phone.c`, on internal event `0xF2`, emits five meaningful bytes
padded to a fixed 21-byte frame:

```
4E C9 <seq> <totalChunks> <lastChunkIndex>
```

| Byte | Source | Meaning |
|------|--------|---------|
| 0 | literal | `0x4E` |
| 1 | literal | `0xC9` |
| 2 | `field20_0xc8[4]` | echoed `textSeqNum` (see below) |
| 3 | `DAT_20019a68` | total chunks, **zeroed on read** |
| 4 | `DAT_20019a67` | final chunk index, **zeroed on read** |

Byte 2 is written by `FUN_0007f41e(param_1, param_2)`:

```c
void FUN_0007f41e(undefined1 param_1,undefined1 param_2)
{
  pGVar1 = __get_dashboard_state();
  pGVar1->field20_0xc8[6] = param_2;
  pGVar1 = __get_dashboard_state();
  pGVar1->field20_0xc8[4] = param_1;
}
```

Every call site in the `0x4E` handler passes `param_3[1]` as `param_1` —
request byte 1, i.e. the `0x4E` header's `textSeqNum`. So byte 2 is an echoed
sequence number. Useful for correlating an ack to a specific send; not a render
status.

Bytes 3–4 are consumed: `deal_event_to_phone` captures them at entry and zeroes
both before sending. A second read returns zeros.

### The received-vs-complete signal is byte 1

In the `0x4E` handler (`ble_process_req_dispatch.c` case `0x4e`):

```c
if ((uint)param_3[3] == param_3[2] - 1) {
  uVar10 = 0xc9;          /* final chunk */
} else {
  ... FUN_0007f472(pvVar19,0x1e9,pGVar6->field20_0xc8[4],1);
      FUN_0007f41e(param_3[1],1);
  uVar10 = 0xcb;          /* intermediate chunk */
}
```

with `param_3[2]` = total chunks and `param_3[3]` = current chunk index.

- `0xCB` — chunk accepted, more expected
- `0xC9` — final chunk accepted

**If the host treats anything other than `0xC9` as failure, every intermediate
chunk of a multi-chunk text send reads as a failure.** Single-chunk sends
(`totalChunks = 1`, `currentChunk = 0`) always satisfy `0 == 1 - 1` and get
`0xC9`, so this only bites once chunking starts.

The identical `0xC9` / `0xCB` split appears in the `0x0F` handler
(`ble_process_put_req.c` case `0xf`), so it is a family convention rather than
something specific to `0x4E`.

### Master / slave asymmetry in the completion path

```c
bVar5 = __is_master();
if (bVar5) {
  if ((uint)bVar16 == bVar12 - 1) {
    DAT_20019a69 = 0x4e;
    DAT_20019a67 = bVar16;
    DAT_20019a68 = bVar12;
    FUN_0007f41e(param_3[1],0);
    return 0;                    /* no synchronous reply */
  }
}
else if ((uint)bVar16 == bVar12 - 1) {
  FUN_0007f41e(param_3[1],0);    /* falls through to the normal inline reply */
}
```

On the **final** chunk the master stashes the counters and returns 0, deferring
to the event path above. The non-master replies inline. So the deferred
`4E C9 …` frame is **master-only**.

### What none of this proves

All of it means "accepted by the text handler". That is one layer above a GATT
ACK and still below render. The closest thing to a render-phase flag is
`FUN_0007f41e`'s second argument (`field20_0xc8[6]` — `1` on the `0xCB` path,
`0` on completion), and it is **not** carried in the ack frame. It is internal
state only.

For an actual "is this lens showing something" answer, see §3.

### Related acks in the same emitter

`deal_event_to_phone` special-cases three internal event codes into
`<opcode> C9 <state>` frames rather than `F5 <code>`:

| Internal event | Emitted opcode | State byte source |
|---|---|---|
| `0xF0` | `0x0D` | `param_1 - 0x6af` |
| `0xF1` | `0x0F` | `param_1 - 0x6b0` |
| `0xF2` | `0x4E` | `param_1 - 0x6b0` |

`param_1 - 0x6b0` is `field20_0xc8[4]`, traced above. The `0x0D` slot
(`- 0x6af`, `field20_0xc8[5]`) is **not** traced — the same offset is written by
the `0x0a` navigation handler as a nav sequence byte, which may be offset
arithmetic drift in the decompilation rather than genuine sharing. Treat the
`0x4E` row as solid and the other two as indicative.

### What would confirm it on device

Send a deliberately chunked `0x4E` block (force `totalChunks > 1`) and log
every response byte rather than just validating byte 1. Expect `0xCB` on each
intermediate chunk and one `4E C9 <seq> <total> <final>` at the end. Confirms
the chunk semantics and the seq echo in one run.

---

## 3. Per-lens display state in the readback range

**Answer: yes — `0x39`, and it is answered locally rather than through the
relay, so it reports the queried lens's own state.**

### Full `0x29`–`0x3F` map

Names are the firmware's own, from its `printk` strings. "Via relay" means the
case calls `FUN_00019d14`.

| Opcode | Content | Answered |
|--------|---------|----------|
| `0x29` | `BLE_REQ_GET_BRIGHTNESS` → `29 65 <level> <auto>` | via relay |
| `0x2A` | `BLE_REQ_GET_ANTI_SHAKE_ENABLE` | via relay |
| `0x2B` | `BLE_REQ_GET_DISPLAY_MODE` → `2b 69 <b2> <b3>` | via relay |
| `0x2C` | `BLE_REQ_GET_DEVICE_INFO` — request carries the host platform byte | — |
| `0x2D` | `BLE_REQ_GET_M_N_S_MAC` | — |
| `0x2E` | unnamed | — |
| `0x32` | `BLE_REQ_GET_WAKEUP_ANGLE` | — |
| `0x33` | `BLE_REQ_GET_GLASSES_SN` | — |
| `0x34` | `BLE_REQ_GET_DEVICE_SN` | — |
| `0x35` | `BLE_REQ_GET_ESB_CHANNEL` | — |
| `0x36` | notification counts (`get_notification_counts_cmd_process`) | local |
| `0x37` | unnamed, returns 5 bytes | via relay |
| `0x38` | ANCS enable state (`globle->enable_ancs %d`) | local |
| **`0x39`** | **system status / current running app** | **local** |
| `0x3A`–`0x3F` | unnamed | — |

`0x2F`, `0x30`, `0x31` have no cases.

### `0x39` — system status

Logs `return system status to app,current running app is E_ID_SCREEN_IDLE` or
`return system status to app,current running app is %d`. Returns 6 bytes; the
status byte is:

- `0x00` when `__is_idle()` is true
- otherwise `field20_0xc8[0xd]` — the current running app / screen id
- `0xFF` when the declared length does not match the actual packet length

Crucially the case contains **no `FUN_00019d14` call**, unlike `0x29` / `0x2A` /
`0x2B` / `0x37`. It answers from local state, so it describes the lens you
asked.

This is the closest thing in the protocol to "what is this lens showing", and
the only readback that would let the host verify a display push rather than
trust a GATT ACK.

### Two caveats before building on it

**Screen ids are not mapped.** `field20_0xc8[0xd]` is compared against `0x00`,
`0x04`, `0x06`, `0x07` and `0x09`–`0x14` across
`bt_ancs_notification_source_handler.c`, `confirm_message.c`,
`key_event_thread.c`, `send_dmic_msg.c`, `check_disp_onboarding.c` and
`msg_sync_thread.c`. Enumerating them is a straightforward read of those files,
not done here.

**`__is_idle()` is compound**, so status `0x00` means more than "screen id 0":

```c
bool __is_idle(void)
{
  if (((*(int *)pGVar1->___glasses_state == 0) &&
      (*(char *)(pGVar1->___glasses_state + 4) == 0x1)) &&
     (pGVar1->field20_0xc8[0xd] == 0x0)) {
    bVar2 = pGVar1->field_0xfea == '\x01';
  }
  else { bVar2 = false; }
  return bVar2;
}
```

A lens can be non-idle with screen id 0 if the glasses-state word or
`field_0xfea` disagree.

### What would confirm it on device

Query `0x39` on both lenses with one lens deliberately in a different state
(e.g. text pushed to the right only). If the two lenses return different status
bytes, `0x39` is per-lens and usable. Running `0x2B` in the same pass is the
cheapest available test of the relay-topology question from §1: if `0x2B`
reports the *peer's* mode while `0x39` reports the local one, the relay crosses
temples.

---

## 4. Which lens is the slave

**Answer: left. Master advertises as `_R_`, non-master as `_L_`.**

From `bt_start.c`, the branch that selects the advertised device name:

```c
bVar6 = __is_master();
if (bVar6) {
  ... pcVar9 = "%s_R_%02X%02X%02X";        /* and _%d_R_, V%d%d%d_R_ variants */
}
else {
  ... pcVar9 = "%s_L_%02X%02X%02X";        /* and _%d_L_, V%d%d%d_L_ variants */
}
```

with `"Even G1"` as the `%s`. So right = master, left = slave.

It is the same flag used everywhere else:

```c
bool __is_master(void) { return (bool)*(undefined1 *)GLOBAL_STATE; }
```

That one byte gates the deferred `0x4E` completion frame (§2), the direction of
`sync_to_slave`, and every `Send*ToSlave` function. Each temple stores both MAC
suffixes — the `_R_` branch reads fields `0xfde`/`0xfdf`/`0xfe0`, the `_L_`
branch `0xfe4`/`0xfe5`/`0xfe6` — consistent with the
`master mac: … slave mac: …` log string.

### Consequence for asymmetric writes

Since `0x4E` content is not relayed in either direction (§1), a right-only
(master) write will not propagate text to the left lens. The master/slave split
is real elsewhere though: a **left-only** write additionally misses the deferred
completion-event path, because that path is master-only. So left-only is worse
than right-only — but not for the reason "the slave depends on relay for
content" would suggest.

### Not established

How master is assigned. No writer of `GLOBAL_STATE` byte 0 was found in the
labelled source, so whether it comes from a GPIO strap, flash, or ESB
negotiation is unknown.

---

## 5. Corrections to earlier notes

Both of these correct [firmware-decomp-notes.md](firmware-decomp-notes.md) and
[protocol-reference.md](protocol-reference.md) as first written on 2026-09-07,
and have been applied there.

### `0x29` response byte 3 is the auto-brightness flag

Previously recorded as "the auto flag label stays unconfirmed". It is
confirmed structurally. Opcode `0x01` (brightness set) takes `param_2[4]` as
level and `param_2[5]` as the auto flag, and writes the auto byte to
`param_1[0xf9c]`:

```c
case 0:   /* opcode 0x01 */
  if ((param_1[0xed5] != param_2[4]) || (param_1[0xf9c] != param_2[5])) {
    (**(code **)(param_1 + 0xb8c))(param_1 + 0xb6c);
    param_1[0xf9c] = param_2[5];
    ...
  }
  *param_3 = param_2[4];
  param_3[1] = param_2[5];
  param_3[2] = 0xc9;
  return 3;
```

`0x29` reads back exactly those two fields:

```c
case 0:   /* opcode 0x29 */
  *param_3 = param_1[0xed5];   /* byte 2 — level */
  bVar2    = param_1[0xf9c];   /* byte 3 — auto  */
```

Same field. The JohnRThomas wiki was right. The two empirical probes on
firmware 1.6.6 that returned byte 3 = `0x00` now need a different explanation —
auto genuinely off at probe time, or the relay answering for the wrong leg. A
re-probe should set auto on, confirm via `F5 12` behaviour, and query both legs.

Incidental from the same read: `0x01` replies `<level> <auto> C9` (3 bytes), and
`0x2A` reads `param_1[0xf64]` which opcode `0x02` writes — so `0x02` sets
anti-shake and `0x2A` reads it back.

### `0x2C` is `GET_DEVICE_INFO`

Previously listed as a standalone "host platform declaration" opcode, with
`BLE_REQ_GET_DEVICE_INFO` recorded as opcode-unpinned. They are the same thing:
`0x2C` is `GET_DEVICE_INFO`, and the platform byte rides in the request
(`raw_data[1] == 1` → Android, `== 2` → iOS). `0x2D`, `0x32`, `0x33`, `0x34`
and `0x35` are now pinned too — see the table in §3.

### Overstated relay topology

`firmware-decomp-notes.md` said the `0x29` readback "is answered from the other
temple over SPI". That is more than the source supports and has been softened.
`FUN_00019d14` logs `spim tx` / `spim ret` around the call and the handler is
named `master_process_put_req`, but whether the struct it reads holds the
peer's state or local state is not established. There is separately an ESB path
for temple-to-temple traffic (`sync_to_slave`,
`local_esbm_ipc_service_recv` / `local_esbs_ipc_service_recv`). The opcode
gating in §1 holds either way.

---

## 6. Open questions and the probes that would settle them

| # | Question | Probe |
|---|----------|-------|
| 1 | Does a single-leg `0x4E` write reach both lenses? | Write text to one leg, look at both lenses |
| 2 | Do intermediate chunks really ack `0xCB`? | Force `totalChunks > 1`, log all response bytes |
| 3 | Is `0x39` per-lens? | Query both lenses with one in a known different state |
| 4 | Does the relay cross temples? | Same run as #3, comparing `0x2B` against `0x39` |
| 5 | Is `0x29` byte 3 the auto flag in practice? | Set auto on, query both legs |
| 6 | What are the screen ids in `field20_0xc8[0xd]`? | Source read of the six files listed in §3 |
| 7 | How is master assigned? | Unresolved from source; would need a strap/flash check |

Probes 3 and 4 are the same run. Probes 1 and 2 are each a few lines of test
code and would confirm or kill the two conclusions that matter most.

## Related docs
- [firmware-decomp-notes.md](firmware-decomp-notes.md) — the source, its limits, and the wider reconciliation
- [protocol-reference.md](protocol-reference.md) — wire-level command catalogue
- [FINDINGS-layouts.md](FINDINGS-layouts.md) — rendering protocol findings
- [FINDINGS-battery+brightness.md](FINDINGS-battery+brightness.md) — the `0x29` empirical probes
