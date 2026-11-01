# Hermes ↔ CloudKit bridge: local contract verification (Task 0)

Verification date: **2026-11-01**. Target: the throwaway instance described below, plus the
`hermes-agent` checkout the local `hermes` launcher resolves to.

This document answers one question before any bridge code is written: **what can a local bridge
process actually rely on when it talks to `hermes serve` on the loopback interface?**

Every claim below carries its evidence class:

- **source** — read in the installed `hermes-agent` checkout (`bf0203a794`, `hermes --version`
  reporting `v0.22.2+3291.gbf0203a`, release 2026.9.24).
- **fixture** — pinned in `Packages/NeoCloudBridge/Tests/HermesBridgeClientTests/Fixtures/`.
- **live** — observed on a running server during this verification.

A source fact is not a live fact. The whole point of this task was to find the places where the
two differ; one of them changes the design of the bridge.

## 1. How the live check was isolated

| Item | Value |
| --- | --- |
| Command | `HERMES_HOME=/tmp/neobridge_home HERMES_DASHBOARD_SESSION_TOKEN=<local probe value> hermes serve --port 19119 --host 127.0.0.1 --skip-build` |
| Data root | `/tmp/neobridge_home` (fresh, deleted afterwards, never the user's `~/.hermes`) |
| Bind | loopback only, port 19119 (9119 was free but unused; nothing else was moved) |
| Pre-existing processes | untouched. The user's `hermes gateway run` (`127.0.0.1:55658`) was only read via `GET /api/status`; no RPC was sent to it |
| Credentials | none read from `~/.hermes`; no `.env` content was opened, copied, printed or logged |
| Probe scripts | written under `/tmp/neobridge_probe`, never in this repository |

`GET /api/status` on the isolated instance reported `version 0.22.2`, `auth_required=false`,
`gateway_mode=none`, `profiles=["default"]` — i.e. a plain loopback backend, the same shape a Mac
bridge would meet on a user's machine.

The user's own gateway answers `/api/status` but returns `401 {"detail":"Unauthorized"}` on
`/api/auth/ws-ticket` and on the `/api/ws` upgrade: it needs its own gateway credential. A bridge
must not assume that a port that answers health checks is reachable.

## 2. Transport and authentication

**live**

| Step | Result |
| --- | --- |
| `ws://127.0.0.1:19119/api/ws` (no credential) | upgrade refused, HTTP `401 {"detail":"Unauthorized"}` |
| `POST /api/auth/ws-ticket {}` on a loopback backend with `auth_required=false` | `401 {"detail":"Unauthorized"}` — the ticket route is a *gated-mode* route, not a loopback one |
| `ws://…/api/ws?token=<HERMES_DASHBOARD_SESSION_TOKEN>` | accepted, first frame is `event gateway.ready` |
| REST `GET /api/status` | `200` without a credential |

**source** (`hermes_cli/web_server_chat.py::_ws_auth_reason`, `hermes_cli/web_server.py`): the
loopback path compares `?token=` in constant time against the process's `_SESSION_TOKEN`, which is
`HERMES_DASHBOARD_SESSION_TOKEN` when that environment variable is set and otherwise a fresh random
value per process start. Gated mode additionally accepts a browser-minted single-use `?ticket=`
(30 s TTL) and a `?internal=` credential that only server-spawned sockets get. A
`X-Hermes-Gateway-Ticket` header is refused on `/api/ws` by design.

**Consequence for the bridge.** Local credentials are a *process* fact, not a stable configuration
value. The bridge stores the endpoint plus the user's password/session token in the Mac Keychain,
obtains a `X-Hermes-Session-Token` per launch, and re-establishes it after a backend restart. A
token that survives is a convenience, never an assumption.

## 3. The capability negotiation frame

**live / fixture** — `client.capabilities {server_requests: true}`:

```json
{"server_requests": ["approval","clarify","display.install.sudo","preview.act","preview.read",
 "secret","setup_beat","sudo","terminal.read","theme.apply","theme.pick","tour","vault.code",
 "vault.save_login","vault.unlock_prompt","window.read"],
 "declines_not_shown": true}
```

This is the declaration that makes Hermes send interactive requests at all: without it the backend
treats the socket as a client that predates server→client requests and withdraws approvals instead
of asking. The bridge declares it (so it can *see* a request and report `waitingOnMac`) — declaring
it is not approving anything.

`ping` replies `{"pong":true}`.

## 4. Session identity

**live**

| Observation | Evidence |
| --- | --- |
| `session.create {profile:"default"}` → `{session_id:"c00c4099", stored_session_id:"20261101_133428_6c5569", message_count, messages, info}` | `session_create.json` |
| `session.resume {session_id:"20261101_133428_6c5569"}` (stored id) → `session_id:"c00c4099"` | `session_resume_by_stored_id.json` |
| `session.resume {session_id:"c00c4099"}` (runtime id) → `{"code":4007,"message":"session not found"}` | `error_session_not_found.json` |
| After killing and restarting the backend, resuming the **same stored id** returned a **different** runtime id (`d53435de`) with `message_count:1` | live, restart probe |

**source** (`tui_gateway/contracts/sessions.py`): "`session_id` is the STORED id (or an exact
title); the reply's `session_id` is the runtime id."

