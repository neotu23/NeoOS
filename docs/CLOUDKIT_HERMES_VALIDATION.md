# CloudKit bridge: validation record

Date: **2026-11-01**. Hermes target: the installed `hermes-agent` checkout,
`hermes --version` → `v0.22.2+3291.gbf0203a` (release 2026.9.24), plus one isolated live instance
described in `docs/CLOUDKIT_HERMES_COMPATIBILITY.md`.

This file records what was **actually run**. Anything not run is listed as not run, with the reason.
A compiled binary is not an end-to-end proof, and this document is written so nobody has to guess
which is which.

## 1. Summary

| Area | State |
| --- | --- |
| Shared package (`Packages/NeoCloudBridge`) | 60 tests pass (39 core + 21 sync) |
| Local Hermes adapter | 17 tests pass against recorded frames and error frames |
| macOS bridge controller | 11 tests pass against fake mailbox/Hermes/clock |
| macOS bridge app | builds (`CODE_SIGNING_ALLOWED=NO`); **not run against CloudKit** |
| iOS app | builds; existing 170 unit tests pass; 4 new UI tests pass |
| Real iCloud end to end | **not run** — needs a container, a signed App ID and two devices |
| Real Hermes successful turn | **not run** — the isolated instance had no usable provider credential |

## 2. Commands and results

### 2.1 Shared package

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/NeoCloudBridge
```

Result: `39` core tests, `21` sync tests, `17` client tests — all pass.

Covered behaviours (test names are the contract):

- `CloudModelsTests`: request round trip preserves ids; blank / oversized text is refused; the 32 KiB
  limit is measured in **UTF-8 bytes** (a 10 922-character Chinese string passes at 32 766 bytes, one
  more character fails; 8 192 emoji pass at exactly 32 768); result inline/asset limits.
- `MessageReducerTests`: `completed` never regresses to `running`; failed/cancelled only give way to a
  completed result; stale revisions are ignored; unknown schema is quarantined; dependency order,
  missing dependency waits, a failed/uncertain predecessor blocks the rest, a fork is
  `conversationConflict`.
- `BridgeStoreTests`: enqueue + draft clear are atomic; duplicate delivery keeps one journal;
  `dispatching` survives reopen and refuses a second dispatch; result + outbox are atomic; a failed
  commit advances no token; an orphan result is kept and links when its request arrives; a cancel
  before dispatch prevents it; a replayed cancel does not touch another turn; account scope isolates
  rows, drafts and tokens.
- `CloudRecordCodecTests`: stable typed record names with no user text; unknown schema, malformed
  body, missing fields, wrong bridge/profile and mismatched name prefix are quarantined; oversized and
  blank text cannot survive encoding.
- `CloudMailboxTests`: pagination consumes every page and advances the token only at the end;
  concurrent refreshes coalesce into one cycle; an expired token rescans without re-dispatching a
  completed turn; a lost acknowledgement reads the record back and compares content; a genuine
  conflict is not overwritten; an account switch uploads nothing; `retryAfter` beats the exponential
  backoff.
- `LocalHermesClientTests`: non-loopback endpoints are refused; the JSON-RPC id is not a durable
  input id; submit re-resolves the **stored** session id; the credential is re-read on every
  reconnect; no credential means no socket; terminal events carry the answer; an interactive request
  is surfaced and never answered.
- `RecoveryTests`: pre-send failure is `confirmedNotSent`; a lost acknowledgement without an inquiry
  API is `unknown` and submits nothing; a receipt API is queried, not resubmitted; recorded fixtures
  decode into the typed events; several frames in one WebSocket message are split correctly.

### 2.2 macOS bridge

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project HermesIOS.xcodeproj -scheme NeoOSBridge \
  -destination 'platform=macOS' -derivedDataPath /tmp/NeoOSCloudKitDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```
Result: **BUILD SUCCEEDED**.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project HermesIOS.xcodeproj -scheme NeoOSBridge \
  -destination 'platform=macOS' -derivedDataPath /tmp/NeoOSCloudKitDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:NeoOSBridgeTests/BridgeControllerTests test
