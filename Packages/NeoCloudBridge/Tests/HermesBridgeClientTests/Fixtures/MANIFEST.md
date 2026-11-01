# Hermes wire fixtures

These files are recorded copies of frames observed on a **real** `hermes serve`
of Hermes `0.22.2` (`bf0203a794`, release 2026.9.24), captured on 2026-11-01
against an isolated instance (`HERMES_HOME` pointing at a throwaway directory,
`127.0.0.1:19119`, `--skip-build`). They are the source of truth for the
`HermesBridgeClient` codec: every key the adapter reads has to appear here.

Nothing in this directory is hand-invented except where a file states
`synthesized` in its own `_fixture` block; synthesized frames only reuse field
names observed in a real frame of the same event type.

## Sanitisation

- `replay_epoch`, `install_id`, session ids and row ids were replaced with
  stable placeholders. They are per-instance random values, not credentials.
- The `gateway.ready` skin block was trimmed to four keys: it is presentational
  and would hide the framing details this fixture exists to pin down.
- No cookie, `?token=` value, `?ticket=` value, `X-Hermes-Session-Token` value,
  `X-Hermes-Gateway-Ticket` value, `.env` content or absolute private path is
  present in any file here. Review before adding a new fixture.

## Provenance

| File | Kind | Origin |
| --- | --- | --- |
| `gateway_ready.json` | real | first frame on `/api/ws` |
| `client_capabilities.json` | real | `client.capabilities {server_requests: true}` |
| `session_create.json` | real | `session.create {profile: "default"}` |
| `session_resume_by_stored_id.json` | real | `session.resume {session_id: "<stored id>"}` |
| `prompt_submit_accepted.json` | real | `prompt.submit {session_id, text}` on a live session |
| `message_complete_error.json` | real | terminal frame when the profile had no reachable provider |
| `message_complete_ok.json` | synthesized | same payload class, `status: "ok"`; see the compatibility doc, "Not verified" |
| `error_unknown_method.json` | real | `runtime.describe` / `prompt.receipt` / `session.mutate` on this build |
| `error_session_not_found.json` | real | `session.resume {session_id: "<runtime id>"}` |
| `session_events_since.json` | real | `session.events.since {session_id, last_seen: 0}` |
| `session_interrupt.json` | real | `session.interrupt {session_id}` |