**Consequence.** The bridge's durable conversation key is the **stored** session id. A runtime id is
a per-process handle: it must never be written as the conversation's identity, and every reconnect
re-resolves the stored id before submitting.

## 5. Durable input identity and admission lookup — the finding that changes the design

The checkout *declares* exactly the primitives a bridge would want, in
`tui_gateway/contracts/canonical.py`:

```python
class PromptReceiptParams(Params):
    session_id: str
    admission_id: str
    include_result: bool | None = None
# AdmissionStatus.status: "queued" | "started" | "unknown" | "terminal"
canonical_method("prompt.receipt", …)
canonical_method("prompt.cancel", …)
canonical_method("prompt.resolve_unknown", …)
```

with the comment that these are "canonical `hermes-gateway-v1` methods that only the session
authority serves" — `gateway/session_controls.py::AuthorityConnection.dispatch` — while "the TUI
sidecar (`server._methods`) never registers them". `/api/ws` is the sidecar.

**live** — on the same instance:

| Method | Reply |
| --- | --- |
| `runtime.describe` | `-32601 unknown method` |
| `prompt.receipt` | `-32601 unknown method` |
| `prompt.cancel` | `-32601 unknown method` |
| `prompt.resolve_unknown` | `-32601 unknown method` |
| `session.mutate` | `-32601 unknown method` |

(`error_unknown_method.json`.)

And the accepted submit carries no durable identity at all:

**live / fixture** — `prompt.submit {session_id, text:"…"}` → `{"status":"streaming","user_row_id":3}`.
There is no `admission_id`, no `input_id`, no idempotency key. `user_row_id` is a database row
number, not a delivery receipt.

**Therefore, for this build:**

| Question | Answer |
| --- | --- |
| Can the bridge name an input before sending it? | No. Nothing on the wire carries a client-chosen input identity. |
| Can it ask later whether an input was executed? | No. `prompt.receipt` does not exist on this transport. |
| Can it cancel a *queued* admission? | No. `prompt.cancel` does not exist; only `session.interrupt` (a running turn) does. |
| What must a post-send ambiguity become? | `uncertain`. Never an automatic resubmit. |

This is the plan's `uncertain` downgrade (§5.4 point 5), now backed by a live negative result
rather than an assumption. Source availability of an admission API upstream does not make it
available here, and the bridge must probe for it instead of hard-coding either answer.

### 5.1 Why replayed text is not evidence of execution

**live** — this is the sharpest result of the verification:

1. Submitted `BRIDGE_DISAMBIGUATION_PROBE 只回复 OK` to a session with no reachable provider.
2. The turn failed: an `error` event, then `message.complete {status:"error"}`.
3. `session.history` then contained `count:1`, `roles:["user"]`, **the probe text present**, and no
   assistant row.
