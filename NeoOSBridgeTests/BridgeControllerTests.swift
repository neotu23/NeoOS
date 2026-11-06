import XCTest
import CloudBridgeCore
import CloudBridgeSync
import HermesBridgeClient
@testable import NeoOSBridge

// MARK: - Fakes

/// Records what the bridge asked Hermes to do. Nothing here touches a socket.
final class FakeHermes: HermesExecuting, @unchecked Sendable {
    enum Outcome {
        case complete(String)
        case interactive(String)
        case fail(String)
        case never
    }

    private let lock = NSLock()
    private var _submissions: [BridgeRequest] = []
    private var _interrupts: [UUID] = []
    private var _recoveries: [ExecutionJournal] = []
    private var continuation: AsyncStream<HermesBridgeEvent>.Continuation?
    private var pendingEvents: [HermesBridgeEvent] = []
    var outcome: Outcome = .complete("OK")
    var recoveryOutcome: RecoveryOutcome = .unknown

    var submissions: [BridgeRequest] { lock.withLock { _submissions } }
    var submissionCount: Int { lock.withLock { _submissions.count } }
    var interrupts: [UUID] { lock.withLock { _interrupts } }
    var recoveries: [ExecutionJournal] { lock.withLock { _recoveries } }

    func probe() async throws -> HermesCapabilities {
        HermesCapabilities(supportsAdmissionReceipt: false)
    }

    func resolveConversation(_ conversation: BridgeConversation) async throws -> HermesSession {
        HermesSession(storedSessionID: "stored-\(conversation.conversationID.uuidString.prefix(8))",
                      runtimeSessionID: "runtime", profileID: conversation.profileID)
    }

    func submit(_ request: BridgeRequest, in session: HermesSession) async throws -> Admission {
        lock.withLock { _submissions.append(request) }
        switch outcome {
        case .complete(let text):
            emit(HermesBridgeEvent(kind: .completed, messageID: request.messageID, text: text))
        case .interactive(let prompt):
            emit(HermesBridgeEvent(kind: .interactive, messageID: request.messageID, text: prompt))
        case .fail(let reason):
            emit(HermesBridgeEvent(kind: .failed, messageID: request.messageID, detail: reason))
        case .never:
            break
        }
        return Admission(kind: .streaming, userRowID: 1)
    }

    func recover(_ execution: ExecutionJournal) async throws -> RecoveryOutcome {
        lock.withLock { _recoveries.append(execution) }
        return recoveryOutcome
    }

    func interrupt(_ execution: ExecutionJournal) async throws {
        lock.withLock { _interrupts.append(execution.messageID) }
    }

    func events() async -> AsyncStream<HermesBridgeEvent> {
        let stream = AsyncStream<HermesBridgeEvent> { continuation in
            lock.withLock {
                self.continuation = continuation
                for event in pendingEvents { continuation.yield(event) }
                pendingEvents.removeAll()
            }
        }
        return stream
    }

    private func emit(_ event: HermesBridgeEvent) {
        let target = lock.withLock { () -> AsyncStream<HermesBridgeEvent>.Continuation? in
            if let continuation { return continuation }
            pendingEvents.append(event)
            return nil
        }
        target?.yield(event)
    }
}

/// Stands in for CloudKit: the tests care about what the bridge publishes, not that iCloud exists.
final class FakeMailbox: MailboxTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _published: [OutboundRecord] = []
    private var _operations: [String] = []
    var synchronizeError: Error?
    var publishError: Error?

    var published: [OutboundRecord] { lock.withLock { _published } }
    var operations: [String] { lock.withLock { _operations } }

    func accountScope() async throws -> AccountScope {
        AccountScope(containerID: "iCloud.test.NeoOS", environment: "development", userRecordName: "_user")
    }

    func synchronize() async throws -> SyncSummary {
        lock.withLock { _operations.append("synchronize") }
        if let synchronizeError { throw synchronizeError }
        return SyncSummary()
    }

    func publish(_ record: OutboundRecord) async throws -> PublishReceipt {
        lock.withLock { _operations.append("publish") }
        if let publishError { throw publishError }
        lock.withLock { _published.append(record) }
        return PublishReceipt(recordName: record.recordName, confirmedAt: Date())
    }
}

// MARK: - Tests

