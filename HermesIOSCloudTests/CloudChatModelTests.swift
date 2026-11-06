import XCTest
import CloudBridgeCore
import CloudBridgeSync
@testable import NeoOSCloudChat

@MainActor
final class CloudChatModelTests: XCTestCase {
    func testFirstMessageCreatesConversationWithoutVisitingSettings() async throws {
        let model = await CloudChatModel.fixture(offline: false, seedStates: false)
        model.draft = "第一条消息"
        XCTAssertTrue(model.canSend, "choosing a Mac is sufficient; no hidden new-chat step")
        await model.enqueueText()
        XCTAssertEqual(model.messages.map(\.text), ["第一条消息"])
        XCTAssertNotNil(model.activeConversationID)
        XCTAssertEqual(model.draft, "")
    }

    func testOfflineFirstMessageIsVisibleAndKeepsUploadError() async throws {
        let model = await CloudChatModel.fixture(offline: true, seedStates: false)
        model.draft = "离线保存"
        await model.enqueueText()
        XCTAssertEqual(model.messages.map(\.text), ["离线保存"])
        XCTAssertEqual(model.draft, "")
        guard case .failed = model.status else { return XCTFail("show why upload is pending") }
    }

    func testMessageAppearsBeforeSlowNetworkAndNextDraftSurvives() async throws {
        let suite = "CloudChatModelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CloudChatModel(defaults: defaults)
        let store = try BridgeStore(inMemoryScope: slowScope)
        let mailbox = SuspendedMailbox()
        model.attachFixture(store: store, mailbox: mailbox, bridgeID: UUID())
        model.draft = "先显示的消息"
        let send = Task { await model.enqueueText() }
        await mailbox.waitUntilStarted()
        XCTAssertEqual(model.messages.map(\.text), ["先显示的消息"])
        XCTAssertEqual(model.draft, "")
        model.draft = "网络仍在等待时输入的下一条"
        await mailbox.finish()
        await send.value
        XCTAssertEqual(model.draft, "网络仍在等待时输入的下一条")
    }

    func testChangingMacAndProfileStartsSeparateConversation() async throws {
        let model = await CloudChatModel.fixture(offline: false, seedStates: true)
        let oldID = model.activeConversationID
        await model.selectDevice(UUID(), name: "Work Mac", profileID: "work")
        XCTAssertNil(model.activeConversationID)
        XCTAssertTrue(model.messages.isEmpty)
        model.draft = "给另一台 Mac"
        await model.enqueueText()
        XCTAssertNotEqual(model.activeConversationID, oldID)
        XCTAssertEqual(model.messages.map(\.text), ["给另一台 Mac"])
        XCTAssertEqual(model.selectedProfileID, "work")
    }

    func testForegroundRefreshRespectsCloudKitRetryAfter() async throws {
        let suite = "CloudChatRetryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CloudChatModel(defaults: defaults)
        let store = try BridgeStore(inMemoryScope: slowScope)
        let mailbox = RateLimitedMailbox()
        model.attachFixture(store: store, mailbox: mailbox, bridgeID: UUID())
        await model.refresh()
        await model.refresh()
        let attempts = await mailbox.attempts
        XCTAssertEqual(attempts, 1, "foreground polling must honor the server's retry deadline")
    }

    func testReplacingMailboxDoesNotReuseOldSyncOrOverwriteNewStatus() async throws {
        let suite = "CloudChatReplaceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CloudChatModel(defaults: defaults)
        let store = try BridgeStore(inMemoryScope: slowScope)
        let oldMailbox = SuspendedMailbox()
        model.attachFixture(store: store, mailbox: oldMailbox, bridgeID: UUID())
        let oldRefresh = Task { await model.refresh() }
        await oldMailbox.waitUntilStarted()
        model.attachFixture(store: store, mailbox: CloudFixtureMailbox(offline: true), bridgeID: UUID())
        let newRefresh = Task { await model.refresh() }
        await Task.yield()
        await oldMailbox.finish()
        await oldRefresh.value
        await newRefresh.value
        guard case .failed(let reason) = model.status else {
            return XCTFail("the new mailbox must sync independently of the old one")
        }
        XCTAssertTrue(reason.contains("offline"))
    }

    func testConcurrentSendDoesNotDuplicateDraft() async throws {
        let model = await CloudChatModel.fixture(offline: false, seedStates: true)
        model.draft = "只发送一次"
        async let first: Void = model.enqueueText()
        async let second: Void = model.enqueueText()
        _ = await (first, second)
        XCTAssertEqual(model.messages.filter { $0.text == "只发送一次" }.count, 1)
    }
}

private let slowScope = AccountScope(containerID: "iCloud.test", environment: "development", userRecordName: "test")

private actor SuspendedMailbox: MailboxTransport {
    private var operation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func accountScope() async throws -> AccountScope { slowScope }
    func synchronize() async throws -> SyncSummary {
        await withCheckedContinuation { continuation in
            operation = continuation
            started?.resume()
            started = nil
        }
        return SyncSummary()
    }
    func publish(_ record: OutboundRecord) async throws -> PublishReceipt {
        PublishReceipt(recordName: record.recordName, confirmedAt: Date())
    }
    func waitUntilStarted() async {
        if operation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { operation?.resume(); operation = nil }
}

private actor RateLimitedMailbox: MailboxTransport {
    private(set) var attempts = 0
    func accountScope() async throws -> AccountScope { slowScope }
    func synchronize() async throws -> SyncSummary {
        attempts += 1
        throw MailboxError.transport("稍后重试", retryAfter: 120)
    }
    func publish(_ record: OutboundRecord) async throws -> PublishReceipt {
        throw MailboxError.transport("稍后重试", retryAfter: 120)
    }
}
