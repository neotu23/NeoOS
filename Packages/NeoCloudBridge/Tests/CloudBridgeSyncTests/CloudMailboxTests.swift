import XCTest
import CloudBridgeCore
@testable import CloudBridgeSync

/// A scripted stand-in for CloudKit: no account, no network, full control over pages and outcomes.
///
/// A lock-protected class rather than an actor: the adapter protocol is a plain `Sendable` contract
/// (the real CloudKit client is not an actor either), so the fake matches that shape.
final class FakeDatabase: CloudDatabaseAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var _scope: AccountScope
    private var stored: [String: Data] = [:]
    private var pages: [AdapterChanges]
    private var scriptedOutcomes: [String: AdapterSaveOutcome]
    private var expireTokenOnce = false
    private var _fetchCount = 0
    private var _saveCount = 0
    private var _subscribeCount = 0
    private var _savedNames: [String] = []

    init(scope: AccountScope, pages: [AdapterChanges] = [],
         outcomes: [String: AdapterSaveOutcome] = [:]) {
        self._scope = scope
        self.pages = pages
        self.scriptedOutcomes = outcomes
    }

    var fetchCount: Int { lock.withLock { _fetchCount } }
    var saveCount: Int { lock.withLock { _saveCount } }
    var subscribeCount: Int { lock.withLock { _subscribeCount } }
    var savedNames: [String] { lock.withLock { _savedNames } }

    func setScope(_ scope: AccountScope) { lock.withLock { _scope = scope } }
    func seed(_ recordName: String, body: Data) { lock.withLock { stored[recordName] = body } }
    func enqueuePage(_ page: AdapterChanges) { lock.withLock { pages.append(page) } }

    /// The next `fetchChanges` throws `tokenExpired`, as CloudKit does after a long offline period.
    func expireNextToken() { lock.withLock { expireTokenOnce = true } }

    func script(_ outcome: AdapterSaveOutcome, for recordName: String) {
        lock.withLock { scriptedOutcomes[recordName] = outcome }
    }

    // MARK: CloudDatabaseAdapter

    func account() async throws -> AccountScope { lock.withLock { _scope } }

    func ensureZone() async throws {}

    func subscribe() async throws { lock.withLock { _subscribeCount += 1 } }

    func fetchChanges(token: Data?, limit: Int) async throws -> AdapterChanges {
        try lock.withLock {
            _fetchCount += 1
            if expireTokenOnce {
                expireTokenOnce = false
                throw AdapterError.tokenExpired
            }
            guard !pages.isEmpty else { return AdapterChanges(newToken: token, moreComing: false) }
            return pages.removeFirst()
        }
    }

    func fetch(recordName: String) async throws -> AdapterRecord? {
        lock.withLock {
            guard let body = stored[recordName] else { return nil }
            return AdapterRecord(recordName: recordName, body: body)
        }
    }

    func save(_ records: [OutboundRecord]) async throws -> [AdapterSaveOutcome] {
        lock.withLock {
            _saveCount += 1
            var outcomes: [AdapterSaveOutcome] = []
            for record in records {
                if let scripted = scriptedOutcomes.removeValue(forKey: record.recordName) {
                    if case .saved = scripted { stored[record.recordName] = record.payload }
                    outcomes.append(scripted)
                    continue
                }
                stored[record.recordName] = record.payload
                _savedNames.append(record.recordName)
                outcomes.append(.saved(recordName: record.recordName, changeTag: "tag-\(_savedNames.count)"))
            }
            return outcomes
        }
    }

    func accountChanges() -> AsyncStream<AccountScope?> {
        AsyncStream { $0.finish() }
    }
}