@MainActor
final class BridgeControllerTests: XCTestCase {
    private var directory: URL!
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private let scope = AccountScope(containerID: "iCloud.test.NeoOS", environment: "development",
                                     userRecordName: "_user")
    private var bridgeID = UUID()
    private var store: BridgeStore!
    private var hermes: FakeHermes!
    private var mailbox: FakeMailbox!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neobridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try BridgeStore(path: directory.appendingPathComponent("store.sqlite").path, scope: scope)
        hermes = FakeHermes()
        mailbox = FakeMailbox()
        bridgeID = UUID()
    }

    override func tearDown() async throws {
        await store?.close()
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - Duplicate delivery

    func testDuplicateDeliveryCallsSubmitOnce() async throws {
        let request = makeRequest()
        // The same record delivered three times, as CloudKit may do.
        for _ in 0..<3 {
            _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        }
        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        await waitUntil { self.hermes.submissionCount == 1 }
        XCTAssertEqual(hermes.submissionCount, 1, "one message is one execution")

        await controller.drainOne()
        XCTAssertEqual(hermes.submissionCount, 1, "a second drain must not submit again")
    }

    // MARK: - Crash windows

    func testCrashAfterDispatchNeverBlindlyResubmits() async throws {
        let request = makeRequest()
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        // The previous run committed "about to send" and then died.
        try await store.beginDispatch(messageID: request.messageID, now: epoch)
        hermes.recoveryOutcome = .unknown

        let controller = makeController()
        await controller.recoverPendingWork()
        await controller.drainOne()

        XCTAssertEqual(hermes.submissionCount, 0, "an unproven submission is never replayed")
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .uncertain)
        XCTAssertEqual(hermes.recoveries.map(\.messageID), [request.messageID])
    }

    func testCompletedUploadRetryDoesNotInvokeHermes() async throws {
        let request = makeRequest()
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        try await store.beginDispatch(messageID: request.messageID, now: epoch)
        let result = BridgeResult(messageID: request.messageID, conversationID: request.conversationID,
                                  bridgeID: request.bridgeID, content: .inline("done"),
                                  contentSHA256: "sha", completedAt: epoch, terminalStatus: .completed)
        let outbound = try await store.finish(messageID: request.messageID, result: result, now: epoch)

        let controller = makeController()
        await controller.refresh()
        await controller.drainOne()
        await controller.recoverPendingWork()

        XCTAssertEqual(hermes.submissionCount, 0, "a stored answer is retried as an upload, never as a turn")
        let pending = try await store.pendingOutbound()
        XCTAssertEqual(pending.map(\.recordName), [outbound.recordName])
    }

    // MARK: - Ordering

    func testPerConversationDependencyOrder() async throws {
        let first = makeRequest(text: "第一条", createdAt: epoch)
        let second = makeRequest(text: "第二条", createdAt: epoch.addingTimeInterval(1),
                                 previous: first.messageID)
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(second), .request(first)]))

        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        await waitUntil { self.hermes.subscriptionOrder.count >= 1 }
        let order = hermes.submissionOrder
        XCTAssertEqual(order.first, first.messageID, "the dependency runs first even though it synced second")

        await waitUntil { self.hermes.submissionOrder.count == 2 }
        XCTAssertEqual(hermes.submissionOrder, [first.messageID, second.messageID])
    }

    func testSecondRequestWaitsWhileTheFirstIsBlocked() async throws {
        let first = makeRequest(text: "失败的一条", createdAt: epoch)
        let second = makeRequest(text: "后面的一条", createdAt: epoch.addingTimeInterval(1),
                                 previous: first.messageID)
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(first), .request(second)]))
        try await store.fail(messageID: first.messageID, code: "provider", summary: "no provider", now: epoch)

        let controller = makeController()
        await controller.drainOne()

        XCTAssertEqual(hermes.submissionCount, 0,
                       "the bridge must not step over a failed turn")
    }

    // MARK: - Interaction

    func testInteractivePromptNeverAutoApproves() async throws {
        let request = makeRequest()
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        hermes.outcome = .interactive("允许执行 rm -rf 吗？")

        let controller = makeController()
        controller.start()
        defer { controller.stop() }

        await waitUntil { controller.waitingMessageID == request.messageID }
        XCTAssertEqual(controller.waitingMessageID, request.messageID)
        XCTAssertTrue(controller.waitingReason?.contains("rm -rf") ?? false)
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .waitingOnMac)
        XCTAssertEqual(hermes.interrupts, [], "nothing is answered or stopped without the user")
    }

    func testInterruptKeepsTheJournalUntilHermesConfirms() async throws {
        let request = makeRequest()
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        hermes.outcome = .interactive("需要确认")
        let controller = makeController()
        controller.start()
        defer { controller.stop() }
        await waitUntil { controller.waitingMessageID == request.messageID }

        await controller.interruptActiveTask()
        XCTAssertEqual(hermes.interrupts, [request.messageID])
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertNotEqual(journal?.state, .cancelled,
                          "a stop request is not proof that the turn stopped")
    }

    // MARK: - Cancellation

    func testCancelBeforeRequestPreventsDispatch() async throws {
        let request = makeRequest()
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        let controller = makeController()

        await controller.cancel(messageID: request.messageID)
        await controller.drainOne()

        XCTAssertEqual(hermes.submissionCount, 0, "a cancelled request is never dispatched")
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .cancelled)
    }

    func testRepeatedCancelDoesNotInterruptNewTurn() async throws {
        let first = makeRequest(text: "第一轮", createdAt: epoch)
        let second = makeRequest(text: "第二轮", createdAt: epoch.addingTimeInterval(1),
                                 previous: first.messageID)
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(first), .request(second)]))

        let controller = makeController()
        await controller.cancel(messageID: first.messageID)
        await controller.cancel(messageID: first.messageID)

        let secondJournal = try await store.executionProjection(messageID: second.messageID)
        XCTAssertEqual(secondJournal?.state, .received,
                       "a cancel for one message must not touch the next one")
    }

    // MARK: - Pause

    func testPauseStopsNewDispatches() async throws {
        let request = makeRequest()
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        let controller = makeController()
        controller.pause()

        await controller.drainOne()
        XCTAssertEqual(hermes.submissionCount, 0)
        XCTAssertEqual(controller.phase, .paused)

        controller.resume()
        controller.start()
        await waitUntil { self.hermes.submissionCount == 1 }
        controller.stop()
        XCTAssertEqual(hermes.submissionCount, 1)
    }

    // MARK: - Scope

    func testOldAccountCompletionStaysInOldScope() async throws {
        let request = makeRequest()
        _ = try await store.applyRemotePage(RemotePage(changes: [.request(request)]))
        try await store.beginDispatch(messageID: request.messageID, now: epoch)
        let result = BridgeResult(messageID: request.messageID, conversationID: request.conversationID,
                                  bridgeID: request.bridgeID, content: .inline("旧账号的答案"),
                                  contentSHA256: "s", completedAt: epoch, terminalStatus: .completed)
        try await store.finish(messageID: request.messageID, result: result, now: epoch)

        let otherScope = AccountScope(containerID: scope.containerID, environment: scope.environment,
                                      userRecordName: "_otherUser")
        await store.switchScope(to: otherScope)

        let controller = makeController()
        await controller.refreshTasks()
        XCTAssertEqual(controller.tasks, [], "another iCloud identity sees no rows")
        let visible = try await store.result(messageID: request.messageID)
        XCTAssertNil(visible)
    }

    // MARK: - Helpers

    func testRefreshPublishesDeviceAfterMailboxInitialization() async throws {
        let controller = makeController()
        await controller.refresh()

        XCTAssertEqual(mailbox.operations, ["synchronize", "publish"])
        XCTAssertEqual(mailbox.published.map(\.kind), [.device])
        XCTAssertEqual(controller.lastHeartbeatAt, epoch)
        let record = try XCTUnwrap(mailbox.published.first)
        let codec = CloudRecordCodec(scope: RecordScope(bridgeID: nil, profileID: nil))
        guard case .change(.device(let device)) = codec.decode(recordName: record.recordName, body: record.payload) else {
            return XCTFail("the phone must be able to discover the published Mac")
        }
        XCTAssertEqual(device.bridgeID, bridgeID)
        XCTAssertEqual(device.name, "测试 Mac")
    }

    func testFailedDevicePublicationIsReportedAndRetried() async throws {
        let controller = makeController()
        mailbox.publishError = MailboxError.transport("device upload failed", retryAfter: nil)
        await controller.refresh()
        XCTAssertEqual(controller.lastError, "device upload failed")
        XCTAssertTrue(mailbox.published.isEmpty)
        XCTAssertNil(controller.lastHeartbeatAt)

        mailbox.publishError = nil
        await controller.refresh()
        XCTAssertEqual(mailbox.operations, ["synchronize", "publish", "synchronize", "publish"])
        XCTAssertEqual(mailbox.published.map(\.kind), [.device])
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.lastHeartbeatAt, epoch)
    }

    func testSynchronizationFailureDoesNotPublishDevice() async throws {
        let controller = makeController()
        mailbox.synchronizeError = MailboxError.transport("sync failed", retryAfter: nil)
        await controller.refresh()
        XCTAssertEqual(mailbox.operations, ["synchronize"])
        XCTAssertEqual(controller.lastError, "sync failed")
    }

    private func makeController() -> BridgeController {
        BridgeController(store: store, mailbox: mailbox, hermes: hermes,
                         codec: CloudRecordCodec(scope: RecordScope(bridgeID: bridgeID, profileID: "default")),
                         bridgeID: bridgeID, bridgeName: "测试 Mac", profileID: "default",
                         clock: BridgeClock(now: { [epoch] in epoch },
                                            sleep: { duration in
                                                // The turn timeout (600 s) is parked so the test decides
                                                // the outcome; the 30 s poll interval is shortened.
                                                if duration >= .seconds(600) {
                                                    try await Task.sleep(for: .seconds(3600))
                                                } else {
                                                    try await Task.sleep(for: .milliseconds(10))
                                                }
                                            }))
    }

    private func makeRequest(text: String = "只回复 OK", createdAt: Date? = nil,
                             previous: UUID? = nil) -> BridgeRequest {
        BridgeRequest(conversationID: conversationID, bridgeID: bridgeID, profileID: "default",
                      sourceDeviceID: "device-A", text: text, previousMessageID: previous,
                      createdAt: createdAt ?? epoch)
    }

    private var conversationID: UUID { conversation }
    private let conversation = UUID()

    /// Poll rather than sleep a fixed interval: the loop is asynchronous, the assertion is not.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

private extension FakeHermes {
    var subscriptionOrder: [UUID] { submissions.map(\.messageID) }
    var submissionOrder: [UUID] { submissions.map(\.messageID) }
}
