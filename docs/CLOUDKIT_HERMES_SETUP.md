# CloudKit → local Hermes: setup and operation

NeoOS has two ways to reach Hermes:

| Mode | Path | What works |
| --- | --- | --- |
| **Direct** (unchanged) | iPhone → `hermes serve` over HTTPS/Tailscale HTTP/WebSocket | Everything the app already does: chat, voice, attachments, approvals, groups |
| **CloudKit** (new, first release) | iPhone → private CloudKit database → `NeoOSBridge` on the Mac → loopback `hermes serve` | Text only: conversation list, sending, final answers, failure and uncertain states |

The bridge does **not** replace the direct connection. Nothing in the new mode rewrites a stored
connection, and switching modes never moves or replays a queued message.

## 1. What has to exist before either side can work

These steps need a human in the Apple Developer portal and in CloudKit Console. They are the only
parts of this feature that cannot be done from the repository.

1. **App IDs.** Two identifiers in the same Team:
   - `org.neil.NeoOSBridge` (macOS app)
   - the existing iOS app identifier
   Both need the **iCloud** capability with CloudKit enabled.
2. **One CloudKit container**, e.g. `iCloud.org.neil.NeoOS`, assigned to both App IDs. The bundle
   identifiers and the container in this repository are placeholders taken from the signing account
   that built the project; replace them with yours.
3. **Schema** in the container's development environment. Record types and fields are listed in §3.
4. **Same iCloud user** signed in on the Mac and the iPhone, and both apps allowed to use iCloud.
5. **Push notifications** on both apps if you want pushes to trigger a pull. The feature works
   without them — a foreground pull and the 30-second fallback converge — it is just slower.
6. Before distributing a TestFlight or App Store build, **deploy the schema** to production and
   confirm both apps use the same environment. A development/production mismatch looks exactly like
   "no data yet", which is why the bridge shows the chosen environment in its settings.

If the container or the entitlements are missing, both apps say so. Neither falls back to the public
database, and neither embeds a server-to-server key.

## 2. Running the bridge on the Mac

1. Make sure `hermes serve` runs on the loopback interface, exactly as `docs/CONNECTING.md` describes
   for a local backend:
   ```sh
   hermes serve --host 127.0.0.1 --port 9119
   ```
   The bridge only accepts `localhost`, `127.0.0.1` and `::1`. It never uses Tailscale or a public
   address, and it never modifies your Hermes configuration.
2. Launch **NeoOS 桥接** (`NeoOSBridge.app`). It runs in your login session: no root daemon, no login
   item, no sleep prevention. Closing the window keeps it bridging; quitting stops it.
3. In the bridge's **设置** tab:
   - iCloud container + environment (the same values as the iPhone).
   - Loopback address and port.
   - The local Hermes credential. It is written to the **login Keychain** and cleared from the field;
     it is never uploaded, logged, or written to a record.
   - Profile (default `default`).
   - **测试连接** probes `client.capabilities` and reports whether this backend supports an admission
     lookup. On Hermes 0.22.2 it will say it does not — see
     `docs/CLOUDKIT_HERMES_COMPATIBILITY.md`.
   - **开始** starts bridging.
4. On the iPhone: Settings → mode → *Connexion iCloud (asynchrone)* → **连接并同步** → pick the Mac
   → **新建对话**.

### What the Mac does

- Pulls the mailbox, then runs **one turn at a time** across all conversations (strictly serial
  inside a conversation).
- Before calling Hermes it commits `dispatching`; after acceptance it records `accepted`; the final
  answer and its upload entry are written in **one** SQLite transaction.
- On restart it reconciles anything left in `dispatching`/`accepted`/`running`. Without an admission
  lookup the answer is `uncertain` — never a silent resend.
- Refuses to start a second executor for the same user: a `flock` on
  `~/Library/Application Support/NeoOSBridge/executor.lock` is held for the process's lifetime.

### Stopping

- **暂停** stops new dispatches; a turn already inside Hermes is not replayed or abandoned.
- **停止** on a task asks Hermes to interrupt it. The journal only becomes `cancelled` when a terminal
  frame proves it stopped.
- Quitting the app stops the executor. Nothing is deleted: local journals and cloud records stay for
  recovery and reconciliation.

## 3. CloudKit schema

Private database, custom zone `NeoOSMailboxV1`. Every record carries `schemaVersion` (Int64, 1) and a
`body` (Bytes) field holding the encoded domain value plus `bridgeID` / `profileID`. A record whose
version this build does not know is **quarantined**, never applied.

| Record type | recordName | Written by | Purpose |
| --- | --- | --- | --- |
| `BridgeDevice` | `bridge_<bridgeID>` | Mac | Heartbeat, name, profile, capabilities |
| `BridgeConversation` | `conversation_<id>` | creating iPhone | Ownership: only this device appends |
| `BridgeRequest` | `request_<messageID>` | iPhone | The message; immutable once written |
| `BridgeExecution` | `execution_<messageID>` | Mac | State + monotonic revision |
| `BridgeResult` | `result_<messageID>` | Mac | Final answer; immutable |
| `BridgeControl` | `control_<controlID>` | iPhone | Best-effort cancel |

Product limits (not Apple quota claims): request text **32 KiB** UTF-8, inline result **128 KiB**,
result asset **5 MiB**. Larger answers become a `CKAsset`; an answer above the asset limit is reported
as too large rather than truncated. Request and result records are written once: a `serverRecordChanged`
conflict is read back and compared field by field, never overwritten.

## 4. What the cloud mode deliberately does not do

- No approvals, no clarifying questions, no secrets. A task that needs a human shows
  `waitingOnMac` with the reason and a *stop* button; the phone cannot answer for you.
- No voice, attachments, configuration, groups, or arbitrary RPC.
- No cross-channel takeover: a conversation started on the direct connection is not continued from
  the cloud, and a queued cloud message is never re-sent over WebSocket.
- No multi-Mac failover, no importing the full Hermes history, no bulk cloud deletion.

## 5. Troubleshooting

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `iCloud 不可用` on the phone | not signed in, or the app has no iCloud capability | System Settings → Apple ID; the app's iCloud switch |
| Mac listed but nothing happens | Mac app not bridging, or a different profile | Bridge 设置 → 状态; the profile field on both sides |
| Message stays `已上传，等待 Mac` | the Mac has not pulled yet | press **刷新** on the Mac, or wait for the 30 s fallback |
| Message shows `不确定` | the connection dropped after the send | this is intentional; see the compatibility doc. Do not "retry" — the bridge refuses to replay |
| `Mac 需要人工处理` | Hermes asked something only a human can answer | finish it over the direct connection, then start a new cloud conversation |
| Nothing syncs, no error | development vs production container mismatch | compare the environment in both settings screens |

## 6. Verification status

Feature-level verification (what was actually run, and what was not) is in
`docs/CLOUDKIT_HERMES_VALIDATION.md`. Read it before claiming a build is working end to end: the
CloudKit path is compiled and unit-tested against fakes, and has **not** been exercised against a real
iCloud container.