final class CloudMailboxTests: XCTestCase {
    private var directory: URL!
    private let scope = AccountScope(containerID: "iCloud.test.NeoOS", environment: "development",
                                     userRecordName: "_userA")
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private var bridgeID = UUID()
    private var conversationID = UUID()

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("neocloudbridge-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bridgeID = UUID()
        conversationID = UUID()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - Paging

    func testFetchConsumesAllPages() async throws {
        let store = try makeStore()
        let first = makeRequest(text: "第一页")
        let second = makeRequest(text: "第二页", createdAt: epoch.addingTimeInterval(1),
                                 previous: first.messageID)
        let codec = makeCodec()
        let database = FakeDatabase(
            scope: scope,
            pages: [
                AdapterChanges(records: [record(try codec.encode(first))], newToken: Data([1]), moreComing: true),
                AdapterChanges(records: [record(try codec.encode(second))], newToken: Data([2]), moreComing: false),
            ])
        let mailbox = CloudMailbox(store: store, adapter: database, codec: codec) { [epoch] in epoch }

        let summary = try await mailbox.synchronize()

        XCTAssertEqual(summary.received, 2, "both pages' requests were new here")
        XCTAssertEqual(summary.failed, 0)
        let storedToken = try await store.changeToken()
        XCTAssertEqual(storedToken, Data([2]), "the token advances only once every page is durable")
        let entries = try await store.conversationEntries(conversationID)
        XCTAssertEqual(entries.map(\.messageID), [first.messageID, second.messageID])
    }

    func testDuplicatePushCoalescesFetch() async throws {
        let store = try makeStore()
        let codec = makeCodec()
        let database = FakeDatabase(scope: scope, pages: [
            AdapterChanges(records: [record(try codec.encode(makeRequest(text: "唯一一页")))]),
        ])
        let mailbox = CloudMailbox(store: store, adapter: database, codec: codec) { [epoch] in epoch }

        // Two notifications arrive together: they must share one cycle, not race on the token.
        async let first = mailbox.synchronize()
        async let second = mailbox.synchronize()
        _ = try await (first, second)

        let fetches = database.fetchCount
        XCTAssertEqual(fetches, 1, "concurrent refreshes coalesce into one fetch cycle")
    }

    func testExpiredTokenRescanDoesNotRedispatch() async throws {
        let store = try makeStore()
        let codec = makeCodec()
        let request = makeRequest(text: "已经完成的活")
        let result = BridgeResult(messageID: request.messageID, conversationID: conversationID,
                                  bridgeID: bridgeID, content: .inline("done"), contentSHA256: "s",
                                  completedAt: epoch, terminalStatus: .completed)

        // The conversation already completed once.
        let database = FakeDatabase(scope: scope)
        let mailbox = CloudMailbox(store: store, adapter: database, codec: codec) { [epoch] in epoch }
        database.enqueuePage(AdapterChanges(records: [record(try codec.encode(request)),
                                                           record(try codec.encode(result))],
                                                 newToken: Data([7]), moreComing: false))
        _ = try await mailbox.synchronize()
        let completedBefore = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(completedBefore?.state, .completed)

        // Now the token expires and the backend forces a full rescan of the same records.
        database.expireNextToken()
        database.enqueuePage(AdapterChanges(records: [record(try codec.encode(request)),
                                                           record(try codec.encode(result))],
                                                 newToken: Data([8]), moreComing: false))
        _ = try await mailbox.synchronize()

        let after = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(after?.state, .completed, "a rescan must not reopen a finished turn")
        let recoverable = try await store.recoverableExecutions()
        XCTAssertEqual(recoverable, [], "a full rescan must not queue a redispatch")
    }

    // MARK: - Uploads

    func testUploadAckLostReadsBackSameRecord() async throws {
        let store = try makeStore()
        let codec = makeCodec()
        let request = makeRequest(text: "回执丢了")
        let outbound = try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)

        let database = FakeDatabase(scope: scope)
        // The server already holds the same record: the lost-ack case.
        database.seed(outbound.recordName, body: outbound.payload)
        database.script(.conflict(recordName: outbound.recordName), for: outbound.recordName)

        let mailbox = CloudMailbox(store: store, adapter: database, codec: codec) { [epoch] in epoch }
        _ = try await mailbox.synchronize()

        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox, [], "the identical stored record counts as uploaded")
        let journal = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(journal?.state, .uploaded, "uploaded still means waiting for the Mac")
    }

    func testConflictingContentIsNotOverwritten() async throws {
        let store = try makeStore()
        let codec = makeCodec()
        let request = makeRequest(text: "真正的内容")
        let outbound = try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)

        let database = FakeDatabase(scope: scope)
        database.seed(outbound.recordName, body: Data(#"{"someone":"else"}"#.utf8))
        database.script(.conflict(recordName: outbound.recordName), for: outbound.recordName)

        let mailbox = CloudMailbox(store: store, adapter: database, codec: codec) { [epoch] in epoch }
        _ = try await mailbox.synchronize()

        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox.map(\.recordName), [outbound.recordName],
                       "different content is a conflict, not a successful upload")
    }

    func testAccountSwitchDoesNotUploadOldOutbox() async throws {
        let store = try makeStore()
        let codec = makeCodec()
        let request = makeRequest(text: "属于旧账号")
        _ = try await store.enqueue(request, clearingDraftFor: conversationID, now: epoch)

        let otherScope = AccountScope(containerID: scope.containerID, environment: scope.environment,
                                      userRecordName: "_userB")
        let database = FakeDatabase(scope: otherScope)
        let mailbox = CloudMailbox(store: store, adapter: database, codec: codec) { [epoch] in epoch }

        do {
            _ = try await mailbox.synchronize()
            XCTFail("a different iCloud identity must abort the cycle")
        } catch {
            XCTAssertEqual(error as? MailboxError, .accountChanged)
        }

        let saves = database.saveCount
        XCTAssertEqual(saves, 0, "the old account's outbox is never pushed to the new one")
        let outbox = try await store.pendingOutbound()
        XCTAssertEqual(outbox.count, 1)
    }

    func testOrphanResultEventuallyLinks() async throws {
        let store = try makeStore()
        let codec = makeCodec()
        let request = makeRequest(text: "答案先到")
        let result = BridgeResult(messageID: request.messageID, conversationID: conversationID,
                                  bridgeID: bridgeID, content: .inline("42"), contentSHA256: "s",
                                  completedAt: epoch, terminalStatus: .completed)

        let database = FakeDatabase(scope: scope)
        let mailbox = CloudMailbox(store: store, adapter: database, codec: codec) { [epoch] in epoch }

        database.enqueuePage(AdapterChanges(records: [record(try codec.encode(result))],
                                                 newToken: Data([1]), moreComing: false))
        _ = try await mailbox.synchronize()
        let orphan = try await store.result(messageID: request.messageID)
        XCTAssertEqual(orphan?.content.inlineText, "42")
        let noRequest = try await store.request(messageID: request.messageID)
        XCTAssertNil(noRequest)

        database.enqueuePage(AdapterChanges(records: [record(try codec.encode(request))],
                                                 newToken: Data([2]), moreComing: false))
        _ = try await mailbox.synchronize()
        let linked = try await store.executionProjection(messageID: request.messageID)
        XCTAssertEqual(linked?.state, .completed)
    }

    // MARK: - Retry policy

    func testRetryAfterIsRespected() async throws {
        let store = try makeStore()
        let mailbox = CloudMailbox(store: store, adapter: FakeDatabase(scope: scope), codec: makeCodec())

        let vetoed = await mailbox.retryDelay(attempt: 0, retryAfter: 120)
        XCTAssertEqual(vetoed, 120, "Apple's retryAfter wins whenever it is longer")

        let first = await mailbox.retryDelay(attempt: 0, retryAfter: nil)
        XCTAssertGreaterThanOrEqual(first, 2)
        XCTAssertLessThanOrEqual(first, 2.5)

        let saturated = await mailbox.retryDelay(attempt: 20, retryAfter: nil)
        XCTAssertLessThanOrEqual(saturated, 60, "the backoff ceiling is 60 seconds")
    }

    func testReconcileAdoptsANewIdentityAndReportsIt() async throws {
        let store = try makeStore()
        let mailbox = CloudMailbox(store: store, adapter: FakeDatabase(scope: scope), codec: makeCodec())
        let other = AccountScope(containerID: scope.containerID, environment: scope.environment,
                                 userRecordName: "_userB")

        let unchanged = try await mailbox.reconcile(scope)
        XCTAssertFalse(unchanged)
        let changed = try await mailbox.reconcile(other)
        XCTAssertTrue(changed)
        let adopted = await store.accountScope
        XCTAssertEqual(adopted.storageKey, other.storageKey)

        let valid = try await mailbox.reconcile(nil)
        XCTAssertFalse(valid, "signed out keeps the rows but is not reported as a change")
    }

    // MARK: - Helpers

    private func makeStore() throws -> BridgeStore {
        try BridgeStore(path: directory.appendingPathComponent("store.sqlite").path, scope: scope)
    }

    private func makeCodec() -> CloudRecordCodec {
        CloudRecordCodec(scope: RecordScope(bridgeID: bridgeID, profileID: "default"))
    }

    private func makeRequest(text: String, createdAt: Date? = nil, previous: UUID? = nil) -> BridgeRequest {
        BridgeRequest(conversationID: conversationID, bridgeID: bridgeID, profileID: "default",
                      sourceDeviceID: "device-A", text: text, previousMessageID: previous,
                      createdAt: createdAt ?? epoch)
    }

    private func record(_ outbound: OutboundRecord) -> AdapterRecord {
        AdapterRecord(recordName: outbound.recordName, body: outbound.payload)
    }
}