```
Result: `11` tests, **TEST SUCCEEDED**.

`BridgeControllerTests` covers: duplicate delivery calls `submit` once; a crash after `dispatching`
merely loads never blindly resubmits; a completed turn with a pending upload retries the upload and
never calls Hermes; per-conversation dependency order is honoured; a failed predecessor blocks the
rest; an interactive prompt is reported as `waitingOnMac` and never answered; a stop request does not
mark the task cancelled before Hermes confirms; a cancel before dispatch prevents it; a repeated
cancel does not touch the next turn; pause stops new dispatches; another iCloud identity sees no rows.

Signing: **the app could not be built with signing enabled.**
`xcodebuild` reported `No profiles for 'org.neil.NeoOSBridge' were found`. The CloudKit and App
Sandbox entitlements need an App ID with the iCloud capability. Everything above therefore proves the
code compiles and its logic is correct; it does **not** prove that iCloud works. See §4.

### 2.3 iOS app

Build:
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project HermesIOS.xcodeproj -scheme HermesIOS \
  -destination 'platform=iOS Simulator,id=326F7710-4B5C-4F0E-9C52-36F05259FB22' \
  -derivedDataPath /tmp/NeoOSCloudKitDerivedData CODE_SIGNING_ALLOWED=NO build
```
Result: **BUILD SUCCEEDED**. (The simulator id is the iPhone 17 Pro listed by
`xcrun simctl list devices available` on this machine.)

Existing core tests:
```sh
swift test --package-path .
```
Result: `170` tests pass — the rename/localization work and the existing model logic are untouched.

Mode tests:
```sh
swift test --package-path . --filter ConnectionModeTests
```
Result: `4` tests pass. A missing `connectionMode` key resolves to `direct`; an unknown value also
resolves to `direct`; the value round-trips.

Cloud UI tests:
```sh
xcodebuild -project HermesIOS.xcodeproj -scheme HermesIOS \
  -destination 'platform=iOS Simulator,id=326F7710-4B5C-4F0E-9C52-36F05259FB22' \
  -derivedDataPath /tmp/NeoOSCloudKitDerivedData CODE_SIGNING_ALLOWED=NO \
  -only-testing:HermesIOSUITests/CloudChatUITests test
```
Result: `4` tests, **TEST SUCCEEDED**:

| Test | What it proves |
| --- | --- |
| `testCloudModeWithoutDirectServerCanOpenChat` | cloud mode opens with no saved direct endpoint |
| `testUploadedAndRunningHaveDistinctLabels` | `已上传，等待 Mac` and `Hermes 正在执行` are different labels |
| `testOfflineEnqueueSurvivesRelaunch` | an offline send is accepted and shown, not dropped |
| `testDirectModeStillOpensTheOriginalChat` | the direct composer still works (`--demo`) |

These run against `CloudFixtureMailbox` (`-neoCloudFixture`, DEBUG only): an in-memory store and a
mailbox that can be told to fail. They do not touch CloudKit.

## 3. Coverage, by review focus (plan §7)

| # | Risk | Evidence |
| --- | --- | --- |
| 1 | Hermes ran but the receipt was lost → must not re-run | `RecoveryTests.testLostAckWithoutAnInquiryAPIStaysUnknown` (adapter, `unknown`), `BridgeControllerTests.testCrashAfterDispatchNeverBlindlyResubmits` (controller: zero submits), `BridgeStoreTests.testDispatchingSurvivesReopen` (journal). Live evidence that "the text is in the history" is not proof: `docs/CLOUDKIT_HERMES_COMPATIBILITY.md` §5.1. **Fake-level only**; no real crash injection against a real backend. |
| 2 | Mac stored the answer, upload failed / app crashed → retry the same record | `BridgeStoreTests.testResultAndOutboxAreAtomic`, `testFailedFinishPersistsNothing`; `BridgeControllerTests.testCompletedUploadRetryDoesNotInvokeHermes`; `CloudMailboxTests.testUploadAckLostReadsBackSameRecord`. |
| 3 | iCloud account switch must not mix data | `BridgeStoreTests.testAccountScopeIsolatesRows`, `testScopeIsolationHoldsForTokensAndDrafts`; `CloudMailboxTests.testAccountSwitchDoesNotUploadOldOutbox`; `BridgeControllerTests.testOldAccountCompletionStaysInOldScope`. **Not tested on two real Apple IDs.** |
| 4 | A cloud-only user must not be blocked | `CloudChatUITests.testCloudModeWithoutDirectServerCanOpenChat`. |
| 5 | Push lost, token expired, out-of-order records | `CloudMailboxTests.testExpiredTokenRescanDoesNotRedispatch`, `testFetchConsumesAllPages`, `testOrphanResultEventuallyLinks`, `testDuplicatePushCoalescesFetch`; `BridgeStoreTests.testOrphanResultIsKeptUntilItsRequestArrives`. Pushes themselves: **not tested** (no device, no container). |

