# G1 companion-app comparison notes

Comparative analysis of three other Even Realities G1 companion apps, against our `EvenDemoApp` baseline + roadmap. Investigation date: 2026-05-18.

Sibling document: [`python-sdk-comparison-notes.md`](python-sdk-comparison-notes.md).

## Apps under review

| App | Stack | Size | Status in this doc |
|---|---|---|---|
| **fahrplan** | Flutter + Android native (same as us) | 60 MB | In progress (sub-agent running) |
| **openclaw-glasses** | TypeScript / Node (Bun lockfile, runs via tsx) | 1.8 MB | Reviewed |
| **MentraOS** | Bun monorepo, multi-glasses OS layer | 1.4 GB | Deferred to separate session |

---

## openclaw-glasses

**Verdict up front:** does NOT shortcut our Terminal Mode work. It's a one-shot Q&A app, not a session mirror, and its apparent simplicity is a property of running on MentraOS rather than a borrowable design pattern.

### What it actually is

Wake-word voice assistant connecting a G1 (paired via MentraOS phone app) to OpenClaw — a third-party Claude-Code-style coding agent product with a local daemon. User says "Hello", glasses show "Listening!", user asks a question, dots animate, a single answer ≤150 chars displays for 10 s.

**Topology:** G1 ↔ MentraOS phone app ↔ MentraOS cloud ↔ this Node server (on user's Mac) ↔ local OpenClaw daemon.

**Runtime:** Node via `tsx`. Single process subclassing `@mentra/sdk`'s `AppServer`. Deployed as a macOS LaunchAgent.

### What it does NOT have

This is the key finding. Compared to our Terminal Mode v1 spec:

- **No BLE transport in repo.** MentraOS owns the entire BLE stack; this app gets `session.events.onTranscription(...)` and `session.layouts.showTextWall(...)` as primitives.
- **No session mirroring.** `sendMessage` returns `Promise<string>` (`gateway-client.ts:378-462`). There is no subscription primitive, no `tool-call-start`, no `turn-end`, no thinking indicator from session state.
- **They have the streaming firehose and turn it off.** `gateway-client.ts:429-431`:
  ```typescript
  if (msg.event === 'agent' && payload?.stream === 'assistant' && payload?.data?.text) {
      fullText = payload.data.text; // Use full text, not delta
  }
  ```
  `fullText` is replaced on every event, not appended. They only paint on `state === 'final'`.
- **No client-side conversation buffer** — they rely on `sessionKey: glasses-<sessionId>` and let the OpenClaw backend thread continuity.

### Crypto comparison vs Happy

The WS endpoint is `ws://localhost:18789`. **No E2E encryption because the data plane is local.** They sign an Ed25519 connect challenge to authenticate a paired device to the local daemon, but there's no relay traversal, so no content cipher needed. Happy needs libsodium because Happy ferries messages through their cloud E2E-encrypted; OpenClaw doesn't because the data never leaves the host.

This is **not** "OpenClaw cleverly avoided crypto" — it's "OpenClaw doesn't need crypto because there's no remote data plane".

### Things worth borrowing

1. **Confidence-and-duration noise filter** (`transcription.ts:45-61`). Drop utterances <500 ms or mean confidence <0.85 *before* wake-word matching. About 20 lines of Dart to port. Belongs in our QuickAsk/Router wake path regardless of which AI backend we choose.
2. **Process-exit-on-permanent-disconnect under a supervisor** (`index.ts:101-107`). When reconnect logic genuinely gives up, kill the process and let the OS restart. Analogue for us: foreground-service restart policy as a last-resort fail-safe under our three-layer reconnect stack.
3. **Stream-suppression rendering** (`gateway-client.ts:429-440` + `transcription.ts:143-162`). Independent corroboration of our v1 rule "discard streaming deltas, show a thinking animation, paint on transition events". Two unrelated teams arriving at the same constraint is a strong signal.

### Things explicitly NOT worth borrowing

1. **The "simplicity" is the MentraOS dependency.** Adopting their approach means migrating off our own BLE stack onto someone else's platform. Discarding everything in our lower layers is not a shortcut.
2. **One-shot Q&A is not a session mirror.** The features that matter for Terminal Mode (`tool-call-start` progress, `turn-end → "Claude waiting"`, thinking indicator from `ephemeral activity`) have zero implementation here. The 280 lines that bridge "AI ↔ glasses display" only cover the wake/answer/display loop — the easy part.
3. **OpenClaw-only lock-in.** Small third-party agent with no leverage to switch. Happy is at least agent-agnostic in principle.

### The genuinely transferable idea

If Claude Code exposes a local IPC endpoint (UNIX socket, named pipe, file tail, documented `--port` flag), we could prototype a **laptop-tethered Terminal-Mode-v0** that skips Happy + crypto entirely:

- Claude Code on laptop → local socket → small adapter (Dart or Node) → over LAN to our Flutter app via WebSocket/HTTP-SSE → existing BLE render path.
- Read-only display first. Reply path slips to v0.1.
- Pre-spike check (half-day): investigate `claude --help`, Code SDK docs, any documented local surface. If nothing, the idea collapses and we're back to Happy.
- **What v0 does NOT replace:** Happy's away-from-desk use case. Mobile-network Terminal Mode. Encrypted relay. Multi-device. These remain why Happy is the eventual target.

### Candidate backlog items (TBC after fahrplan)

- **STT noise filter** — adopt the duration + confidence floor before any wake-word or trigger matching. Low effort, high robustness. Map to our QuickAsk and Router v1 trigger logic.
- **Terminal-Mode-v0 local-tether spike** — half-day investigation of Claude Code's local surface. Decision input for whether to do v0 ahead of Happy crypto work. Pure spike, no production code.
- **Process-exit fail-safe on terminal disconnect** — long-tail safety net for the foreground service.

---

## fahrplan

Same Flutter + Kotlin stack as us. ~14k Dart lines (vs our ~14k — basically a wash). Public GitHub repo (`meyskens/fahrplan`), F-Droid distribution, README explicitly invites copying ("Please copy as much code as you want — expanding the G1 open source ecosystem is better for everyone!"). Author chose G1 because it accepts his prescription.

**Verdict up front:** fahrplan is the highest-value comparison target. Same stack, overlapping feature surface, **a fully working reference implementation of the deterministic-router pattern we have as Router v1 backlog**, and a complete `0x1E` dashboard-widgets infrastructure we don't have yet. They're materially worse than us on BLE robustness and the mode model, equal on text rendering, and ahead on voice / dashboard / multi-provider STT.

### Architecture in prose

`BluetoothManager` (926 lines, single god-object) owns left/right `Glass` instances, drives a 1-minute sync timer that pushes dashboard widgets + time/weather, holds the notification listener, and exposes every BLE write API. Inbound traffic flows `Glass.handleNotification()` → `BluetoothReciever.singleton.receiveHandler()` (421 lines) which routes by opcode. Voice flows go into `Voicecontrol` (`lib/voice/voicecontrol.dart`) which fuzzy-matches transcripts against `VoiceModule` registries. Three big classes carry most of the logic.

For comparison: we have 34 service files. Their decomposition is much flatter than ours. **Their shape would be a regression for us — keep ours.**

### BLE transport — we are clearly ahead

| Axis | fahrplan | us |
|---|---|---|
| Heartbeat opcode + format | `0x25`, 6-byte, **byte-for-byte identical to ours** (`models/g1/glass.dart:160-170`) | Same |
| Heartbeat cadence | 5 s fire-and-forget (`glass.dart:173-177`) | 2 s with ACK echo check |
| Reconnect | Immediate, no backoff, no cap, no cooldown (`bluetooth_manager.dart:299-308`) | Exponential 2/4/8/16/30s + per-leg cooldown gates |
| Connection priority | `HIGH` + MTU 251 on connect, never downgrades | Same |
| Packet pacing | Ad-hoc `Future.delayed`, 5-second default between text-wall pages (`bluetooth_manager.dart:399-400`) | `StreamingRenderQueue` with per-frame pacing |

**Real bug in their code worth flagging:** `Glass.connect()` always calls `startHeartbeat()`, the old `Timer.periodic` is only cancelled in `disconnect()`. Each reconnect leaks a heartbeat timer. A flapping link will accumulate parallel timers — exactly the failure mode our reconnect-pacing work fixed.

**Firmware quirk worth verifying on our side** (`bluetooth_manager.dart:838-844`):
```
setMicrophone() sends to the right glass only —
"for an unknown issue the microphone will not close when sent to the left side"
```
We do not currently have similar handling and may have the same latent bug; worth a small spike when next touching the mic code.

### Mode / gesture model — fundamentally different shape

**They have no app-level modes.** No Glance, Navigate, Chat, Capture, QuickNote concept. Every feature is a dashboard widget pushed via `0x1E`, plus voice-triggered one-shot screens. No `F5 20` mode-switch, no tilt-up handling, no double-tap handling, no long-press-right/left as gestures (they only consume `F5 02/03` head-up/down, `F5 23/24` Even-AI start/stop, and route the firmware-native QuickNote audio differently — see below).

**One-line summary of the intent difference:**
- Fahrplan right-hold: firmware QuickNote → LC3 → Whisper → **command-router**.
- Us right-hold: firmware QuickNote → LC3 → Whisper → **GPT tidy → classifier → notes store**.

Same firmware primitive, opposite consumer. They use the long-press to issue commands; we use it to capture a thought.

**Left-hold (`F5 23/24` Even-AI):** they pipe transcript → **Home Assistant `/api/conversation/process`** → `sendText()` (`bluetooth_reciever.dart:130-157`). Very opinionated — they assume you run HA. We use OpenAI ChatGPT.

### Render pipeline — equivalent at `0x4E`, big gap at `0x1E`

**`0x4E` text wall** (`bluetooth_manager.dart:432-505`). Custom binary-search line-wrapping with space-break preference. `MAX_CHUNK_SIZE = 176`, `LINES_PER_SCREEN = 5`, `screenStatus = 0x71`. Same exact constants as MentraOS. Multi-page supported, 5-second default between pages. Symbol substitution (`⬆ → ^`, `⟶ → -`) only in line wrapping; emoji map (`utils/emoji.dart`, ~120 mappings) only applied on the notification path. **The emoji policy is inconsistent across send paths** — same issue we should make explicit in our codebase.

**`0x52` streaming** — not used. They have no streaming-assistant pipeline.

**`0x4B` NCS notifications** — used, but `notifyId = 1` hardcoded, so collisions clobber. We track distinct IDs.

**`0x1E` dashboard widgets — this is the big one.** Models in `models/g1/note.dart:18-107`. They serialise every "widget" (calendar today, waypoints, checklists, Träwelling, Home Assistant, custom WebViews) into up to 4 native dashboard-notes slots and push them on the 1-minute sync tick. Their `Note.buildAddCommand()` and `buildDeleteCommand()` are a complete reference for an opcode we currently have only as a backlog item with zero implementation.

**`0x0A` navigation** — full implementation including 136×136 primary turn icon + 488×136 secondary route map, run-length encoded, chunked at 185 bytes with 8 ms pacing. We do directions-only via `0x0a` card protocol; their bitmap path is something we could borrow if we ever want on-glasses turn icons.

**`0x06 0x01` time-and-weather** (`models/g1/time_weather.dart:158-185`). They push time **plus weather icon + temp + 12/24h flag** in the same packet. We push time only. One-line extension on our side and we get weather on the firmware's native dashboard slot.

**Translate-mode opcodes** (`models/g1/translate.dart`): `0x39` setup, `0x50 06 00 00 01 01` start, `0x1C` language pair, `0x0F` original text, `0x0D` translated text. A complete firmware translate-overlay UI we don't use at all. Live two-line transcription UX could be reused for transcription mode even outside translation.

### Voice / STT / wake words — their strongest area

**Wake-word on the GLASSES mic, not the phone mic.** This is the architectural insight worth borrowing on its own. They put the glasses into `F5 02` wake-word mode (`bluetooth_reciever.dart:108-110`), LC3 frames stream in via `0xF1`, a `VoiceDataCollector` runs a 1-second tick that decodes LC3 → PCM → in-memory WAV → wake-word detector. Battery cost is on the glasses (designed for it); no `AudioRecord` permission churn on the phone; decoupled from foreground service.

**Two engines, pluggable factory** (`utils/wakeword_engine.dart:29-46`):
- **Porcupine** — paid-tier access key, ships `okay-glass.ppn` keyword file.
- **Snowboy** — free, `.pmdl` model. Notable detail: they inject the last 2 PCM samples as context (lines 218-243) to avoid wake words straddling tick boundaries.

**Three STT providers** (`whisper.dart:15-29`):
- **Local whisper-ggml** — VAD via RMS threshold 0.015, 800ms silence commits a chunk, 2-second overlap buffer between chunks, smart-merge of overlapping transcripts.
- **OpenAI-compatible remote** — any `/v1/audio/transcriptions` endpoint, plus a websocket variant with a fake-large WAV header trick.
- **Azure Speech via self-hosted bridge** — phone connects via websocket to a small Node bridge they ship (`azure-bridge-server/`, Dockerfile included) which holds the Azure subscription key and runs the Azure Speech SDK (no Dart binding exists). Partial + final results stream back as JSON.

**PTT + always-listening coexist.** `F5 23` PTT explicitly disables wake-word capture (`bluetooth_reciever.dart:118-122`).

**Anti-pattern:** WAV-header construction duplicated **five times** across `whisper.dart` and once more in `bluetooth_reciever.dart`. Worth abstracting if we borrow any of this.

### Assistant / LLM integration — no generative Chat, deterministic router only

The LLM service (`lib/services/llm_service.dart`, 160 lines) has exactly two methods:
1. **`matchCommand()`** — system prompt at line 113: _"You are a voice assistant only returning the number of the best matching query."_ Returns the best-match index or `NO_MATCH`.
2. **`summaryGen()`** — compresses a user utterance to a 20-char label.

There is no generative-chat path. **Their LLM does command intent classification, not conversation.** They invert our setup — we use GPT to generate answers; they use it as a tiebreaker.

**This is exactly our Router v1, fully built.** The architecture:

- `lib/voice/module.dart`: `VoiceModule(name, commands)` and `VoiceCommand(description, triggerPhrases, execute(inputText))` + an `endCommand()` hook that clears the screen after 5 seconds.
- `lib/voice/voicecontrol.dart:36-42`: registers modules (`Checklist`, `WebView`, `Waypoint`, `Stop`, `Music`).
- Match algorithm (`_findBestCommand`, lines 163-209): for each trigger phrase, run `ratio`, `partialRatio`, `tokenSortRatio`, `tokenSetRatio` from `fuzzywuzzy`, take max, accept ≥ 60 with longest-phrase tiebreak. If `mode == 'llm'`, pass the full command list to the LLM and use its index — **falling back to fuzzy if the LLM returns NO_MATCH or a garbage index**.

This pattern maps almost 1:1 onto our backlogged Calendar/Notes/Media handlers. Polarity flip: we'd keep generative chat as the no-match fallback (their version doesn't have generative chat at all).