4. After a backend restart, the stored id still resumed with `message_count:1` and only that user row.

So a user row in the transcript proves the *text was accepted into the database*, not that the
agent ran. The bridge must never treat "my text is in the history" as proof of execution, exactly as
§5.4 point 5 requires.

## 6. Events

**live / fixture**

| Event | Payload keys observed |
| --- | --- |
| `gateway.ready` (first frame) | `type`, `payload{…, replay_epoch, change_events, heartbeat}` |
| `session.info` | model, provider, reasoning_effort, yolo, approval_mode, tools, skills, cwd, running, stored_session_id, desktop_contract, version, release_date, usage, profile_name, … |
| `session.title` | title / session_key |
| `message.start`, `thinking.delta`, `status.update` | streaming progress (no `message.delta` was emitted on the failing path) |
| `message.complete` | `text`, `usage`, `status` (`ok`/`error`), `persisted_turn`, `error`, `recoverable`, `error_surface` |
| `error` | `message` (a string, sometimes containing provider diagnostics) |
| `session.events.since` result | `events`, `latest_seq`, `truncated`, `count`, `epoch`, `open_requests` |

**source**: `seq` is scoped to a runtime session and resets after a backend restart; a changed
`epoch` invalidates the watermark. Replay returns event objects, not JSON-RPC envelopes.

**Consequence.** The bridge's typed event stream keys on `message.complete` for a terminal result,
keeps the `error` text for `errorSummary`, and treats an epoch change as "reset the watermark and
refetch state" rather than "replay from 0".

## 7. Interactive requests and interruption

**live**: `session.interrupt {session_id}` → `{"status":"interrupted"}`. The reply is a status, not
proof that the turn stopped emitting; the adapter still waits for the terminal frame.

**live**: the `client.capabilities` list above is the set of interactive methods this build can send.
`approval`, `clarify`, `sudo`, `secret` and the vault prompts are therefore *reachable*, which is why
the first cloud release must report `waitingOnMac` and offer only "stop this task" — it can see a
question and must not answer it.

**Not verified live.** No interactive request was produced during verification: the isolated profile
could not reach a provider, so no tool call could trigger one. The shape is known from the
repository's existing app code (`HermesIOS/Core/VoiceLiveProtocol.swift`,
`HermesIOS/Networking/HermesSocket.swift`, `docs/HERMES_PROTOCOL.md`) and from
`tui_gateway/contracts/server_requests.py`; the bridge's own fixture will be added with the adapter
test that exercises it.

## 8. Error semantics

| Shape | Meaning | Bridge handling |
| --- | --- | --- |
| `{-32601, "unknown method: …"}` | method not served by this build | capability probe result, not a failure to retry |
| `{4007, "session not found"}` | runtime id is stale / wrong id kind | re-resolve the stored id once, then fail the task |
| `{4001, "invalid params"}` | strict contracts: unknown keys rejected | a codec bug; never retried blindly |
| `error` event + `message.complete{status:"error"}` | the turn failed after admission | terminal `failed`, with `errorSummary` |
| HTTP `401` on `/api/status` or the upgrade | wrong/missing credential | blocked before sending: the task stays `received`, never `uncertain` |

The last row is the rule from §6 of the plan: a failure *before* an unambiguous send is a safe retry
(`received`); only an ambiguity *after* sending is `uncertain`.

## 9. What this build does **not** provide

| Wanted | Status on 0.22.2 `/api/ws` | Consequence |
| --- | --- | --- |
| client-chosen durable input id | absent | `uncertain` on post-send ambiguity |
| `prompt.receipt` / admission state query | absent (`-32601`) | no post-hoc "did it run?" answer |
| `prompt.cancel` for a queued input | absent (`-32601`) | `BridgeControl` cancel is best-effort: it prevents a *not yet dispatched* task, otherwise it calls `session.interrupt` while the turn runs |
| `runtime.describe` capability document | absent (`-32601`) | capability probing must use `client.capabilities` + `session.info.version` |
| provider reachability | environment, not protocol | a turn can fail with `error` after a successful submit — the bridge reports `failed`, it does not retry |

