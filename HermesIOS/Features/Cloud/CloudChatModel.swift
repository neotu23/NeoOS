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
    private(set) var isEnqueuing = false
    private(set) var selectedProfileID: String
    private(set) var isConfiguring = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var configurationID = UUID()
    @ObservationIgnored private var reloadID = UUID()
    @ObservationIgnored private var retryNotBefore: Date?

    private var store: BridgeStore?
    private var mailbox: (any MailboxTransport)?
    private let defaults: UserDefaults
    private let deviceID: String
    /// Chosen Mac. Stored per account through the store, not in the direct connection JSON.
    private(set) var selectedBridgeID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.deviceID = Self.persistentDeviceID(defaults: defaults)
        selectedProfileID = defaults.string(forKey: "cloudProfileID") ?? "default"
        selectedBridgeID = defaults.string(forKey: "cloudBridgeID").flatMap(UUID.init(uuidString:))
    }

    var canSend: Bool {
        guard !isEnqueuing, !isConfiguring, store != nil, mailbox != nil else { return false }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard draft.utf8.count <= BridgeLimits.requestTextBytes else { return false }
        if case .unconfigured = status { return false }
        return selectedBridgeID != nil
    }

    var isConfigured: Bool { store != nil && selectedBridgeID != nil }

    // MARK: - Lifecycle

    /// Build the mailbox. CloudKit needs a container, an iCloud account and a chosen Mac; without
    /// them the screen stays honest instead of queueing messages nobody will ever read.
    func configure(containerID: String, environment: String) async {
        let generation = beginConfiguration()
        isConfiguring = true
        store = nil
        mailbox = nil
        activeConversationID = nil
        conversations = []
        messages = []
        status = .syncing
        defer { if configurationID == generation { isConfiguring = false } }
        do {
            let adapter = CloudKitDatabaseAdapter(configuration: .init(containerIdentifier: containerID,
                                                                       environment: environment))
            let scope: AccountScope
            do {
                scope = try await adapter.account()
                guard configurationID == generation else { return }
            } catch {
                guard configurationID == generation else { return }
                status = .unconfigured("iCloud 不可用：\(error)")
                return
            }
            let path = try storePath(scope: scope)
            let store = try BridgeStore(path: path, scope: scope)
            self.store = store
            // Discovery must keep all Macs; choosing another device must not leave a stale codec filter.
            let codec = CloudRecordCodec()
            let mailbox = CloudMailbox(store: store, adapter: adapter, codec: codec)
            self.mailbox = mailbox
            isConfiguring = false
            status = .ready
            await reload()
            guard configurationID == generation else { return }
            await refresh()
        } catch {
            guard configurationID == generation else { return }
            status = .failed("无法打开本地消息库：\(error)")
        }
    }

    func selectDevice(_ bridgeID: UUID, name: String, profileID: String = "default") async {
        if selectedBridgeID != bridgeID || selectedProfileID != profileID {
            activeConversationID = nil
            messages = []
        }
        selectedBridgeID = bridgeID
        selectedProfileID = profileID
        defaults.set(profileID, forKey: "cloudProfileID")
        deviceName = name
        defaults.set(bridgeID.uuidString, forKey: "cloudBridgeID")
        await reload()
    }

    // MARK: - Conversations

    /// Start a conversation owned by this iPhone. Only the creating device appends to it.
    func startConversation(bridgeID: UUID, profileID: String = "default") async {
        guard !isEnqueuing, !isConfiguring, let store else { return }
        let generation = configurationID
        do {
            let id = try await createConversation(bridgeID: bridgeID, profileID: profileID, in: store)
            guard configurationID == generation, selectedBridgeID == bridgeID,
                  selectedProfileID == profileID else { return }
            activeConversationID = id
            await reload()
        } catch {
            guard configurationID == generation else { return }
            status = .failed("无法创建对话：\(error)")
        }
    }

    private func createConversation(bridgeID: UUID, profileID: String, in store: BridgeStore) async throws -> UUID {
        let conversation = BridgeConversation(bridgeID: bridgeID, profileID: profileID,
                                              sourceDeviceID: deviceID, title: "NeoOS", createdAt: Date())
        try await store.enqueueConversation(conversation)
        return conversation.conversationID
    }

    // MARK: - Sending

    /// Commit locally before touching CloudKit. A slow pull must never hold the user's text hostage.
    func enqueueText() async {
        guard canSend, let store, let bridgeID = selectedBridgeID else { return }
        isEnqueuing = true
        let generation = configurationID
        let text = draft
        let profileID = selectedProfileID
        let selectedConversation = activeConversationID
        do {
            defer { if configurationID == generation { isEnqueuing = false } }
            let conversationID: UUID
            if let selectedConversation, let conversation = try await store.conversation(selectedConversation),
               conversation.bridgeID == bridgeID, conversation.profileID == profileID,
               conversation.sourceDeviceID == deviceID {
                conversationID = selectedConversation
            } else {
                guard configurationID == generation else { return }
                conversationID = try await createConversation(bridgeID: bridgeID, profileID: profileID, in: store)
                guard configurationID == generation else { return }
                if selectedBridgeID == bridgeID, selectedProfileID == profileID,
                   activeConversationID == selectedConversation { activeConversationID = conversationID }
            }
            guard configurationID == generation else { return }
            let entries = try await store.conversationEntries(conversationID)
            guard configurationID == generation else { return }
            let request = BridgeRequest(conversationID: conversationID, bridgeID: bridgeID,
                                       profileID: profileID, sourceDeviceID: deviceID,
                                       text: text, previousMessageID: entries.last?.messageID, createdAt: Date())
            _ = try await store.enqueue(request, clearingDraftFor: conversationID)
            guard configurationID == generation else { return }
            if draft == text { draft = "" }
            await reload()
        } catch {
            guard configurationID == generation else { return }
            status = .failed("无法保存消息：\(error)")
            return
        }
        guard configurationID == generation else { return }
        // synchronize owns upload confirmation and errors; never upload the same row a second time.
        await refresh()
    }

    func requestCancel(messageID: UUID) async {
        guard let store, let bridgeID = selectedBridgeID else { return }
        let generation = configurationID
        let control = BridgeControl(messageID: messageID, bridgeID: bridgeID, createdAt: Date())
        let codec = CloudRecordCodec(scope: RecordScope(bridgeID: bridgeID, profileID: nil))
        do {
            let record = try codec.encode(control)
            _ = try await mailbox?.publish(record)
            guard configurationID == generation else { return }
            _ = try await store.applyRemotePage(RemotePage(changes: [.control(control)]))
            guard configurationID == generation else { return }
            await reload()
        } catch {
            guard configurationID == generation else { return }
            status = .failed("无法取消任务：\(error)")
        }
    }

    // MARK: - Sync

    @discardableResult
    private func beginConfiguration() -> UUID {
        configurationID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        retryNotBefore = nil
        reloadID = UUID()
        isEnqueuing = false
        return configurationID
    }

    func refresh() async {
        guard !isConfiguring else { return }
        if let retryNotBefore, retryNotBefore > Date() { return }
        if let refreshTask { await refreshTask.value; return }
        let generation = configurationID
        let task = Task { await performRefresh(generation: generation) }
        refreshTask = task
        await task.value
        if configurationID == generation { refreshTask = nil }
    }

    private func performRefresh(generation: UUID) async {
        guard configurationID == generation, let store, let mailbox else { return }
        status = .syncing
        var needsReload = false
        do {
            let summary = try await mailbox.synchronize()
            guard configurationID == generation, self.store === store else { return }
            lastSyncAt = Date()
            retryNotBefore = nil
            status = .ready
            needsReload = summary.saved > 0 || summary.received > 0 || summary.failed > 0
        } catch MailboxError.accountChanged {
            guard configurationID == generation else { return }
            status = .failed("iCloud 账号已更改。请重新连接 iCloud 并选择这台 Mac。")
            needsReload = true
        } catch {
            guard configurationID == generation else { return }
            var retryAfter: TimeInterval?
            if case MailboxError.transport(_, let delay) = error { retryAfter = delay }
            if case AdapterError.transport(_, let delay) = error { retryAfter = delay }
            if let retryAfter, retryAfter > 0 { retryNotBefore = Date().addingTimeInterval(retryAfter) }
            status = .failed(String(describing: error))
            needsReload = true
        }
        // An empty delta cannot have changed the transcript. Avoid rereading the entire history
        // on every foreground poll, especially while the user is composing a message.
        if needsReload { await reload() }
    }

    /// Load the projections the UI shows. Reads only; nothing here writes to CloudKit.
    func reload() async {
        guard let store else { return }
        let invocation = UUID()
        reloadID = invocation
        // Read a stable selection. None of the awaits below may overwrite a newer chat/device choice.
        let bridgeID = selectedBridgeID
        let profileID = selectedProfileID
        let requestedActive = activeConversationID
        var summaries: [CloudConversationSummary] = []
        if let ids = try? await store.conversationIDs() {
            for id in ids {
                guard let conversation = try? await store.conversation(id),
                      conversation.bridgeID == bridgeID, conversation.profileID == profileID,
                      conversation.sourceDeviceID == deviceID else { continue }
                let entries = (try? await store.conversationEntries(id)) ?? []
                summaries.append(CloudConversationSummary(id: id, title: conversation.title,
                    lastMessageAt: entries.last?.createdAt ?? conversation.createdAt, messageCount: entries.count))
            }
        }
        summaries.sort { $0.lastMessageAt > $1.lastMessageAt }
        let active = requestedActive.flatMap { id in summaries.contains(where: { $0.id == id }) ? id : nil }
            ?? summaries.first?.id
        var loaded: [CloudMessage] = []
        if let active {
            let entries = (try? await store.conversationEntries(active)) ?? []
            for entry in entries {
                let text = (try? await store.request(messageID: entry.messageID))?.text ?? ""
                let answer = (try? await store.result(messageID: entry.messageID))?.content.inlineText
                loaded.append(CloudMessage(id: entry.messageID, text: text, state: entry.state,
                                           answer: answer, createdAt: entry.createdAt))
            }
        }
        let device = (try? await store.devices())?.first(where: { $0.bridgeID == bridgeID })
        guard reloadID == invocation, self.store === store,
              selectedBridgeID == bridgeID, selectedProfileID == profileID,
              activeConversationID == requestedActive else { return }
        if conversations != summaries { conversations = summaries }
        activeConversationID = active
        if messages != loaded { messages = loaded }
        if let device { deviceName = device.name }
    }

    /// Bridges this device has heard from. Discovery is a pull, never a fake "online" list.
    func knownDevices() async throws -> [BridgeDevice] {
        try await store?.devices() ?? []
    }

    #if DEBUG
    // MARK: - Test fixture (DEBUG)

    /// Wire the model to an injected store and mailbox; used by `CloudFixtureMailbox`.
    func attachFixture(store: BridgeStore, mailbox: any MailboxTransport, bridgeID: UUID) {
        beginConfiguration()
        isConfiguring = false
        self.store = store
        self.mailbox = mailbox
        self.selectedBridgeID = bridgeID
        self.selectedProfileID = "default"
        self.deviceName = "Fixture Mac"
        status = .ready
    }

    /// One message per interesting state, so a UI test can compare the labels.
    func seedFixtureStates(bridgeID: UUID) async {
        guard let store else { return }
        let conversation = BridgeConversation(bridgeID: bridgeID, profileID: "default",
                                              sourceDeviceID: deviceID, title: "Fixture",
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