**Music module detail worth knowing** (`main.dart:58-73` + `modules/music.dart`): they spin up an empty `MyAudioHandler` via `AudioService.init()` and immediately call `play()` on it — this registers Fahrplan as a media-controller participant, which is what gives `FlutterMediaController` system-level access to read/manipulate other apps' media sessions. Without this trick, system media APIs would be locked out. We'll need this when we implement the Router `MediaHandler`.

### Feature parity check against our roadmap

| Our backlogged feature | fahrplan equivalent |
|---|---|
| **Capture v2 — recording HUD, safer stop, recordings list** | None. No tilt-up gesture, no recording mode. They consume firmware QuickNote as a voice trigger only |
| **Router v1 — `glance` trigger + Calendar/Notes/Media** | **Fully built**, including LLM-as-tiebreaker. Reference implementation. See above |
| **Router v1 Chat history logging** | No equivalent (no Chat surface to log into) |
| **Shazam song-ID** | Not present. They can read media-session metadata for "what's playing" but no acoustic fingerprint |
| **Terminal Mode** | Not present, not relevant — they have nothing comparable |
| **Bonus: dashboard widgets** (currently `dashboard-injection` and `quicknote-dashboard-push` in our backlog) | **Fully built** via `0x1E`. Reference implementation. See Render section |

