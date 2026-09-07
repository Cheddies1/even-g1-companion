# Historical ticket: `hermes-api-tailscale-bind` — expose Hermes API to the tailnet

> **Retired 2026-09-02, archived 2026-09-07.** Hermes, OpenWebUI and their local state were permanently deleted from `deepthought` (the box itself is very much alive - it now runs Ollama, T3 Code and the local OpenCode provider). The app-side route was removed by `hermes-dewire-chat` on 2026-09-07. This is a dated implementation record only: do not follow its commands, and do not treat the endpoint or the `AssistantBackendKind` enum it describes as existing.

**Goal:** Make the Hermes OpenAI-compatible API reachable from Eddie's phone over Tailscale, so the Even Companion app can route Quick Ask reasoning to `http://deepthought:8642/v1`. **Blocks** the app-side `hermes-agent-v1` item (already code-complete, pending this).

> Cross-repo handoff doc. The change lives in `~/.hermes/` (different repo / worklist), not in EvenDemoApp. This file is kept here only as a record of the blocking dependency.

## Problem

Hermes runs in a host-network Docker container and the API server currently binds to loopback only. OpenWebUI works **because it shares the host's network namespace and hits `127.0.0.1:8642`** — that is a different reachability path from the phone, which arrives over the `tailscale0` interface. Verified live:

- `127.0.0.1:8642/health` → **200** ✓ (loopback works)
- `100.120.15.61:8642/health` (the Tailscale IP) → **000, unreachable** ✗

So "infrastructure is ready" is true for OpenWebUI and **not** true for the glasses. The phone cannot reach Hermes today. This must land before the app feature can be verified on-device.

## The change

In `~/.hermes/config.yaml`, bind the API server to an address the tailnet can reach, then restart:

```yaml
# ~/.hermes/config.yaml
API_SERVER_HOST: 100.120.15.61      # Tailscale IP of deepthought
```
```bash
systemctl --user restart hermes-gateway
```

Plain HTTP is fine here: the tailnet is already WireGuard-encrypted, so the bearer token rides an encrypted transport without needing `tailscale serve` / a TLS proxy. Binding to the specific Tailscale IP (not `0.0.0.0`) keeps it off the LAN and public interfaces, so no UFW rule is required.

## ⚠️ The one decision to make: don't break OpenWebUI

If the server binds **only** to `100.120.15.61`, it stops listening on `127.0.0.1` — and **OpenWebUI's `127.0.0.1:8642` path breaks.** Pick one:

- **Option A (recommended): bind to the Tailscale IP, repoint OpenWebUI.** Since OpenWebUI is on the same box, change its Hermes endpoint from `127.0.0.1:8642` to `http://deepthought:8642` (MagicDNS) or `100.120.15.61:8642`. One bind address, no firewall change, both clients use the same path. MagicDNS is already proven on this tailnet (the laptop reaches `http://deepthought:8080`).
- **Option B: bind `0.0.0.0` + firewall.** Keeps loopback working untouched, but now listens on every interface — so add a UFW rule allowing `8642` **in on `tailscale0` only** and denying it elsewhere. More moving parts; only choose this if repointing OpenWebUI is awkward.

If `API_SERVER_HOST` accepts a list of bind addresses, binding both `127.0.0.1` and `100.120.15.61` is the cleanest of all — check whether the Hermes config supports that before falling back to A or B.

## Contract the app depends on

The app (`ChatBackendRouter` + `OpenAiChatBackend`) will hit, with base URL `http://deepthought:8642/v1`:

| Call | Method | Auth | Notes |
|---|---|---|---|
| `/v1/health` | `GET` | **none** | Reachability probe, 3s timeout. App treats *any* HTTP response (incl. 404) as "reachable"; only a transport failure (refused/DNS/timeout) means "unreachable → fall back to OpenAI". Keep it 200 + unauthenticated if you can. |
| `/v1/chat/completions` | `POST` | `Authorization: Bearer <API_SERVER_KEY>` | OpenAI-compatible. App sends `model`, `messages` (system + turns), `max_completion_tokens`, `stream: true`. Must return SSE `data:` lines with `choices[].delta.content`. |

