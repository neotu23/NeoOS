import XCTest
@testable import CloudBridgeCore

final class BridgeStoreTests: XCTestCase {
    private var directory: URL!
    private let scopeA = AccountScope(containerID: "iCloud.test.NeoOS", environment: "development",
                                      userRecordName: "_userA")
    private let scopeB = AccountScope(containerID: "iCloud.test.NeoOS", environment: "development",
                                      userRecordName: "_userB")
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neocloudbridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testDeletionOnlyPageReportsProjectionChange() async throws {
        let store = try makeStore()
        let request = makeRequest(conversationID: UUID(), text: "未执行的请求")
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        let summary = try await store.applyRemotePage(RemotePage(
            deletedRecordNames: ["request_\(request.messageID.uuidString)"]))
        let execution = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(execution?.state, .cancelled)
        XCTAssertGreaterThan(summary.saved + summary.received + summary.failed, 0,
                             "the UI must be told to reload after a deletion-only page")
    }

    // MARK: - Enqueue

    func testEnqueueAndDraftClearAreAtomic() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let draft = "草稿：只回复 OK 👋"
        try await store.saveDraft(draft, conversationID: conversationID)
        let savedDraft = try await store.draft(conversationID: conversationID)
        XCTAssertEqual(savedDraft, draft)