### Notable patterns and anti-patterns

**Worth borrowing:**
- VoiceModule registry + fuzzy/LLM router (Router v1 reference).
- Multi-engine factory pattern (`WakeWordDetector.create()`, `WhisperService.service()`) for pluggable STT and wake-word backends.
- **Gadgetbridge weather broadcast intake** (`services/weather_broadcast_service.dart`). Zero-API-key weather: register a `BroadcastReceiver` for `nodomain.freeyourgadget.gadgetbridge.ACTION_GENERIC_WEATHER`, parse the JSON payload published by Gadgetbridge / Weather Notification / Breezy Weather. Smart.
- Background-isolate keep-alive via Kotlin lifecycle detector — kills the background Flutter engine when the activity comes up, restarts it when it goes away. Avoids Hive double-open.
- Per-command ACK completer map (`glass.dart:24, 122-158`).

**Worth avoiding:**
- Naive reconnect + heartbeat timer leak (described above).
- WAV header duplicated five times.
- **Documented whitelist UI not wired to the filter.** `lib/screens/settings/notifications_screen.dart` writes a whitelist to Hive; `bluetooth_manager.dart:697-718` never reads it. README claims "Mirror notifications from whitelisted apps"; the implementation mirrors everything. Real shipped bug — they have a documented feature that doesn't exist. Easy mistake to make. Our `notification_policy.dart` actually does what its UI claims.
- Two god-classes carrying most logic.
- Inconsistent emoji-policy across send paths.