## 4. Not verified, and what it needs

| Item | Why it was not done | What would close it |
| --- | --- | --- |
| Real iCloud round trip | no signed App ID with iCloud, no container, no schema | `docs/CLOUDKIT_HERMES_SETUP.md` §1, then run the checklist in §5 below |
| Real macOS build with entitlements | `No profiles for 'org.neil.NeoOSBridge'` | add the App ID + iCloud capability to the team, then build without `CODE_SIGNING_ALLOWED=NO` |
| CloudKit push → pull | needs a signed app on a real device | enable Push Notifications on both App IDs |
| A real successful Hermes turn | the isolated backend had no usable provider credential; `~/.hermes/.env` was deliberately not read | run the same probe against a profile whose provider key works, and record `message.complete{status:"ok"}` |
| Interactive (approval/clarify) end to end | same reason: no provider → no tool call → no request | trigger a tool that needs approval over the direct connection and observe the bridge's `waitingOnMac` |
| Two real iCloud accounts switching on one Mac | needs two Apple IDs and a signed app | sign out/in and confirm the second account sees no rows |
| iPhone airplane mode + process kill + relaunch | the UI fixture proves the local queue, not the real upload | do it on a device with a container |
| Hermes restart during a live turn (epoch change) | no live turn was possible | observe `session.reclaimed` / a new epoch and confirm the bridge marks the task `uncertain` |

## 5. Real end-to-end checklist (to run once §4 is unblocked)

1. Sign the Mac app, register the container, deploy the schema to development.
2. Sign in with the **same** iCloud user on both devices; confirm the same container + environment.
3. iPhone, cloud mode: send `只回复 CLOUDKIT_OK，不调用任何工具`.
4. Watch the labels: `已上传，等待 Mac` → `Mac 已接收` → `Hermes 已接收` → `Hermes 正在执行` → `已完成`.
5. Reopen both apps: the request and the answer are still there.
6. Quit the Mac app, send two messages in one conversation, relaunch: they run in order, once each
   (Mac submits = 2).
7. iPhone airplane mode → send → kill the app → relaunch: the message is still queued, the draft of
   an unsent message is still there; back online it uploads with the same `messageID`.
8. Drop one acceptance receipt (disconnect after `prompt.submit`): the task must read `不确定`, and
   the Mac's journal must show **no second submit**.
9. Get an answer, cut the network, restart the bridge, reconnect: the same result record uploads, and
   Hermes is not called again.
10. Disable notifications: a manual refresh or a foreground pull recovers the state.
11. Point the two sides at different environments: each shows an accurate reason; no old outbox row
    is uploaded.

## 6. Repository state

- No `git commit` / `git push` was performed.
- The existing uncommitted work (renames, `Localization.swift`, `LanguageSettingsView.swift`,
  `en.lproj`, `zh-Hans.lproj`, the `project.pbxproj` edits) was preserved. `xcodegen generate` was
  **not** run against the checked-in project: the checked-in `project.pbxproj` carries hand edits the
  spec does not reproduce (`DEVELOPMENT_TEAM = S8X8W7J77M`, `org.neil.*` bundle identifiers,
  `STRING_CATALOG_GENERATE_SYMBOLS`). The new targets and files were inserted by
  `scripts/add_neobridge_targets.py`; `project.yml` was updated separately so a future regeneration
  knows about them.
- Suggested commit boundaries, if these changes are split up:
  1. `Packages/NeoCloudBridge` + tests (Task 1–4)
  2. `NeoOSBridge/`, `NeoOSBridgeTests/`, `scripts/add_neobridge_targets.py`, project files (Task 5–6)
  3. `HermesIOS/Features/Cloud/`, `Core/ConnectionMode.swift`, `Networking/CloudRuntime.swift`, the
     app/RootView/delegate edits, strings, iOS tests (Task 7)
  4. `docs/CLOUDKIT_HERMES_{COMPATIBILITY,SETUP,VALIDATION}.md`, README (Task 8)
