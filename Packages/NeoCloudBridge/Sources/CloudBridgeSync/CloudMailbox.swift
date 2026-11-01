import Foundation
import CloudBridgeCore

// MARK: - Adapter surface

public struct AdapterRecord: Hashable, Sendable {
    public let recordName: String
    public let body: Data
    public let changeTag: String?

    public init(recordName: String, body: Data, changeTag: String? = nil) {
        self.recordName = recordName
        self.body = body
        self.changeTag = changeTag
    }
}

public struct AdapterChanges: Hashable, Sendable {
    public var records: [AdapterRecord]
    public var deletedRecordNames: [String]
    public var newToken: Data?
    /// CloudKit's `moreComing`: a page boundary, never an end.
    public var moreComing: Bool

    public init(records: [AdapterRecord] = [], deletedRecordNames: [String] = [],
                newToken: Data? = nil, moreComing: Bool = false) {
        self.records = records
        self.deletedRecordNames = deletedRecordNames
        self.newToken = newToken
        self.moreComing = moreComing
    }
}

public enum AdapterSaveOutcome: Hashable, Sendable {
    case saved(recordName: String, changeTag: String)
    /// `serverRecordChanged`: somebody else's copy is there. Must be read back, never overwritten.
    case conflict(recordName: String)
    case failed(recordName: String, code: String, message: String, retryAfter: TimeInterval?)

    public var recordName: String {
        switch self {
        case .saved(let name, _), .conflict(let name), .failed(let name, _, _, _): name
        }
    }
}

public enum AdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    case accountUnavailable(String)
    case tokenExpired
    case permissionDenied(String)
    case zoneMissing
    case transport(String, retryAfter: TimeInterval?)

    public var description: String {
        switch self {
        case .accountUnavailable(let detail): "iCloud account unavailable: \(detail)"
        case .tokenExpired: "the change token expired"
        case .permissionDenied(let detail): "CloudKit permission denied: \(detail)"
        case .zoneMissing: "the mailbox zone is missing"
        case .transport(let detail, _): "CloudKit transport error: \(detail)"
        }
    }
}

/// Everything `CloudMailbox` needs from CloudKit, so tests can run without an iCloud account.
///
/// The real implementation wraps `CKContainer`/`CKDatabase` operations; the fake one returns scripted
/// pages. Nothing above this line knows about `CKRecord`.
public protocol CloudDatabaseAdapter: Sendable {
    func account() async throws -> AccountScope
    func ensureZone() async throws
    func subscribe() async throws
    /// - Parameter token: nil means "fetch everything" (first run, or after a token expiry).
    func fetchChanges(token: Data?, limit: Int) async throws -> AdapterChanges
    func fetch(recordName: String) async throws -> AdapterRecord?
    func save(_ records: [OutboundRecord]) async throws -> [AdapterSaveOutcome]
    /// Emits whenever the system reports a different iCloud identity (or nil when signed out).
    func accountChanges() -> AsyncStream<AccountScope?>
}

// MARK: - Mailbox

public enum MailboxError: Error, Equatable, Sendable, CustomStringConvertible {
    case accountChanged
    case conflict(String)
    case transport(String, retryAfter: TimeInterval?)
    case tooManyPages

    public var description: String {
        switch self {
        case .accountChanged: "the iCloud account changed; nothing was uploaded"
        case .conflict(let name): "\(name) already exists with different content"
        case .transport(let detail, _): detail
        case .tooManyPages: "the mailbox kept reporting more pages"
        }
    }
}

/// The contract the bridge controller binds to. `CloudMailbox` is the production implementation.
public protocol MailboxTransport: Sendable {
    func accountScope() async throws -> AccountScope
    func synchronize() async throws -> SyncSummary
    func publish(_ record: OutboundRecord) async throws -> PublishReceipt
}