        let request = makeRequest(conversationID: conversationID, text: draft)
        let record = try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)

        let storedDraft = try await store.draft(conversationID: conversationID)
        XCTAssertEqual(storedDraft, "", "a committed enqueue clears the draft")
        XCTAssertEqual(record.recordName, "request_\(request.messageID.uuidString)")

        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .queuedLocal)
        let storedRequest = try await store.request(messageID: request.messageID)
        XCTAssertEqual(storedRequest?.text, draft)
        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox.map(\.recordName), [record.recordName])
    }

    func testFailedEnqueueKeepsTheDraftAndQueuesNothing() async throws {
        let store = try makeStore(faults: [.beforeEnqueueCommit])
        let conversationID = UUID()
        let draft = "草稿不能丢"
        try await store.saveDraft(draft, conversationID: conversationID)

        let request = makeRequest(conversationID: conversationID, text: draft)
        do {
            try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)
            XCTFail("expected the armed fault to abort the enqueue")
        } catch {
            XCTAssertEqual(error as? StoreError, .injected(.beforeEnqueueCommit))
        }

        let storedDraft = try await store.draft(conversationID: conversationID)
        XCTAssertEqual(storedDraft, draft, "the draft survives a failed transaction")
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertNil(journal)
        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox, [])
    }

    func testDuplicateRequestHasSingleJournal() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "一次就好")

        try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)
        // The same message arriving from CloudKit, and the same enqueue retried: neither may create
        // a second execution.
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]), now: epoch)
        try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch.addingTimeInterval(5))

        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.revision, 0)
        let entries = try await store.conversationEntries(conversationID)
        XCTAssertEqual(entries.count, 1)
        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox.count, 1)
    }

    func testEnqueueRejectsOversizedTextWithoutTouchingTheStore() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let huge = String(repeating: "中", count: 11_000)  // 33_000 bytes
        let request = makeRequest(conversationID: conversationID, text: huge)

        do {
            try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)
            XCTFail("expected the size guard to fire")
        } catch {
            guard case .textTooLarge = error as? BridgeValidationError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox, [])
    }

    // MARK: - Dispatch

    func testDispatchingSurvivesReopen() async throws {
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "重启后仍然记得")
        do {
            let store = try makeStore()
            _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]), now: epoch)
            try await store.beginDispatch(messageID: request.messageID, now: epoch)
        }

        let reopened = try makeStore()
        let journal = try await reopened.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .dispatching,
                       "dispatching must not silently fall back to received: that would invite a resend")

        let recoverable = try await reopened.recoverableExecutions()
        XCTAssertEqual(recoverable.map(\.messageID), [request.messageID])

        do {
            try await reopened.beginDispatch(messageID: request.messageID, now: epoch.addingTimeInterval(60))
            XCTFail("a second dispatch of the same message must be refused")
        } catch {
            XCTAssertEqual(error as? StoreError, .notReceived(messageID: request.messageID, state: .dispatching))
        }
    }

    func testBeginDispatchOnlyAcceptsReceived() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "hello")
        try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)

        do {
            try await store.beginDispatch(messageID: request.messageID, now: epoch)
            XCTFail("queuedLocal is not dispatchable: the Mac has not received it yet")
        } catch {
            XCTAssertEqual(error as? StoreError, .notReceived(messageID: request.messageID, state: .queuedLocal))
        }
    }

    // MARK: - Result / outbox

    func testResultAndOutboxAreAtomic() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "给个答案")
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]), now: epoch)
        try await store.beginDispatch(messageID: request.messageID, now: epoch)

        let result = BridgeResult(messageID: request.messageID, conversationID: conversationID,
                                  bridgeID: request.bridgeID, content: .inline("OK"),
                                  contentSHA256: "sha", completedAt: epoch, terminalStatus: .completed)
        let record = try await store.finish(messageID: request.messageID, result: result, now: epoch)

        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .completed)
        let storedResult = try await store.result(messageID: request.messageID)
        XCTAssertEqual(storedResult?.content.inlineText, "OK")
        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox.map(\.recordName), [record.recordName], "the answer is queued for upload")
        let recoverable = try await store.recoverableExecutions()
        XCTAssertEqual(recoverable, [], "a completed turn is not recovered")
    }

    func testFailedFinishPersistsNothing() async throws {
        let store = try makeStore(faults: [.beforeFinishCommit])
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "答案会失败")
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]), now: epoch)
        try await store.beginDispatch(messageID: request.messageID, now: epoch)

        let result = BridgeResult(messageID: request.messageID, conversationID: conversationID,
                                  bridgeID: request.bridgeID, content: .inline("OK"),
                                  contentSHA256: "sha", completedAt: epoch, terminalStatus: .completed)
        do {
            try await store.finish(messageID: request.messageID, result: result, now: epoch)
            XCTFail("expected the armed fault")
        } catch {
            XCTAssertEqual(error as? StoreError, .injected(.beforeFinishCommit))
        }

        let storedResult = try await store.result(messageID: request.messageID)
        XCTAssertNil(storedResult)
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .dispatching)
        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox, [])
    }

    func testCompletedTurnNeverReturnsToDispatch() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "问一次")
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]), now: epoch)
        try await store.beginDispatch(messageID: request.messageID, now: epoch)
        let result = BridgeResult(messageID: request.messageID, conversationID: conversationID,
                                  bridgeID: request.bridgeID, content: .inline("OK"),
                                  contentSHA256: "sha", completedAt: epoch, terminalStatus: .completed)
        try await store.finish(messageID: request.messageID, result: result, now: epoch)

        // A stale execution record arriving late must not reopen the turn.
        let stale = ExecutionUpdate(messageID: request.messageID, state: .running, revision: 99, updatedAt: epoch)
        _ = try await store.applyRemotePage(RemotePage(changes: [.execution(stale)]), now: epoch)
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .completed)

        do {
            try await store.beginDispatch(messageID: request.messageID, now: epoch)
            XCTFail("a completed turn must never be dispatched again")
        } catch {
            XCTAssertEqual(error as? StoreError, .notReceived(messageID: request.messageID, state: .completed))
        }
    }

    // MARK: - Tokens

    func testTokenDoesNotAdvanceOnFailedCommit() async throws {
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "别丢页")
        let token = Data([0x01, 0x02, 0x03])

        do {
            let failing = try makeStore(faults: [.beforePageCommit])
            do {
                _ = try await failing.applyRemotePage(RemotePage(changes: [.request(request)], nextToken: token),
                                                      now: epoch)
                XCTFail("expected the armed fault")
            } catch {
                XCTAssertEqual(error as? StoreError, .injected(.beforePageCommit))
            }
            let storedToken = try await failing.changeToken()
            XCTAssertNil(storedToken, "a page that did not persist must not advance the token")
            let journal = try await failing.executionProjection(messageID: request.messageID)
            XCTAssertNil(journal, "the rows rolled back with the token")
        }

        let healthy = try makeStore()
        _ = try await healthy.applyRemotePage(RemotePage(changes: [.request(request)], nextToken: token), now: epoch)
        let healthyToken = try await healthy.changeToken()
        XCTAssertEqual(healthyToken, token)
        let journal = try await healthy.executionProjection(messageID: request.messageID)
        XCTAssertNotNil(journal)

        try await healthy.clearChangeToken()
        let clearedToken = try await healthy.changeToken()
        XCTAssertNil(clearedToken)
    }

    // MARK: - Dependency order

    func testMissingDependencyWaits() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let first = makeRequest(conversationID: conversationID, text: "第一条", createdAt: epoch)
        let second = makeRequest(conversationID: conversationID, text: "第二条",
                                 createdAt: epoch.addingTimeInterval(1), previous: first.messageID)

        // Only the second message has synced: running it now would reorder the conversation.
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(second)]), now: epoch)
        let waiting = try await store.conversationEntries(conversationID)
        XCTAssertEqual(MessageReducer.dispatchDecision(in: waiting),
                       .waitForDependency(messageID: second.messageID, dependency: first.messageID))

        // The predecessor arrives and completes; now the second message may run.
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(first)]), now: epoch)
        try await store.beginDispatch(messageID: first.messageID, now: epoch)
        try await store.finish(messageID: first.messageID,
                               result: BridgeResult(messageID: first.messageID, conversationID: conversationID,
                                                    bridgeID: first.bridgeID, content: .inline("一"),
                                                    contentSHA256: "", completedAt: epoch,
                                                    terminalStatus: .completed),
                               now: epoch)
        let ready = try await store.conversationEntries(conversationID)
        XCTAssertEqual(MessageReducer.dispatchDecision(in: ready), .dispatch(messageID: second.messageID))
    }

    // MARK: - Scope isolation

    func testAccountScopeIsolatesRows() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "只属于 A")
        try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)
        let visibleInA = try await store.request(messageID: request.messageID)
        XCTAssertNotNil(visibleInA)

        await store.switchScope(to: scopeB)
        let hiddenInB = try await store.request(messageID: request.messageID)
        XCTAssertNil(hiddenInB, "another iCloud user must never see this row")
        let outboxInB = try await store.pendingOutbound()
        XCTAssertEqual(outboxInB, [], "the old outbox must not be uploaded for the new account")
        let conversationsInB = try await store.conversationIDs()
        XCTAssertEqual(conversationsInB, [])

        await store.switchScope(to: scopeA)
        let visibleAgain = try await store.request(messageID: request.messageID)
        XCTAssertNotNil(visibleAgain, "switching back finds the rows again: they are isolated, not deleted")
    }

    func testScopeIsolationHoldsForTokensAndDrafts() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        try await store.saveDraft("A 的草稿", conversationID: conversationID)
        _ = try await store.applyRemotePage(RemotePage(changes: [], nextToken: Data([9])), now: epoch)

        await store.switchScope(to: scopeB)
        let draft = try await store.draft(conversationID: conversationID)
        XCTAssertEqual(draft, "")
        let token = try await store.changeToken()
        XCTAssertNil(token)
    }

    // MARK: - Ordering hazards

    func testOrphanResultIsKeptUntilItsRequestArrives() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "先有答案后有问")
        let result = BridgeResult(messageID: request.messageID, conversationID: conversationID,
                                  bridgeID: request.bridgeID, content: .inline("答案是 42"),
                                  contentSHA256: "sha", completedAt: epoch, terminalStatus: .completed)

        _ = try await store.applyRemotePage(RemotePage(changes: [.result(result)]), now: epoch)
        let orphan = try await store.result(messageID: request.messageID)
        XCTAssertEqual(orphan?.content.inlineText, "答案是 42")
        let missingRequest = try await store.request(messageID: request.messageID)
        XCTAssertNil(missingRequest)

        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]), now: epoch)
        let linked = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(linked?.state, .completed, "the result already proves the turn finished")
    }

    func testCancelBeforeDispatchPreventsItLocally() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let request = makeRequest(conversationID: conversationID, text: "来不及取消")
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]), now: epoch)

        let control = BridgeControl(messageID: request.messageID, bridgeID: request.bridgeID, createdAt: epoch)
        _ = try await store.applyRemotePage(RemotePage(changes: [.control(control)]), now: epoch)

        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .cancelled)
        do {
            try await store.beginDispatch(messageID: request.messageID, now: epoch)
            XCTFail("a cancelled request must not be dispatched")
        } catch {
            XCTAssertEqual(error as? StoreError,
                           .notReceived(messageID: request.messageID, state: .cancelled))
        }
    }

    func testRepeatedCancelDoesNotDisturbANewTurn() async throws {
        let store = try makeStore()
        let conversationID = UUID()
        let first = makeRequest(conversationID: conversationID, text: "第一轮", createdAt: epoch)
        let second = makeRequest(conversationID: conversationID, text: "第二轮",
                                 createdAt: epoch.addingTimeInterval(1), previous: first.messageID)
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(first), .request(second)]), now: epoch)

        let control = BridgeControl(messageID: first.messageID, bridgeID: first.bridgeID, createdAt: epoch)
        _ = try await store.applyRemotePage(RemotePage(changes: [.control(control)]), now: epoch)
        // The control belongs to the first message only.
        let secondJournal = try await store.executionProjection(messageID: second.messageID)
        XCTAssertEqual(secondJournal?.state, .received)

        let duplicate = BridgeControl(controlID: control.controlID, messageID: first.messageID,
                                      bridgeID: first.bridgeID, createdAt: epoch.addingTimeInterval(30))
        _ = try await store.applyRemotePage(RemotePage(changes: [.control(duplicate)]), now: epoch)
        let secondAgain = try await store.executionProjection(messageID: second.messageID)
        XCTAssertEqual(secondAgain?.state, .received, "replaying a cancel must not touch another turn")
    }

    func testUnknownStateIsQuarantinedNotApplied() async throws {
        let store = try makeStore()
        let messageID = UUID()
        let future = ExecutionUpdate(messageID: messageID, schemaVersion: CloudSchema.version + 1,
                                     state: .running, revision: 1, updatedAt: epoch)
        let summary = try await store.applyRemotePage(RemotePage(changes: [.execution(future)]), now: epoch)
        XCTAssertEqual(summary.failed, 1)
        let journal = try await store.executionProjection(messageID: messageID)
        XCTAssertNil(journal)
        let quarantined = try await store.quarantinedRecords()
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(quarantined.first?.reason, QuarantineReason.unknownSchemaVersion.rawValue)
    }

    // MARK: - Helpers

    private func makeStore(faults: Set<StoreFault> = []) throws -> BridgeStore {
        // A fixed file name per test: `setUp` gives each test its own directory, and tests that
        // reopen the store need the same file.
        let path = directory.appendingPathComponent("store.sqlite").path
        return try BridgeStore(path: path, scope: scopeA, faults: faults)
    }

    private func makeRequest(conversationID: UUID, text: String, createdAt: Date? = nil,
                             previous: UUID? = nil) -> BridgeRequest {
        BridgeRequest(conversationID: conversationID, bridgeID: UUID(), profileID: "default",
                      sourceDeviceID: "device-A", text: text, previousMessageID: previous,
                      createdAt: createdAt ?? epoch)
    }
}