---

---

## MentraOS — focused G1-file inspection

Full MentraOS analysis is deferred (1.4 GB, multi-stack monorepo). This section is a targeted scan of the four G1-specific files that live under `mobile/modules/bluetooth-sdk/`. Citations are accurate as of 2026-05-18.

### Files reviewed

| File | Lines | Role |
|---|---|---|
| `android/src/main/java/com/mentra/bluetoothsdk/sgcs/G1.java` | 3974 | Android G1 BLE handler, packet construction, gesture parsing |
| `ios/Source/sgcs/G1.swift` | 2505 | iOS G1 BLE handler |
| `android/src/main/java/com/mentra/bluetoothsdk/utils/G1Text.kt` | 436 | Pixel-aware text wrapping and `0x4E` chunking |
| `ios/Source/utils/G1Text.swift` | 2067 | iOS text layout — not read in detail this pass |

### Heartbeat — three different shapes within one project

This is striking. MentraOS uses different heartbeat formats across platforms, and a much slower cadence than either us or the official app.

**Cadence:** `HEARTBEAT_INTERVAL_MS = 15000` (15 s, `G1.java:117`). Slower than the official app's 8 s steady state, and **7.5× slower than our 2 s**. They schedule the first one 10 s after connect (`G1.java:715`).

**Android payload (6 bytes, `G1.java:2391-2400`):**
```java
buffer.put((byte) 0x25);
buffer.put((byte) 6);
buffer.put((byte) (currentSeq & 0xFF));
buffer.put((byte) 0x00);
buffer.put((byte) 0x04);
buffer.put((byte) (currentSeq++ & 0xFF));
// On wire: 25 06 <seq> 00 04 <seq>
```