- **Model id:** the app defaults to `hermes-agent`. Confirm that's the served model name (or tell me what to set it to).
- **Bearer:** the app pastes `API_SERVER_KEY` (from `~/.hermes/config.yaml`, ~line 560) into a secure-storage field. Static shared secret, fine for single-user homelab over the tailnet.
- **Streaming:** the app streams the reply token-by-token onto the glasses. A non-streaming-only endpoint would degrade UX (it has a `send()` fallback, but streaming is the primary path).
- **Timeout headroom:** the app allows up to **120s** receive timeout for Hermes (configurable) because it expects an agent tool-loop. No server change needed — just don't assume sub-second responses are required.

## Acceptance / how to verify

From the box (confirms the bind):
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://100.120.15.61:8642/v1/health   # expect 200
curl -s http://127.0.0.1:8642/...  # confirm OpenWebUI's path still works per your chosen option
```

From the phone (or any other tailnet node — confirms end-to-end reachability):
```bash
curl -s http://deepthought:8642/v1/health                                       # expect 200, no auth
curl -s http://deepthought:8642/v1/chat/completions \
  -H 'Authorization: Bearer <API_SERVER_KEY>' -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","stream":true,"messages":[{"role":"user","content":"ping"}]}'
# expect SSE data: lines with delta.content
```

**Done when:** `/v1/health` returns 200 over MagicDNS from off-box, an authenticated streaming chat call succeeds over MagicDNS, and OpenWebUI still works.

## Please feed back

- Confirmed bind option (A / B / dual-bind) and whether OpenWebUI needed repointing.
- The served **model id** (so the app default can be set correctly).
- Anything non-standard about the SSE shape or the health route, so the app's probe/parsing matches.

---

## ✅ Outcome (2026-05-27, Hermes side)

**Shipped — Option A (bind the Tailscale IP, repoint OpenWebUI).**

- **Dual-bind was checked and is NOT supported.** The server passes a single host string to one aiohttp `TCPSite` (`gateway/platforms/api_server.py`), and `is_network_accessible()` expects a scalar — there's no list/comma parsing. So it had to be A or B; chose A to keep the box's "nothing beyond loopback/tailnet" invariant with no firewall.
- **Config mechanism note:** `API_SERVER_HOST` was added as a top-level key in `~/.hermes/config.yaml` (not `.env`). The gateway bridges every top-level scalar in `config.yaml` into the process env at startup (`gateway/run.py`), which is the same path the existing `API_SERVER_KEY` already uses.

  ```yaml
  # ~/.hermes/config.yaml
  API_SERVER_HOST: 100.120.15.61   # Tailscale IP of deepthought
  ```

- **OpenWebUI repointed:** its Hermes connection lived in `webui.db` (config JSON blob, `openai.api_base_urls`), changed `http://127.0.0.1:8642/v1` → `http://deepthought:8642/v1`. Verified working after a container restart.

### Answers to the feedback asks
- **Bind option:** A. OpenWebUI needed repointing (now on `http://deepthought:8642/v1`).
- **Model id:** `hermes-agent` — matches the app default; no change needed.
- **SSE shape / health route:** standard OpenAI chunks — `choices[0].delta.content`, terminating `data: [DONE]`. `/v1/health` returns **200 unauthenticated**; `/v1/models` and `/v1/chat/completions` require the bearer. Nothing non-standard for the app's probe/parsing.

### Verified
- On-box: `100.120.15.61:8642/v1/health` → 200; `127.0.0.1:8642` → 000 (loopback intentionally closed); `deepthought:8642/v1/health` → 200; authenticated streaming chat returns `delta.content` then `[DONE]`.
- Off-box (laptop/phone over tailnet): **pending Eddie's confirmation** — `curl http://deepthought:8642/v1/health` should return 200.
