import Foundation
import CryptoKit
import CloudBridgeCore
import CloudBridgeSync
import HermesBridgeClient

/// Injecting time is what makes "30 seconds later" testable without waiting 30 seconds.
public struct BridgeClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now
        self.sleep = sleep
    }
}

/// Collects Hermes events so one execution can wait for its own terminal frame while the socket
/// keeps delivering everything else.
actor EventInbox {
    private var events: [UUID: [HermesBridgeEvent]] = [:]
    private var unattributed: [HermesBridgeEvent] = []
    private var waiters: [UUID: CheckedContinuation<HermesBridgeEvent?, Never>] = [:]

    func push(_ event: HermesBridgeEvent) {
        if let messageID = event.messageID {
            if let waiter = waiters.removeValue(forKey: messageID) {
                waiter.resume(returning: event)
                return
            }
            events[messageID, default: []].append(event)
        } else {
            unattributed.append(event)
            // A connection-level event has no message: hand it to whoever is waiting.
            if waiters.count == 1, let (id, waiter) = waiters.first {
                waiters.removeValue(forKey: id)
                waiter.resume(returning: event)
            }
        }
    }

    /// Wait for the next event belonging to `messageID`. The timeout is the caller's clock.
    func next(for messageID: UUID, timeout: Duration, clock: BridgeClock) async -> HermesBridgeEvent? {
        if var queued = events[messageID], !queued.isEmpty {
            let event = queued.removeFirst()
            events[messageID] = queued.isEmpty ? nil : queued
            return event
        }
        return await withCheckedContinuation { continuation in
            waiters[messageID] = continuation
            Task { [clock, weak self] in
                try? await clock.sleep(timeout)
                await self?.expire(messageID)
            }
        }
    }

    private func expire(_ messageID: UUID) {
        waiters.removeValue(forKey: messageID)?.resume(returning: nil)
    }
}

public enum BridgePhase: Equatable, Sendable {
    case stopped
    case running
    case paused
    case failed(String)
}

public struct BridgeTaskSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let state: DeliveryState
    public let text: String
    public let errorSummary: String?

    public init(id: UUID, conversationID: UUID, state: DeliveryState, text: String, errorSummary: String?) {
        self.id = id
        self.conversationID = conversationID
        self.state = state
        self.text = text
        self.errorSummary = errorSummary
    }
}

/// The Mac side: pull the mailbox, run one turn at a time, publish the result.
///
/// Everything here is deliberately boring: the interesting decisions were made in
/// `MessageReducer` (may this run?) and `BridgeStore` (is it durable?). This type only sequences
/// them, so a crash between any two steps lands on a journal row rather than in a half-state.
@MainActor
@Observable
public final class BridgeController {
    public private(set) var phase: BridgePhase = .stopped
    public private(set) var activeMessageID: UUID?
    public private(set) var waitingMessageID: UUID?
    public private(set) var waitingReason: String?
    public private(set) var lastSyncAt: Date?
    public private(set) var lastError: String?
    public private(set) var tasks: [BridgeTaskSummary] = []
    public private(set) var accountSummary: String = ""

    public let bridgeID: UUID
    public let bridgeName: String

    private let store: BridgeStore
    private let mailbox: any MailboxTransport
    private let hermes: any HermesExecuting
    private let codec: CloudRecordCodec
    private let clock: BridgeClock
    private let inbox = EventInbox()
    private let profileID: String

    private var loopTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var isDispatching = false
    private var isPaused = false

    /// The fallback pull cadence while bridging (§5.5). A notification only triggers a pull; this is
    /// the belt to its braces.
    private let pollInterval: Duration = .seconds(30)
    /// How long one turn may stay silent before the bridge stops calling it "running".
    private let turnTimeout: Duration = .seconds(600)

    public init(store: BridgeStore, mailbox: any MailboxTransport, hermes: any HermesExecuting,
                codec: CloudRecordCodec, bridgeID: UUID, bridgeName: String,
                profileID: String = "default", clock: BridgeClock = BridgeClock()) {
        self.store = store
        self.mailbox = mailbox
        self.hermes = hermes
        self.codec = codec
        self.bridgeID = bridgeID
        self.bridgeName = bridgeName
        self.profileID = profileID
        self.clock = clock
    }