Note the byte positions: counter at byte 2, then `00 04`, then counter repeated. **Our app (and the official app) put the counter at byte 3:** `25 06 00 <seq> 04 <seq>`. The differing byte order suggests one of:
1. The firmware tolerates either ordering (length field is just `06` at byte 1, and the rest is informational)
2. MentraOS has a long-standing bug nobody noticed because heartbeats are best-effort
3. Two valid framings exist in firmware

Worth a small experiment on-device if we ever care, but currently nobody is forcing us to.

**iOS payload (just 2 bytes, `G1.swift:1481-1482`):**
```swift
heartbeatData.append(Commands.BLE_REQ_HEARTBEAT.rawValue)  // 0x25
heartbeatData.append(UInt8(heartbeatCounter & 0xFF))
// On wire: 25 <seq>
```

**Two bytes.** No length field, no marker. The firmware apparently accepts this minimal form too. iOS verifies the counter echo on the response: `handleAck(from: peripheral, success: data[1] == heartbeatCounter - 1)` (`G1.swift:1192`) — they expect the firmware to mirror back `(counter - 1)` because the local counter has already incremented.

**Implication for us:** the 6-byte format isn't load-bearing; the firmware accepts shorter packets. We do not need to change ours, but we should not assume the 6-byte shape is mandatory if we ever investigate firmware behaviour.

### Heartbeat — robustness patterns worth borrowing

1. **No retry on heartbeat write failure** (`G1.swift:1040`):
   > _"for heartbeats, don't retry and assume success since the glasses don't respond"_

   Heartbeats are best-effort transport probes; queueing retries pollutes the send queue and amplifies failure. We should adopt this — check if `BleManager.request` currently retries heartbeats and suppress.

2. **Counter echo verification** (`G1.swift:1192`). They verify the firmware echoes the counter back. Our ACK check (`proto.dart`) only validates `data[0]==0x25 && data[4]==0x04` — we don't verify the counter at all. Tightening this would catch a class of firmware confusion (wrong glass replying, stale packets) we'd otherwise miss.

3. **Counter wrap at 255 in iOS** (`G1.swift:1715-1719`):
   ```swift
   if heartbeatCounter < 255 {
       heartbeatCounter += 1
   } else {
       heartbeatCounter = 0
   }
   ```
   This wraps at 256 (values 0..255), matching the firmware's expected single-byte rollover. Confirms our recent `& 0xff` fix is in line with at least one other implementation.

4. **Battery query every 10 heartbeats** (both platforms — `G1.java:2589`, `G1.swift:1491`). We could adopt the same pattern instead of polling battery on a separate timer.

### `0x4E` text rendering — pixel-aware wrapping and a font table 

`G1Text.kt` is the most actionable find in the whole comparison. They have:

**A hardcoded per-glyph pixel-width font table** (`G1Text.kt:279-419`). ~120 glyphs with exact pixel-width values, including Latin-1 accented characters (À, Ç, É, Ä, Ö, ẞ, ß, Ñ, Í, ñ, ó, ú …) — _French, German, Spanish are all in there._

This contradicts our existing memory ([[g1-firmware-font-ascii-only]]) which says "Unicode symbols don't render on the glasses; use plain ASCII". Refined position: **the G1 firmware font is mostly ASCII plus a known set of Latin-1+ accented characters.** The G1 cannot render arbitrary symbols (`▶`, `⬆`), but it can render Western European text correctly. Worth updating the memory.

They also do **explicit symbol-to-ASCII replacement** before wrapping (`G1Text.kt:52`):
```kotlin
val processedText = text.replace("⬆", "^").replace("⟶", "-")
```

**Pixel-aware line wrapping** (`G1Text.kt:50-138`). Binary search on substring widths to find the maximum characters that fit in the display width, with word-boundary preference (looks for a space to break at, falls back to character-position split if no space within range). Replaces character-count-based wrapping with pixel-precise wrapping. **This is the single highest-value pattern in the whole MentraOS scan for us** — directly applicable to anywhere we render `0x4E` content of variable length (Glance carousel, QuickNote previews, Router handler output, Capture HUD).

**`0x4E` packet header — 9 bytes documented in code** (`G1Text.kt:185-195`):
```
[0]: 0x4E (TEXT_COMMAND)
[1]: textSeqNum
[2]: totalChunks
[3]: i (current chunk index)
[4]: screenStatus = 0x71  (new content 0x01 + text show 0x70)
[5]: new_char_pos0 (high byte)
[6]: new_char_pos1 (low byte)
[7]: page (current page index)
[8]: totalPages
```

`screenStatus = 0x71` is documented explicitly: `0x01` (new content) bit-OR `0x70` (text show). We use this opcode but don't currently document the bit composition in `protocol-reference.md` — worth folding in.

