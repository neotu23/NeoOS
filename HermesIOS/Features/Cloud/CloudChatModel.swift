import Foundation
import Observation
import CloudBridgeCore
import CloudBridgeSync

/// One message the user can see: a request plus whatever answer exists for it.
struct CloudMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String
    let state: DeliveryState
    let answer: String?
    let createdAt: Date
}

struct CloudConversationSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let lastMessageAt: Date
    let messageCount: Int
}

/// The cloud-mode screen's model.
///
/// It is deliberately separate from `AppModel`: the direct connection's state machine is about a live
/// socket, and pretending a cloud mailbox is "connected" would misreport both. Nothing here writes to
/// the direct connection's stored settings.
@MainActor
@Observable
final class CloudChatModel {
    enum Status: Equatable {
        case unconfigured(String)
        case ready
        case syncing
        case failed(String)
    }

    private(set) var status: Status = .unconfigured("iCloud 尚未配置")
    private(set) var conversations: [CloudConversationSummary] = []
    private(set) var messages: [CloudMessage] = []
    private(set) var deviceName: String?
    private(set) var lastSyncAt: Date?
    var activeConversationID: UUID?
    var draft: String = ""

    private var store: BridgeStore?
    private var mailbox: (any MailboxTransport)?
    private let defaults: UserDefaults
    private let deviceID: String
    /// Chosen Mac. Stored per account through the store, not in the direct connection JSON.
    private(set) var selectedBridgeID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.deviceID = Self.persistentDeviceID(defaults: defaults)
        selectedBridgeID = defaults.string(forKey: "cloudBridgeID").flatMap(UUID.init(uuidString:))
    }

    var canSend: Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard draft.utf8.count <= BridgeLimits.requestTextBytes else { return false }
        if case .unconfigured = status { return false }
        return activeConversationID != nil && selectedBridgeID != nil
    }

    var isConfigured: Bool { store != nil && selectedBridgeID != nil }

    // MARK: - Lifecycle

    /// Build the mailbox. CloudKit needs a container, an iCloud account and a chosen Mac; without
    /// them the screen stays honest instead of queueing messages nobody will ever read.
    func configure(containerID: String, environment: String) async {
        do {
            let adapter = CloudKitDatabaseAdapter(configuration: .init(containerIdentifier: containerID,
                                                                       environment: environment))
            let scope: AccountScope
            do {
                scope = try await adapter.account()
            } catch {
                status = .unconfigured("iCloud 不可用：\(error)")
                return
            }
            let path = try storePath(scope: scope)
            let store = try BridgeStore(path: path, scope: scope)
            self.store = store
            let codec = CloudRecordCodec(scope: RecordScope(bridgeID: selectedBridgeID, profileID: nil))
            let mailbox = CloudMailbox(store: store, adapter: adapter, codec: codec)
            self.mailbox = mailbox
            status = .ready
            await refresh()
        } catch {
            status = .failed("无法打开本地消息库：\(error)")
        }
    }

    func selectDevice(_ bridgeID: UUID, name: String) {
        selectedBridgeID = bridgeID
        deviceName = name
        defaults.set(bridgeID.uuidString, forKey: "cloudBridgeID")
    }

    // MARK: - Conversations

    /// Start a conversation owned by this iPhone. Only the creating device appends to it.
    func startConversation(bridgeID: UUID, profileID: String = "default") async {
        guard let store else { return }
        let conversation = BridgeConversation(bridgeID: bridgeID, profileID: profileID,
                                              sourceDeviceID: deviceID,
                                              title: "NeoOS", createdAt: Date())
        let codec = CloudRecordCodec(scope: RecordScope(bridgeID: bridgeID, profileID: profileID))
        if let record = try? codec.encode(conversation) {
            _ = try? await mailbox?.publish(record)
        }
        _ = try? await store.applyRemotePage(RemotePage(changes: [.conversation(conversation)]))
        activeConversationID = conversation.conversationID
        await refresh()
    }

    // MARK: - Sending

    /// Queue one message. The draft is only cleared once the row and the outbox entry are committed.
    func enqueueText() async {
        guard let store, let conversationID = activeConversationID, let bridgeID = selectedBridgeID else { return }
        let text = draft
        let request = BridgeRequest(conversationID: conversationID, bridgeID: bridgeID,
                                   profileID: "default", sourceDeviceID: deviceID,
                                   text: text, previousMessageID: try? await previousMessageID(),
                                   createdAt: Date())
        do {
            try request.validated()
            let record = try await store.enqueue(request, clearingDraftFor: conversationID)
            draft = ""
            await refresh()
            // Upload now; a failure leaves the row in the outbox for the next sync.
            _ = try? await mailbox?.publish(record)
            await refresh()
        } catch let error as BridgeValidationError {
            status = .failed(error.description)
        } catch {
            status = .failed("无法保存草稿：\(error)")
        }
    }

    private func previousMessageID() async throws -> UUID? {
        messages.last?.id
    }

    func requestCancel(messageID: UUID) async {
        guard let store, let bridgeID = selectedBridgeID else { return }
        let control = BridgeControl(messageID: messageID, bridgeID: bridgeID, createdAt: Date())
        let codec = CloudRecordCodec(scope: RecordScope(bridgeID: bridgeID, profileID: nil))
        if let record = try? codec.encode(control) {
            _ = try? await mailbox?.publish(record)
        }
        _ = try? await store.applyRemotePage(RemotePage(changes: [.control(control)]))
        await refresh()
    }

    // MARK: - Sync

    func refresh() async {
        guard let store, let mailbox else { return }
        if case .syncing = status {} else { status = .syncing }
        do {
            _ = try await mailbox.synchronize()
            lastSyncAt = Date()
            status = .ready
        } catch MailboxError.accountChanged {
            status = .failed("iCloud 账号已更改。请重新选择这台 Mac。")
        } catch {
            status = .failed(String(describing: error))
        }
        await reload()
    }

    /// Load the projections the UI shows. Reads only; nothing here writes to CloudKit.
    func reload() async {
        guard let store else { return }
        var summaries: [CloudConversationSummary] = []
        if let ids = try? await store.conversationIDs() {
            for id in ids {
                let entries = (try? await store.conversationEntries(id)) ?? []
                summaries.append(CloudConversationSummary(id: id,
                                                          title: "对话 \(id.uuidString.prefix(6))",
                                                          lastMessageAt: entries.last?.createdAt ?? Date.distantPast,
                                                          messageCount: entries.count))
            }
        }
        conversations = summaries.sorted { $0.lastMessageAt > $1.lastMessageAt }
        if activeConversationID == nil { activeConversationID = conversations.first?.id }
        guard let active = activeConversationID else {
            messages = []
            return
        }
        let entries = (try? await store.conversationEntries(active)) ?? []
        var loaded: [CloudMessage] = []
        for entry in entries {
            let text = (try? await store.request(messageID: entry.messageID))?.text ?? ""
            let answer = (try? await store.result(messageID: entry.messageID))?.content.inlineText
            loaded.append(CloudMessage(id: entry.messageID, text: text, state: entry.state,
                                       answer: answer, createdAt: entry.createdAt))
        }
        messages = loaded.sorted { $0.createdAt < $1.createdAt }
        if let devices = try? await store.devices(), let chosen = selectedBridgeID,
           let device = devices.first(where: { $0.bridgeID == chosen }) {
            deviceName = device.name
        }
    }

    /// Bridges this device has heard from. Discovery is a pull, never a fake "online" list.
    func knownDevices() async throws -> [BridgeDevice] {
        try await store?.devices() ?? []
    }

    #if DEBUG
    // MARK: - Test fixture (DEBUG)

    /// Wire the model to an injected store and mailbox; used by `CloudFixtureMailbox`.
    func attachFixture(store: BridgeStore, mailbox: CloudFixtureMailbox, bridgeID: UUID) {
        self.store = store
        self.mailbox = mailbox
        self.selectedBridgeID = bridgeID
        self.deviceName = "Fixture Mac"
        status = .ready
    }

    /// One message per interesting state, so a UI test can compare the labels.
    func seedFixtureStates(bridgeID: UUID) async {
        guard let store else { return }
        let conversation = BridgeConversation(bridgeID: bridgeID, profileID: "default",
                                              sourceDeviceID: "fixture", title: "Fixture",
                                              createdAt: Date())
        _ = try? await store.applyRemotePage(RemotePage(changes: [.conversation(conversation)]))
        activeConversationID = conversation.conversationID
        let states: [(String, DeliveryState)] = [("已上传的消息", .uploaded), ("正在执行的作业", .running)]
        for (index, entry) in states.enumerated() {
            let request = BridgeRequest(conversationID: conversation.conversationID, bridgeID: bridgeID,
                                        profileID: "default", sourceDeviceID: "fixture",
                                        text: entry.0, createdAt: Date().addingTimeInterval(Double(index)))
            _ = try? await store.applyRemotePage(RemotePage(changes: [.request(request)]))
            _ = try? await store.applyRemotePage(
                RemotePage(changes: [.execution(ExecutionUpdate(messageID: request.messageID,
                                                                state: entry.1, revision: 1,
                                                                updatedAt: Date()))]))
        }
        await reload()
    }
    #endif

    // MARK: - Paths

    private func storePath(scope: AccountScope) throws -> String {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw CocoaError(.fileNoSuchFile) }
        let directory = base.appendingPathComponent("NeoOSCloud", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Per account: switching iCloud users cannot even open the previous user's rows.
        return directory.appendingPathComponent("mailbox-\(scope.storageKey).sqlite").path
    }

    private static func persistentDeviceID(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: "cloudDeviceID") { return stored }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: "cloudDeviceID")
        return generated
    }
}