    // MARK: - Lifecycle

    public func start() {
        guard loopTask == nil else { return }
        isPaused = false
        phase = .running
        startConsumer()
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.recoverPendingWork()
            while !Task.isCancelled {
                await self.refresh()
                await self.drainOne()
                do { try await self.clock.sleep(self.pollInterval) } catch { return }
            }
        }
    }

    /// Pause stops *new* dispatches. A turn already inside Hermes is not replayed or abandoned.
    public func pause() {
        isPaused = true
        phase = .paused
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        phase = .running
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        phase = .stopped
    }

    private func startConsumer() {
        guard consumerTask == nil else { return }
        consumerTask = Task { [weak self, hermes] in
            let stream = await hermes.events()
            for await event in stream {
                guard let self else { return }
                await self.consume(event)
            }
        }
    }

    private func consume(_ event: HermesBridgeEvent) async {
        await inbox.push(event)
        if event.kind == .disconnected, let id = event.messageID {
            // The connection dropped while this turn was in flight: the acknowledgement is unknown.
            try? await store.markUncertain(messageID: id, summary: event.detail, now: clock.now())
            await publishExecution(for: id)
            await refreshTasks()
        }
    }

    // MARK: - Sync

    public func refresh() async {
        do {
            let summary = try await mailbox.synchronize()
            lastSyncAt = clock.now()
            lastError = nil
            if let scope = try? await mailbox.accountScope() {
                accountSummary = scope.environment
            }
            _ = summary
            await refreshTasks()
        } catch MailboxError.accountChanged {
            lastError = "iCloud 账号已更改；旧账号的队列不会被上传。"
            await refreshTasks()
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Recovery

    /// Before anything new runs, settle what a previous run left unresolved.
    public func recoverPendingWork() async {
        guard let recoverable = try? await store.recoverableExecutions() else { return }
        for journal in recoverable {
            let outcome = (try? await hermes.recover(journal)) ?? .unknown
            switch outcome {
            case .confirmedNotSent:
                // Nothing was sent. Leave it received so the normal scheduler can pick it up.
                if journal.state != .received {
                    try? await store.markUncertain(messageID: journal.messageID,
                                                   summary: "上一次没有发送成功，等待重新调度",
                                                   now: clock.now())
                }
            case .completed:
                break
            case .pending:
                break
            case .rejected:
                try? await store.fail(messageID: journal.messageID, code: "rejected",
                                      summary: "Hermes 拒绝了这次提交", now: clock.now())
            case .unknown:
                // No admission lookup on this backend: say so instead of guessing.
                try? await store.markUncertain(messageID: journal.messageID,
                                               summary: "提交后连接中断，无法确认是否已执行",
                                               now: clock.now())
                await publishExecution(for: journal.messageID)
            }
        }
        await refreshTasks()
    }

    // MARK: - Dispatch

    /// Run at most one turn, in the conversation that is ready first.
    public func drainOne() async {
        guard !isPaused, !isDispatching else { return }
        guard let conversations = try? await store.conversationIDs() else { return }
        for conversationID in conversations {
            guard let entries = try? await store.conversationEntries(conversationID) else { continue }
            switch MessageReducer.dispatchDecision(in: entries) {
            case .dispatch(let messageID):
                await execute(messageID)
                return
            case .blockedByPredecessor(_, _, _), .conversationConflict(_, _):
                await refreshTasks()
            case .idle, .inFlight, .waitForDependency:
                continue
            }
        }
    }

    private func execute(_ messageID: UUID) async {
        guard let request = try? await store.request(messageID: messageID) else { return }
        isDispatching = true
        activeMessageID = messageID
        defer {
            isDispatching = false
            activeMessageID = nil
        }

        // Journal first, then the network. A crash in between leaves `dispatching`, which recovery
        // treats as "unknown", never as "send it again".
        do {
            try await store.beginDispatch(messageID: messageID, now: clock.now())
        } catch {
            lastError = String(describing: error)
            return
        }
        await publishExecution(for: messageID)

        let conversation = BridgeConversation(conversationID: request.conversationID, bridgeID: request.bridgeID,
                                              profileID: request.profileID, sourceDeviceID: request.sourceDeviceID,
                                              title: "", createdAt: request.createdAt)
        let session: HermesSession
        let journal = try? await store.executionProjection(messageID: messageID)
        if journal != nil {
            // The stored session id is the durable handle; the in-memory hint only fills first use.
            let storedID = (try? await store.hermesStoredSessionID(messageID: messageID)) ?? nil
            if let storedID, let resumed = try? await resumeSession(storedID: storedID, profile: request.profileID) {
                session = resumed
            } else if let created = try? await hermes.resolveConversation(conversation) {
                session = created
            } else {
                await markBlocked(messageID: messageID, reason: "无法建立本机 Hermes 会话")
                return
            }
        } else {
            await markBlocked(messageID: messageID, reason: "找不到本地记录")
            return
        }
        ConversationHints.remember(session.storedSessionID, for: request.conversationID)

        let admission: Admission
        do {
            admission = try await hermes.submit(request, in: session)
        } catch {
            // The failure is unambiguous and happened before acceptance: not an ambiguity.
            try? await store.fail(messageID: messageID, code: "submit_failed",
                                  summary: String(describing: error).prefix(400).description,
                                  now: clock.now())
            await publishExecution(for: messageID)
            await refreshTasks()
            return
        }

        try? await store.recordAdmission(messageID: messageID, admission: admission,
                                         storedSessionID: session.storedSessionID, now: clock.now())
        await publishExecution(for: messageID)
        await refreshTasks()

        // Wait for this turn's terminal frame on the connection that is already open.
        var sawProgress = false
        while let event = await inbox.next(for: messageID, timeout: turnTimeout, clock: clock) {
            switch event.kind {
            case .started, .progress:
                if !sawProgress {
                    sawProgress = true
                    try? await store.markRunning(messageID: messageID, now: clock.now())
                    await publishExecution(for: messageID)
                }
            case .completed:
                await finish(messageID: messageID, request: request, text: event.text ?? "")
                return
            case .failed:
                try? await store.fail(messageID: messageID, code: "turn_failed",
                                      summary: event.detail, now: clock.now())
                await publishExecution(for: messageID)
                await refreshTasks()
                return
            case .interactive:
                // The cloud channel cannot answer a question. Hold the task and say why.
                waitingMessageID = messageID
                waitingReason = event.text ?? event.detail ?? "Hermes 需要人工确认"
                try? await store.markWaitingOnMac(messageID: messageID, summary: waitingReason,
                                                  now: clock.now())
                await publishExecution(for: messageID)
                await refreshTasks()
                return
            case .interrupted:
                try? await store.fail(messageID: messageID, code: "interrupted",
                                      summary: "任务已被停止", now: clock.now())
                await publishExecution(for: messageID)
                await refreshTasks()
                return
            case .disconnected:
                try? await store.markUncertain(messageID: messageID,
                                               summary: "连接中断，无法确认执行结果",
                                               now: clock.now())
                await publishExecution(for: messageID)
                await refreshTasks()
                return
            }
        }
        // No terminal frame: an absence of evidence is not a completion.
        try? await store.markUncertain(messageID: messageID,
                                       summary: "等待 Hermes 结果超时，未收到最终回复",
                                       now: clock.now())
        await publishExecution(for: messageID)
        await refreshTasks()
    }

    private func finish(messageID: UUID, request: BridgeRequest, text: String) async {
        let payload = text.isEmpty ? "（Hermes 返回了空回复）" : text
        let hash = Self.sha256Hex(payload)
        let content: BridgeResultContent
        if payload.utf8.count <= BridgeLimits.inlineResultBytes {
            content = .inline(payload)
        } else {
            // Too large for a record field: it becomes an asset, never a truncated "answer".
            content = .asset(ResultAsset(fileToken: Self.stash(payload, messageID: messageID) ?? "",
                                         byteCount: payload.utf8.count))
        }
        let result = BridgeResult(messageID: messageID, conversationID: request.conversationID,
                                  bridgeID: request.bridgeID, content: content,
                                  contentSHA256: hash, completedAt: clock.now(),
                                  terminalStatus: .completed)
        do {
            let outbound = try await store.finish(messageID: messageID, result: result, now: clock.now())
            // Upload failure retries this record; it never re-asks Hermes.
            _ = try? await mailbox.publish(outbound)
        } catch {
            lastError = String(describing: error)
        }
        await publishExecution(for: messageID)
        await refreshTasks()
    }

    private func markBlocked(messageID: UUID, reason: String) async {
        try? await store.fail(messageID: messageID, code: "bridge_unavailable", summary: reason,
                              now: clock.now())
        await publishExecution(for: messageID)
        await refreshTasks()
    }

    private func resumeSession(storedID: String, profile: String) async throws -> HermesSession {
        if let client = hermes as? LocalHermesClient {
            return try await client.resume(storedID: storedID)
        }
        return HermesSession(storedSessionID: storedID, runtimeSessionID: storedID, profileID: profile)
    }

    // MARK: - User actions

    /// Stop the task the user is looking at. Hermes only gets a best-effort interrupt, and the
    /// journal is not marked `cancelled` until a terminal frame proves it stopped.
    public func interruptActiveTask() async {
        guard let messageID = activeMessageID ?? waitingMessageID else { return }
        let projection = try? await store.executionProjection(messageID: messageID)
        let stored = try? await store.hermesStoredSessionID(messageID: messageID)
        let journal = ExecutionJournal(messageID: messageID,
                                       conversationID: (try? await store.request(messageID: messageID))?.conversationID ?? UUID(),
                                       bridgeID: bridgeID,
                                       state: projection?.state ?? .running,
                                       revision: projection?.revision ?? 0,
                                       updatedAt: projection?.updatedAt ?? clock.now(),
                                       hermesStoredSessionID: stored ?? nil)
        try? await hermes.interrupt(journal)
        waitingMessageID = nil
        waitingReason = nil
    }

    /// Publish a cancel, then enforce it: locally when the turn has not started, through the
    /// adapter when it has.
    public func cancel(messageID: UUID) async {
        let control = BridgeControl(messageID: messageID, bridgeID: bridgeID, createdAt: clock.now())
        if let record = try? codec.encode(control) { _ = try? await mailbox.publish(record) }
        if let projection = try? await store.executionProjection(messageID: messageID),
           projection.state == .received {
            _ = try? await store.applyRemotePage(RemotePage(changes: [.control(control)]), now: clock.now())
            await publishExecution(for: messageID)
            await refreshTasks()
            return
        }
        await interruptActiveTask()
    }

    // MARK: - Publication

    private func publishExecution(for messageID: UUID) async {
        guard let journal = try? await store.executionProjection(messageID: messageID) else { return }
        let update = ExecutionUpdate(messageID: messageID, state: journal.state, revision: journal.revision,
                                     updatedAt: journal.updatedAt, errorCode: journal.errorCode,
                                     errorSummary: journal.errorSummary)
        guard let record = try? codec.encode(update, bridgeID: bridgeID, profileID: profileID) else { return }
        _ = try? await mailbox.publish(record)
    }

    public func heartbeat() async {
        let device = BridgeDevice(bridgeID: bridgeID, name: bridgeName,
                                  capabilities: ["text"], lastSeenAt: clock.now(), profileID: profileID)
        if let record = try? codec.encode(device) {
            _ = try? await mailbox.publish(record)
        }
    }

    public func refreshTasks() async {
        guard let ids = try? await store.conversationIDs() else { return }
        var collected: [BridgeTaskSummary] = []
        for conversationID in ids {
            guard let entries = try? await store.conversationEntries(conversationID) else { continue }
            for entry in entries.suffix(20) {
                let text = (try? await store.request(messageID: entry.messageID))?.text ?? ""
                let summary = (try? await store.executionProjection(messageID: entry.messageID))?.errorSummary
                collected.append(BridgeTaskSummary(id: entry.messageID, conversationID: conversationID,
                                                   state: entry.state, text: text,
                                                   errorSummary: summary))
            }
        }
        tasks = collected.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Helpers

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Large answers are written next to the database, not into a record field.
    static func stash(_ text: String, messageID: UUID) -> String? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NeoOSBridge/Results", isDirectory: true)
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(messageID.uuidString).txt")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }
}