**Constants worth noting:**
- `DISPLAY_WIDTH = 488` (matches ours)
- `LINES_PER_SCREEN = 5`
- `MAX_CHUNK_SIZE = 176` for BLE chunking
- `totalPages` is supported by the protocol but hardcoded to 1 in their current code — multi-page text rendering is unused. Could matter for our Recordings List or longer Chat responses.

### Gestures — F5 catalogue from MentraOS

Their F5 handler (`G1.java:531-606`) catalogues:

| F5 sub-code | Meaning | Notes |
|---|---|---|
| `F5 02` | Head up | Only consumed from `R_` side |
| `F5 03` | Head down | Only consumed from `R_` side |
| `F5 00` / `F5 20` | Double tap | **Commented out** — "appears to be completely broken — clears the screen — we should not tell people to use the touchpads yet til this is fixed" |
| `F5 06` / `F5 07` | Case removed | Two sub-codes both mean removed |
| `F5 08` | Case open | |
| `F5 0B` | Case closed | |
| `F5 0E` | Case charging status | byte 2 = charging flag |
| `F5 0F` | Case charging info | byte 2 = case battery level |

**Things we knew but they confirm:** F5 02/03 only need to be handled on the R_ side.

**Things they don't have but we do:** `F5 04` (long-press right) and `F5 05` (long-press left) — we built QuickNote and Quick Ask on these gestures. Not in their handler at all. Likely opportunity-cost choice on their side.

**Things they have but we may not catalogue:** the case lifecycle opcodes (`F5 06/07/08/0B/0E/0F`). We could light up:
- "Glasses are in their case" — suppress notifications when in case
- "Case charging level" — show case battery alongside glasses battery
- "Glasses removed from case" — could trigger a Glance HUD "Welcome back" prompt

**Their double-tap status is a clean validation of our work.** They explicitly know `0x18` clears the screen and have given up on the touchpad as a result. We discovered the `0x50 + 0x18` combo (close mode then exit) avoids the ghost-screen. **Our fix is better than theirs** — they're shipping with the touchpad effectively disabled because of the same bug we resolved. See [[0x18-ghost-screen]] memory.

### Mic-beat — separate from BLE heartbeat

`G1.java:2430` has `startMicBeat(int delay)` — _"periodically send a mic ON request so it never turns off"_. This is a different keepalive from the BLE heartbeat: a separate periodic write to keep the microphone in "always-on" state during recording sessions. Relevant for our Capture and QuickNote flows — if the firmware turns the mic off mid-capture, a mic-beat would catch it. Worth investigating whether our current Capture pipeline has any analogous problem.

### Battery query opcode

`constructBatteryLevelQuery()` (`G1.java:2402-2407`):
```java
buffer.put((byte) 0x2C); // Command
buffer.put((byte) 0x01); // use 0x02 for iOS  -- this comment is interesting
```

Response shape: `2C 66 <level>` (`G1.java:558`). Per-leg battery is tracked separately, min of the two is reported as combined glasses level. The `0x01` vs `0x02` sub-byte distinction by platform suggests there may be format differences we don't yet have documented. Worth a brief check against our protocol reference.

### Headline takeaways from MentraOS for the comparison

| Pattern | Effort to adopt | Value |
|---|---|---|
| **Pixel-aware line wrapping with per-glyph widths** | Medium (port font table + binary search wrapper) | High — applies to every text render path |
| **Heartbeat retry suppression** | Low (one conditional in `BleManager.request`) | Medium — clean up failure-mode logic |
| **Heartbeat counter echo verification** | Low (extend ACK check in `proto.dart:209`) | Low–Medium — defence against wrong-glass replies |
| **Case lifecycle opcodes (`F5 06/07/08/0B/0E/0F`)** | Medium (new handlers, UI surfaces) | Medium — enables in-case behaviour and case-battery display |
| **Mic-beat for sustained recording** | Medium (separate periodic timer in Capture) | Conditional — only if we observe mic dropouts |
| **Document `0x4E` header bit composition** in `protocol-reference.md` | Low (docs edit) | Low — protocol clarity |
| **Update G1 firmware-font memory** to reflect Latin-1+ accented support | Low (memory update) | Low–Medium — unblocks French/German/Spanish text handling correctly |

### Things we do better than MentraOS

1. **`0x50 + 0x18` ghost-screen fix.** They have the bug; we shipped the fix.
2. **Long-press gestures (`F5 04 / 05`).** They don't use them; we built QuickNote and Quick Ask on top.
3. **Heartbeat cadence calibrated against HCI captures.** They picked 15 s with no documented rationale; we picked 2 s after a multi-log analysis with clear empirical reconnect-stability win.

---

---

## Cross-app synthesis

### Themes that appear in multiple apps

When two unrelated teams independently arrive at the same architectural choice, that's signal. Three patterns are convergent across the apps reviewed:

1. **Pixel-aware line wrapping has won.** Both MentraOS (`G1Text.kt`) and fahrplan (`bluetooth_manager.dart:513-600`) abandoned character-count wrapping in favour of width-aware wrapping with space-break preference. MentraOS goes further with a hardcoded per-glyph font table; fahrplan estimates widths arithmetically. Either way, char-count wrapping is the deprecated pattern.