## 10. Evidence log

| # | Evidence | Result |
| --- | --- | --- |
| 1 | `GET /api/status` on the user's running `hermes gateway run` (`127.0.0.1:55658`) | `200`, `0.22.2`; `auth_required=false` but `/api/ws` and `/api/auth/ws-ticket` answer `401` |
| 2 | WS upgrade without credential on the isolated backend | refused (401) |
| 3 | WS upgrade with loopback token | accepted (`gateway.ready`) |
| 4 | `client.capabilities {server_requests:true}` | 16 interactive methods, `declines_not_shown:true` |
| 5 | `ping` | `{pong:true}` |
| 6 | `session.create` | runtime + stored id |
| 7 | `session.resume` by stored id / by runtime id | ok / `4007 session not found` |
| 8 | `prompt.submit` | `{status:"streaming", user_row_id}` — no durable input identity |
| 9 | turn events on an unreachable provider | `error` + `message.complete{status:"error"}` |
| 10 | `session.history` after that failure | user row persisted, no assistant row |
| 11 | backend restart, resume same stored id | new runtime id, same stored id, `message_count:1` |
| 12 | canonical methods (`prompt.receipt`, `prompt.cancel`, `prompt.resolve_unknown`, `runtime.describe`, `session.mutate`) | all `-32601` |
| 13 | `session.events.since` | `{events, latest_seq, truncated, count, epoch, open_requests}` |
| 14 | `session.interrupt` | `{status:"interrupted"}` |

## 11. Not verified, and why

| Item | Reason | Status of the requirement |
| --- | --- | --- |
| A real successful assistant turn (`只回复 OK`) | The isolated data root had no usable provider credential. The user's `~/.hermes/.env` was not read, and the credentials available to the verification shell were rejected by the provider (`HTTP 401: Invalid API Key`, with both the Anthropic and the OpenAI-compatible shapes). | **Open.** Needs one run against a profile that can reach its provider. The terminal frame's *shape* is verified (`message.complete` with `status:"ok"`), its successful values are not. `message_complete_ok.json` is marked `synthesized`. |
| An interactive (`approval`/`clarify`) request end to end | No provider → no tool call → no request. | **Open.** The bridge reports `waitingOnMac` on the contract level only. |
| Behaviour of a *busy* session (queued/steered/redirected) | Only single-turn submits were probed, and every one failed at the provider. `prompt.submit` returns `status` `streaming`/`queued`/`steered`/`redirected` per the contracts module. | **Open.** The bridge serialises per conversation itself, so it must not depend on server queuing. |
| `session.events.since` across a real epoch change mid-stream | Requires a restart during a live turn; no live turn was possible. | **Open.** Handled defensively (epoch change ⇒ refetch state). |
| Gate/ticket authentication over Tailscale | Out of scope for the bridge, which only speaks loopback. | Not applicable. |

## 12. Constraints this imposes on the implementation

1. `HermesCapabilities` must record **discovered** facts per connection, not constants: whether
   ticket auth is available, which interactive methods `client.capabilities` returned, and whether an
   admission API exists. On this build the answer is: no admission API, `uncertain` on ambiguity.
2. The bridge resolves conversations by **stored** session id, re-resolves after every reconnect, and
   never persists a runtime id as identity.
3. Terminal results come from `message.complete`; `error` events supply `errorSummary`; a turn that
   fails for provider reasons is `failed`, not retried.
4. `session.interrupt` is the only stop primitive, and it is best-effort. A cancel that arrives before
   dispatch is enforced locally (never dispatch), not by asking Hermes to forget anything.
5. The transport refuses to start unless the endpoint host is `localhost`, `127.0.0.1` or `::1`, and
   refuses to send anything until a credential is confirmed, so "Hermes not running" and "auth
   failed" stay pre-send blockers.