/// The CloudKit side of the mailbox: pull changes, push the outbox, never invent ordering.
///
/// Three acknowledgements stay distinct throughout (§5 of the plan): a saved `CKRecord` means
/// *uploaded*, a Hermes admission means *accepted*, and a stored `BridgeResult` means *completed*.
public actor CloudMailbox: MailboxTransport {
    private let store: BridgeStore
    private let adapter: CloudDatabaseAdapter
    private let codec: CloudRecordCodec
    private let now: @Sendable () -> Date
    private var inFlight: Task<SyncSummary, Error>?
    private var didSubscribe = false
    private var consecutiveFailures = 0

    /// A page loop that never terminates would spin forever on a backend bug; this bounds it.
    private let pageLimit = 50

    public init(store: BridgeStore, adapter: CloudDatabaseAdapter, codec: CloudRecordCodec,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.adapter = adapter
        self.codec = codec
        self.now = now
    }

    // MARK: - Identity

    public func accountScope() async throws -> AccountScope {
        try await adapter.account()
    }

    /// Adopt a freshly reported identity. Returns true when the scope actually changed, so the caller
    /// can cancel anything that belonged to the previous one.
    @discardableResult
    public func reconcile(_ reported: AccountScope?) async throws -> Bool {
        let current = await store.accountScope
        guard let reported else {
            // Signed out: keep the rows (they are the user's) but stop treating the cached identity
            // as valid. Uploads will fail the scope check until a real account comes back.
            return false
        }
        guard reported.storageKey != current.storageKey else { return false }
        await store.switchScope(to: reported)
        return true
    }

    // MARK: - Sync

    /// Pull every pending page and push the outbox. Concurrent calls share one cycle: two cycles on
    /// one scope would race on the change token.
    public func synchronize() async throws -> SyncSummary {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.runCycle() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func runCycle() async throws -> SyncSummary {
        let live = try await adapter.account()
        let stored = await store.accountScope
        guard live.storageKey == stored.storageKey else {
            // The old outbox belongs to the old account. Never push it to the new one.
            throw MailboxError.accountChanged
        }

        try await adapter.ensureZone()
        if !didSubscribe {
            // A subscription only triggers a pull; it is never a task queue of its own.
            try await adapter.subscribe()
            didSubscribe = true
        }

        var summary = try await pullAllPages()
        summary.saved += try await pushOutbox()
        consecutiveFailures = 0
        return summary
    }

    private func pullAllPages() async throws -> SyncSummary {
        var summary = SyncSummary()
        var scannedFresh = false

        for _ in 0..<pageLimit {
            let token = try await store.changeToken()
            do {
                let changes = try await adapter.fetchChanges(token: token, limit: 200)
                let page = reduce(changes)
                let pageSummary = try await store.applyRemotePage(page, now: now())
                summary.saved += pageSummary.saved
                summary.received += pageSummary.received
                summary.failed += pageSummary.failed
                if !changes.moreComing { return summary }
            } catch AdapterError.tokenExpired {
                // A token that no longer means anything must be dropped before a full rescan, and the
                // rescan goes through the same message-id keys, so nothing completed runs twice.
                guard !scannedFresh else { throw AdapterError.tokenExpired }
                try await store.clearChangeToken()
                scannedFresh = true
                continue
            }
        }
        throw MailboxError.tooManyPages
    }

    private func reduce(_ changes: AdapterChanges) -> RemotePage {
        var page = RemotePage()
        page.nextToken = changes.newToken
        page.deletedRecordNames = changes.deletedRecordNames
        for record in changes.records {
            switch codec.decode(recordName: record.recordName, body: record.body) {
            case .change(let change):
                page.changes.append(change)
            case .quarantined(let name, let reason, let raw):
                page.changes.append(.quarantined(recordName: name, reason: reason, raw: raw))
            }
        }
        return page
    }

    private func pushOutbox() async throws -> Int {
        var uploaded = 0
        for record in try await store.pendingOutbound() {
            try await assertScopeUnchanged()
            do {
                _ = try await publish(record)
                uploaded += 1
            } catch MailboxError.accountChanged {
                throw MailboxError.accountChanged
            } catch {
                // One bad record must not stop the others, and it must not hide behind a retry loop
                // here: the caller decides when to try again.
                consecutiveFailures += 1
                if case MailboxError.transport(_, let retryAfter) = error, retryAfter != nil {
                    throw error
                }
            }
        }
        return uploaded
    }

    /// Upload one record. Immutable records (request, result) are written once; if the server already
    /// holds a copy, it is read back and compared field by field instead of being overwritten.
    @discardableResult
    public func publish(_ record: OutboundRecord) async throws -> PublishReceipt {
        try await assertScopeUnchanged()
        let outcomes = try await adapter.save([record])
        guard let outcome = outcomes.first(where: { $0.recordName == record.recordName }) ?? outcomes.first else {
            throw MailboxError.transport("CloudKit returned no outcome for \(record.recordName)", retryAfter: nil)
        }
        switch outcome {
        case .saved(let name, _):
            try await store.confirmUpload(recordNames: [name], now: now())
            return PublishReceipt(recordName: name, confirmedAt: now())
        case .conflict(let name):
            // The classic lost-ack: the write landed, the reply did not. Same bytes ⇒ already stored.
            guard let existing = try await adapter.fetch(recordName: name) else {
                throw MailboxError.conflict(name)
            }
            guard Self.businessContentMatches(existing.body, record.payload) else {
                throw MailboxError.conflict(name)
            }
            try await store.confirmUpload(recordNames: [name], now: now())
            return PublishReceipt(recordName: name, confirmedAt: now())
        case .failed(let name, let code, let message, let retryAfter):
            try await store.recordUploadFailure(recordName: name, error: "\(code): \(message)")
            throw MailboxError.transport(message, retryAfter: retryAfter)
        }
    }

    /// Byte comparison first (the encoder is deterministic), else a decoded comparison so a server
    /// that re-serialises the body still counts as "the same business content".
    static func businessContentMatches(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard let left = try? JSONSerialization.jsonObject(with: lhs) as? [String: Any],
              let right = try? JSONSerialization.jsonObject(with: rhs) as? [String: Any]
        else { return false }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }

    private func assertScopeUnchanged() async throws {
        let live = try await adapter.account()
        let stored = await store.accountScope
        guard live.storageKey == stored.storageKey else { throw MailboxError.accountChanged }
    }

    // MARK: - Retry policy

    /// 2, 4, 8 … capped at 60 s with jitter; Apple's `retryAfter` wins whenever it is longer.
    public func retryDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return retryAfter }
        let exponent = max(0, min(attempt, 6))
        let base = min(60, pow(2, Double(exponent + 1)))
        let jitter = Double.random(in: 0...0.25) * base
        return min(60, base + jitter)
    }

    public var failureCount: Int { consecutiveFailures }
}