2. **Deterministic command router with optional LLM tiebreak.** fahrplan ships exactly the architecture our Router v1 backlog describes. openclaw-glasses ships a thinner version (wake-word → single one-shot LLM, no command palette). The "deterministic-handlers-then-LLM-fallback" shape is the consensus answer; we should pick our handler interface deliberately and not invent it.

3. **Wake-word lives on the glasses mic, not the phone mic.** fahrplan's choice to use `F5 02` glasses-mic mode for wake-word capture is architecturally cleaner than any phone-side always-listening we'd otherwise build (battery on glasses, no `AudioRecord` permission, decoupled from foreground service). MentraOS's `STTTools.kt` + `SherpaOnnxTranscriber.kt` + `VadGateSpeechPolicy.kt` stack on the Android side suggests the same direction (not deeply audited this pass). openclaw-glasses delegates this to MentraOS entirely.

### Where we lead

Validation of existing work — these are areas where the comparison showed our choices are better than all three reviewed apps, and we should not churn-rewrite anything based on cosmetic differences:

| Pattern | vs MentraOS | vs fahrplan | vs openclaw-glasses |
|---|---|---|---|
| **Heartbeat cadence + ACK validation** | They use 15 s on Android, 2-byte payload on iOS; we use 2 s with shape-validated ACK | They use 5 s fire-and-forget; we validate echo | n/a (MentraOS handles) |
| **Reconnect strategy** | Comparable on Android; not as good as our backoff + cooldown | Materially worse — immediate retry, no cap, leaks timers | n/a |
| **`0x50 + 0x18` ghost-screen fix** | They hit the bug and disabled their touchpad as a result | They don't encounter the bug (no mode lifecycle) | n/a |
| **Service decomposition** | n/a | 34 services vs their 3 god-classes; ours is more maintainable | n/a |
| **`StreamingRenderQueue` (per-frame paced 0x52)** | n/a | They have no streaming pipeline at all | n/a |
| **Notification policy actually enforced** | n/a | Their whitelist UI is documented but **not wired** — real shipped bug | n/a |
| **Long-press gestures (`F5 04 / 05`)** | Not used | Not used | n/a |

### Candidate backlog items

Grouped by theme. **Not yet pushed to the worklist.** Surfaced in the chat summary for explicit go/no-go before backlog grooming.

Format: title — source app(s) — effort — value — dependencies.

#### A. Enhancements to existing backlog items

1. **Router v1 — port fahrplan's `VoiceModule` registry pattern.** fahrplan — _medium_ — _high_ — pairs with existing `router-v1-glance-handlers`. Adopt their `VoiceModule(name, commands)` and `VoiceCommand(description, triggerPhrases, execute(inputText))` interface, including the `endCommand()` 5-second auto-clear hook. Use `fuzzywuzzy` for `ratio`/`partialRatio`/`tokenSortRatio`/`tokenSetRatio` scoring with ≥ 60 acceptance + longest-phrase tiebreak. Keep our generative chat as the no-match fallback (inverse polarity to theirs).

2. **Router v1 — STT noise filter at the trigger boundary.** openclaw-glasses — _low_ — _medium_ — pairs with existing `router-v1-glance-handlers`. Drop utterances <500 ms duration or mean STT confidence <0.85 before any trigger or handler-keyword matching. ~20 lines of Dart. Belongs in our QuickAsk/Router wake path regardless of which STT backend.

3. **Dashboard injection (`0x1E`) — promote from backlog to Next with concrete first widget.** fahrplan — _medium_ — _high_ — supersedes existing `dashboard-injection` backlog item (currently Parked for lack of a use case). fahrplan's `models/g1/note.dart:18-107` is a complete byte-format reference. Build `DashboardNote` + `DashboardComposer` (gathers up to 4 typed widgets) + 60 s sync timer. Suggested initial widgets: today's calendar + system status. Also unblocks downstream items.

4. **`0x06 0x01` extend with weather icon + temp.** fahrplan — _low (one-liner)_ — _low–medium_ — pairs with item 3. fahrplan's `models/g1/time_weather.dart:158-185` documents the extended payload. Surfaces weather on the firmware's native dashboard slot. Depends on having weather data available (so trails item 8).

5. **Update [[g1-firmware-font-ascii-only]] memory.** MentraOS — _trivial_ — _low–medium_ — refined claim: G1 firmware font is ASCII plus a documented set of Latin-1+ accented characters (French, German, Spanish all render). Arbitrary Unicode symbols (▶ ⬆) still don't render. Unblocks proper handling of European-language notifications. Already flagged earlier; needs your sign-off.

6. **Document `0x4E` header bit composition in `protocol-reference.md`.** MentraOS — _low_ — _low_ — `screenStatus = 0x71 = 0x01 new-content | 0x70 text-show`, and the full 9-byte header layout. Pure docs cleanup.

#### B. New items

7. **Pixel-aware `0x4E` line wrapping with per-glyph font table.** MentraOS — _medium_ — _high_ — port the ~120-glyph font table from `G1Text.kt:279-419` (or rebuild from fahrplan's arithmetic estimator, less accurate but cheaper) and replace any char-count wrapping in our codebase with binary-search width wrapping with space-break preference. Applies to Glance carousel, QuickNote, Router output, Capture HUD, anywhere `0x4E` content has variable length. Likely affects multiple service files.

8. **Wake-word on glasses mic (Snowboy first).** fahrplan — _medium–large_ — _medium_ — new feature. Arms the glasses into `F5 02` mode; LC3 frames stream in via `0xF1`; 1-second tick decodes to PCM → in-memory WAV → Snowboy (free) detector; positive detection hands off to the Router. fahrplan's `bluetooth_reciever.dart:280-388` is the LC3 collector reference. Settings dial for "armed listening" mode. Ship Snowboy first; Porcupine as opt-in later (paid).

9. **Multi-provider STT factory.** fahrplan — _medium_ — _medium_ — abstract a `STTProvider` interface, factory at startup based on settings. Initial concrete providers: OpenAI Whisper (existing), local whisper-ggml (new — fahrplan's reference impl). Azure Speech is third-tier (needs the bridge server they ship). Useful for privacy / cost / offline.

10. **Gadgetbridge weather broadcast receiver.** fahrplan — _low_ — _low–medium_ — depends on item 3 having a weather widget surface. `BroadcastReceiver` for `nodomain.freeyourgadget.gadgetbridge.ACTION_GENERIC_WEATHER`, parse JSON, feed dashboard. Zero API keys.

11. **Case lifecycle opcodes (`F5 06/07/08/0B/0E/0F`).** MentraOS — _medium_ — _medium_ — new handlers for case removed / open / closed / charging status / case battery level. Enables in-case notification suppression, case-battery display, "welcome back" Glance flash on case-open. UX-decision-heavy.

12. **Terminal Mode v0 — laptop-tethered local-IPC spike.** openclaw-glasses — _half-day spike_ — _gating_ — investigation only. Discover whether Claude Code exposes a local IPC endpoint (UNIX socket, named pipe, `--port` flag, file tail, SDK local server). If yes, sketch a `Terminal Mode v0` shape that skips Happy + crypto. If no, the idea collapses and Happy remains the only path.

#### C. Low-effort hardening (already flagged earlier in the doc)

13. **Heartbeat retry suppression** — MentraOS — _trivial_ — `BleManager.request` should not queue retries for heartbeats. One conditional.

14. **Heartbeat counter echo verification** — MentraOS — _low_ — extend our ACK check (`proto.dart:209-211`) to verify the firmware echoes the counter byte. Catches wrong-glass replies and stale packets.

15. **Microphone-right-side firmware-quirk check** — fahrplan — _quick spike_ — fahrplan sends `setMicrophone()` to the right glass only because the mic doesn't close when sent to the left. Worth a spike to check whether we have the same latent quirk and don't know it.

#### D. Watch items (do not act yet)

- **MicBeat for sustained recording** (MentraOS). Only if we observe mic dropouts during Capture. We don't currently.
- **Translate-mode opcodes** (fahrplan — `0x39/0x50/0x1C/0x0F/0x0D`). Live two-line transcribe UX. No current product driver.
- **On-glasses navigation bitmap rendering** (fahrplan — primary turn icon 136×136 + secondary route map 488×136). Our `0x0a` card protocol works; this is upgrade territory only if we want richer nav rendering.

### Suggested next session

If MentraOS gets its own dedicated review session later, prioritised areas:
- `STTTools.kt` + `SherpaOnnxTranscriber.kt` + `VadGateSpeechPolicy.kt` — their on-device STT + VAD stack. Counter-point to fahrplan's whisper-ggml choice.
- `Bridge.kt` / `BluetoothSdkModule.kt` — the RN bridge layer, to understand how MentraOS exposes its abstractions and what we'd gain/lose by adopting their primitives instead of building our own.
- `services/Foreground.kt` — their foreground-service shape vs ours.
- `docs/` folder at the root — likely has architectural documentation we haven't read.

### Methodology note

This analysis was conducted in a single session on 2026-05-18 via:
- One sub-agent (`general-purpose`) on fahrplan, with self-contained brief covering our baseline + roadmap (full report at ~3500 words);
- One sub-agent (`general-purpose`) on openclaw-glasses with a focused Terminal-Mode-shortcut brief (full report at ~3000 words);
- Direct targeted reads of four MentraOS G1-specific files (~9000 lines combined), with `Grep` triage before `Read`.

All file citations in this document are exact at the time of writing. Confidence is high on patterns described (verified against source) and lower on inferred motivations (where a sub-agent reasoned about *why* a choice was made — these are clearly marked as inference where they appear).
