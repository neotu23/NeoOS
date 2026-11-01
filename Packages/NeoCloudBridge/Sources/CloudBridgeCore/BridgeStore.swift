import Foundation

/// One decoded change from CloudKit, already reduced to a domain value.
///
/// The store never sees a `CKRecord`: `CloudBridgeSync` turns records into these values, which keeps
/// the durable layer testable without iCloud and keeps CloudKit's shape out of the database schema.
public enum RemoteChange: Hashable, Sendable {
    case conversation(BridgeConversation)
    case request(BridgeRequest)
    case execution(ExecutionUpdate)
    case result(BridgeResult)
    case control(BridgeControl)
    case device(BridgeDevice)
    /// A record this build cannot read. Kept for diagnostics only.
    case quarantined(recordName: String, reason: QuarantineReason, raw: Data)
}

public struct RemotePage: Hashable, Sendable {
    public var changes: [RemoteChange]
    public var deletedRecordNames: [String]
    /// The zone change token that becomes valid only if this whole page is stored.
    public var nextToken: Data?

    public init(changes: [RemoteChange] = [], deletedRecordNames: [String] = [], nextToken: Data? = nil) {
        self.changes = changes
        self.deletedRecordNames = deletedRecordNames
        self.nextToken = nextToken
    }
}

/// Faults a test may arm to prove the store rolls back instead of half-committing.
public enum StoreFault: String, Sendable, CaseIterable {
    case beforeEnqueueCommit
    case beforePageCommit
    case beforeFinishCommit
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case notReceived(messageID: UUID, state: DeliveryState)
    case unknownMessage(UUID)
    case alreadyDispatched(UUID)
    case injected(StoreFault)

    public var description: String {
        switch self {
        case .notReceived(let id, let state): "\(id) is \(state.rawValue), not received"
        case .unknownMessage(let id): "no local row for \(id)"
        case .alreadyDispatched(let id): "\(id) was already dispatched"
        case .injected(let fault): "injected store fault: \(fault.rawValue)"
        }
    }
}

/// The single durable message store shared by the iPhone model and the Mac bridge.
///
/// One database per `AccountScope`. Everything the two sides need in order not to re-execute a turn
/// lives here: the request, its execution journal, the final result and the outbox entry, all in the
/// same transaction where they belong together.
public actor BridgeStore {
    private let database: SQLiteDatabase
    private var scope: AccountScope
    private var armedFaults: Set<StoreFault>

    /// - Parameters:
    ///   - path: an Application Support path. Never a synced iCloud Drive folder: this file is the
    ///     local truth, and iCloud Drive would give it a second, conflicting writer.
    ///   - scope: the iCloud identity the rows belong to.
    ///   - faults: test-only.
    public init(path: String, scope: AccountScope, faults: Set<StoreFault> = []) throws {
        self.database = try SQLiteDatabase(path: path)
        self.scope = scope
        self.armedFaults = faults
        try Self.migrate(database)
    }

    public init(inMemoryScope scope: AccountScope, faults: Set<StoreFault> = []) throws {
        self.database = try SQLiteDatabase(path: ":memory:")
        self.scope = scope
        self.armedFaults = faults
        try Self.migrate(database)
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS conversations (
                scope_key TEXT NOT NULL, conversation_id TEXT NOT NULL, bridge_id TEXT NOT NULL,
                profile_id TEXT NOT NULL, source_device_id TEXT NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (scope_key, conversation_id));
            CREATE TABLE IF NOT EXISTS requests (
                scope_key TEXT NOT NULL, message_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
                bridge_id TEXT NOT NULL, profile_id TEXT NOT NULL, source_device_id TEXT NOT NULL,
                kind TEXT NOT NULL, text TEXT NOT NULL, previous_message_id TEXT, created_at REAL NOT NULL,
                PRIMARY KEY (scope_key, message_id));
            CREATE TABLE IF NOT EXISTS executions (
                scope_key TEXT NOT NULL, message_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
                bridge_id TEXT NOT NULL, state TEXT NOT NULL, revision INTEGER NOT NULL,
                updated_at REAL NOT NULL, hermes_stored_session_id TEXT, error_code TEXT,
                error_summary TEXT,
                PRIMARY KEY (scope_key, message_id));
            CREATE TABLE IF NOT EXISTS results (
                scope_key TEXT NOT NULL, message_id TEXT NOT NULL, body BLOB NOT NULL,
                completed_at REAL NOT NULL,
                PRIMARY KEY (scope_key, message_id));
            CREATE TABLE IF NOT EXISTS outbox (
                scope_key TEXT NOT NULL, record_name TEXT NOT NULL, kind TEXT NOT NULL,
                body BLOB NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
                created_at REAL NOT NULL,
                PRIMARY KEY (scope_key, record_name));
            CREATE TABLE IF NOT EXISTS drafts (
                scope_key TEXT NOT NULL, conversation_id TEXT NOT NULL, text TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (scope_key, conversation_id));
            CREATE TABLE IF NOT EXISTS tokens (
                scope_key TEXT NOT NULL, token_key TEXT NOT NULL, token BLOB NOT NULL,
                PRIMARY KEY (scope_key, token_key));
            CREATE TABLE IF NOT EXISTS controls (
                scope_key TEXT NOT NULL, control_id TEXT NOT NULL, message_id TEXT NOT NULL,
                bridge_id TEXT NOT NULL, kind TEXT NOT NULL, created_at REAL NOT NULL,
                PRIMARY KEY (scope_key, control_id));
            CREATE TABLE IF NOT EXISTS devices (
                scope_key TEXT NOT NULL, bridge_id TEXT NOT NULL, body BLOB NOT NULL,
                last_seen_at REAL NOT NULL,
                PRIMARY KEY (scope_key, bridge_id));
            CREATE TABLE IF NOT EXISTS quarantine (
                scope_key TEXT NOT NULL, record_name TEXT NOT NULL, reason TEXT NOT NULL,
                body BLOB, received_at REAL NOT NULL,
                PRIMARY KEY (scope_key, record_name));
            CREATE INDEX IF NOT EXISTS requests_by_conversation
                ON requests (scope_key, conversation_id, created_at);
            """)
        let statement = try database.prepare("INSERT OR IGNORE INTO meta (key, value) VALUES ('schemaVersion', ?)")
        statement.bind(1, String(CloudSchema.version))
        try statement.run()
    }

    // MARK: - Scope

    /// Release the database file. Only tests need this: the app keeps the store for its lifetime.
    public func close() {
        database.close()
    }

    public var accountScope: AccountScope { scope }

    /// Move to another iCloud identity. Rows stay in the file, keyed by the old scope: they are
    /// never deleted (they may be needed to reconcile an in-flight task) and never surface again.
    public func switchScope(to newScope: AccountScope) {
        scope = newScope
    }

    private var scopeKey: String { scope.storageKey }

    // MARK: - Queueing

    /// Persist a request, its journal and its outbox entry, and clear the draft — in one transaction.
    ///
    /// If anything fails, the draft is still there and nothing was queued: the user's text is never
    /// silently lost to a half-written row.
    @discardableResult
    public func enqueue(_ request: BridgeRequest, clearingDraftFor conversationID: UUID,
                        now: Date = Date()) throws -> OutboundRecord {
        try request.validated()
        let record = OutboundRecord(recordName: try Self.recordName(for: request),
                                    kind: .request,
                                    payload: try RecordCoding.encoder().encode(request))
        try database.transaction {
            if armedFaults.contains(.beforeEnqueueCommit) { throw StoreError.injected(.beforeEnqueueCommit) }

            let insert = try database.prepare("""
                INSERT OR IGNORE INTO requests
                (scope_key, message_id, conversation_id, bridge_id, profile_id, source_device_id,
                 kind, text, previous_message_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            insert.bind(1, scopeKey); insert.bind(2, request.messageID.uuidString)
            insert.bind(3, request.conversationID.uuidString); insert.bind(4, request.bridgeID.uuidString)
            insert.bind(5, request.profileID); insert.bind(6, request.sourceDeviceID)
            insert.bind(7, request.kind.rawValue); insert.bind(8, request.text)
            insert.bind(9, request.previousMessageID?.uuidString)
            insert.bind(10, request.createdAt.timeIntervalSince1970)
            try insert.run()

            // `INSERT OR IGNORE` above means a duplicate enqueue keeps one request row; the journal
            // gets the same treatment so a retried enqueue never creates a second execution.
            let journal = try database.prepare("""
                INSERT OR IGNORE INTO executions
                (scope_key, message_id, conversation_id, bridge_id, state, revision, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            journal.bind(1, scopeKey); journal.bind(2, request.messageID.uuidString)
            journal.bind(3, request.conversationID.uuidString); journal.bind(4, request.bridgeID.uuidString)
            journal.bind(5, DeliveryState.queuedLocal.rawValue); journal.bind(6, Int64(0))
            journal.bind(7, now.timeIntervalSince1970)
            try journal.run()

            try upsertOutbox(record, now: now)
            try clearDraft(conversationID)
        }
        return record
    }

    /// The iPhone only clears a draft once the enqueue committed.
    public func saveDraft(_ text: String, conversationID: UUID, now: Date = Date()) throws {
        if text.isEmpty {
            try clearDraft(conversationID)
            return
        }
        let statement = try database.prepare("""
            INSERT INTO drafts (scope_key, conversation_id, text, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (scope_key, conversation_id) DO UPDATE SET text = excluded.text,
                updated_at = excluded.updated_at
            """)
        statement.bind(1, scopeKey); statement.bind(2, conversationID.uuidString)
        statement.bind(3, text); statement.bind(4, now.timeIntervalSince1970)
        try statement.run()
    }

    public func draft(conversationID: UUID) throws -> String {
        let statement = try database.prepare(
            "SELECT text FROM drafts WHERE scope_key = ? AND conversation_id = ?")
        statement.bind(1, scopeKey); statement.bind(2, conversationID.uuidString)
        return try statement.step() ? (statement.text(0) ?? "") : ""
    }

    private func clearDraft(_ conversationID: UUID) throws {
        let statement = try database.prepare(
            "DELETE FROM drafts WHERE scope_key = ? AND conversation_id = ?")
        statement.bind(1, scopeKey); statement.bind(2, conversationID.uuidString)
        try statement.run()
    }

    // MARK: - Outbox

    public func pendingOutbound() throws -> [OutboundRecord] {
        let statement = try database.prepare("""
            SELECT record_name, kind, body FROM outbox WHERE scope_key = ? ORDER BY created_at, record_name
            """)
        statement.bind(1, scopeKey)
        var records: [OutboundRecord] = []
        while try statement.step() {
            guard let name = statement.text(0), let kindText = statement.text(1),
                  let kind = CloudRecordKind(rawValue: kindText), let body = statement.blob(2)
            else { continue }
            records.append(OutboundRecord(recordName: name, kind: kind, payload: body))
        }
        return records
    }

    /// CloudKit confirmed this record. Drop the outbox entry and, for a request, move the projection
    /// from `queuedLocal` to `uploaded` — which still means "waiting for the Mac", not "running".
    public func confirmUpload(recordNames: [String], now: Date = Date()) throws {
        guard !recordNames.isEmpty else { return }
        try database.transaction {
            for name in recordNames {
                let delete = try database.prepare("DELETE FROM outbox WHERE scope_key = ? AND record_name = ?")
                delete.bind(1, scopeKey); delete.bind(2, name)
                try delete.run()

                guard let messageID = Self.messageID(fromRecordName: name) else { continue }
                let update = try database.prepare("""
                    UPDATE executions SET state = ?, updated_at = ?
                    WHERE scope_key = ? AND message_id = ? AND state = ?
                    """)
                update.bind(1, DeliveryState.uploaded.rawValue)
                update.bind(2, now.timeIntervalSince1970)
                update.bind(3, scopeKey); update.bind(4, messageID.uuidString)
                update.bind(5, DeliveryState.queuedLocal.rawValue)
                try update.run()
            }
        }
    }

    public func recordUploadFailure(recordName: String, error: String) throws {
        let statement = try database.prepare("""
            UPDATE outbox SET attempts = attempts + 1, last_error = ?
            WHERE scope_key = ? AND record_name = ?
            """)
        statement.bind(1, String(error.prefix(400))); statement.bind(2, scopeKey); statement.bind(3, recordName)
        try statement.run()
    }

    private func upsertOutbox(_ record: OutboundRecord, now: Date) throws {
        let statement = try database.prepare("""
            INSERT INTO outbox (scope_key, record_name, kind, body, attempts, last_error, created_at)
            VALUES (?, ?, ?, ?, 0, NULL, ?)
            ON CONFLICT (scope_key, record_name) DO UPDATE SET body = excluded.body
            """)
        statement.bind(1, scopeKey); statement.bind(2, record.recordName)
        statement.bind(3, record.kind.rawValue); statement.bind(4, record.payload)
        statement.bind(5, now.timeIntervalSince1970)
        try statement.run()
    }

    // MARK: - Remote changes

    /// Store a whole sync page and advance the change token in the same transaction.
    ///
    /// The token is the promise "everything before this point is durable here". Persisting it
    /// separately from the rows it describes would let a crash skip records forever.
    @discardableResult
    public func applyRemotePage(_ page: RemotePage, tokenKey: String = "zone", now: Date = Date()) throws -> SyncSummary {
        var summary = SyncSummary()
        try database.transaction {
            if armedFaults.contains(.beforePageCommit) { throw StoreError.injected(.beforePageCommit) }

            for change in page.changes {
                switch change {
                case .conversation(let conversation):
                    try upsertConversation(conversation)
                    summary.saved += 1
                case .request(let request):
                    if try upsertRequest(request) {
                        summary.received += 1
                    } else {
                        summary.saved += 1
                    }
                case .execution(let update):
                    if try applyExecution(update, now: now) {
                        summary.failed += 1
                    } else {
                        summary.saved += 1
                    }
                case .result(let result):
                    try applyResult(result, now: now)
                    summary.saved += 1
                case .control(let control):
                    try applyControl(control)
                    summary.saved += 1
                case .device(let device):
                    try upsertDevice(device)
                    summary.saved += 1
                case .quarantined(let recordName, let reason, let raw):
                    try quarantine(recordName: recordName, reason: reason, body: raw, now: now)
                    summary.failed += 1
                }
            }
            for name in page.deletedRecordNames {
                try applyDeletion(recordName: name)
            }
            if let token = page.nextToken {
                let statement = try database.prepare("""
                    INSERT INTO tokens (scope_key, token_key, token) VALUES (?, ?, ?)
                    ON CONFLICT (scope_key, token_key) DO UPDATE SET token = excluded.token
                    """)
                statement.bind(1, scopeKey); statement.bind(2, tokenKey); statement.bind(3, token)
                try statement.run()
            }
        }
        return summary
    }

    public func changeToken(key: String = "zone") throws -> Data? {
        let statement = try database.prepare(
            "SELECT token FROM tokens WHERE scope_key = ? AND token_key = ?")
        statement.bind(1, scopeKey); statement.bind(2, key)
        return try statement.step() ? statement.blob(0) : nil
    }

    public func clearChangeToken(key: String = "zone") throws {
        let statement = try database.prepare("DELETE FROM tokens WHERE scope_key = ? AND token_key = ?")
        statement.bind(1, scopeKey); statement.bind(2, key)
        try statement.run()
    }

    private func upsertConversation(_ conversation: BridgeConversation) throws {
        let statement = try database.prepare("""
            INSERT INTO conversations
            (scope_key, conversation_id, bridge_id, profile_id, source_device_id, title, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (scope_key, conversation_id) DO UPDATE SET title = excluded.title
            """)
        statement.bind(1, scopeKey); statement.bind(2, conversation.conversationID.uuidString)
        statement.bind(3, conversation.bridgeID.uuidString); statement.bind(4, conversation.profileID)
        statement.bind(5, conversation.sourceDeviceID); statement.bind(6, conversation.title)
        statement.bind(7, conversation.createdAt.timeIntervalSince1970)
        try statement.run()
    }

    /// Returns true when this request is new to this device (and therefore needs a journal).
    private func upsertRequest(_ request: BridgeRequest) throws -> Bool {
        let insert = try database.prepare("""
            INSERT OR IGNORE INTO requests
            (scope_key, message_id, conversation_id, bridge_id, profile_id, source_device_id,
             kind, text, previous_message_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insert.bind(1, scopeKey); insert.bind(2, request.messageID.uuidString)
        insert.bind(3, request.conversationID.uuidString); insert.bind(4, request.bridgeID.uuidString)
        insert.bind(5, request.profileID); insert.bind(6, request.sourceDeviceID)
        insert.bind(7, request.kind.rawValue); insert.bind(8, request.text)
        insert.bind(9, request.previousMessageID?.uuidString)
        insert.bind(10, request.createdAt.timeIntervalSince1970)
        try insert.run()
        guard database.changes > 0 else { return false }

        // A fresh request becomes `received`: the Mac has it durably and nothing has been sent yet.
        let journal = try database.prepare("""
            INSERT OR IGNORE INTO executions
            (scope_key, message_id, conversation_id, bridge_id, state, revision, updated_at)
            VALUES (?, ?, ?, ?, ?, 0, ?)
            """)
        journal.bind(1, scopeKey); journal.bind(2, request.messageID.uuidString)
        journal.bind(3, request.conversationID.uuidString); journal.bind(4, request.bridgeID.uuidString)
        journal.bind(5, DeliveryState.received.rawValue)
        journal.bind(6, request.createdAt.timeIntervalSince1970)
        try journal.run()
        return true
    }

    /// Returns true when the record was quarantined instead of applied.
    private func applyExecution(_ update: ExecutionUpdate, now: Date) throws -> Bool {
        let current = try executionProjection(messageID: update.messageID)
        let outcome = MessageReducer.project(current: current, incoming: update)
        switch outcome {
        case .applied(let projection):
            try writeExecution(projection)
            return false
        case .quarantined(let reason):
            try quarantine(recordName: "execution_\(update.messageID.uuidString)", reason: reason,
                           body: Data(), now: now)
            return true
        case .ignoredStaleRevision, .refusedTerminalRegression:
            return false
        }
    }

    private func writeExecution(_ projection: ExecutionProjection) throws {
        let statement = try database.prepare("""
            INSERT INTO executions
            (scope_key, message_id, conversation_id, bridge_id, state, revision, updated_at,
             hermes_stored_session_id, error_code, error_summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT (scope_key, message_id) DO UPDATE SET
                state = excluded.state, revision = excluded.revision,
                updated_at = excluded.updated_at, error_code = excluded.error_code,
                error_summary = excluded.error_summary
            """)
        let conversationID = try conversationID(forMessage: projection.messageID) ?? UUID()
        let bridgeID = try bridgeID(forMessage: projection.messageID) ?? UUID()
        statement.bind(1, scopeKey); statement.bind(2, projection.messageID.uuidString)
        statement.bind(3, conversationID.uuidString); statement.bind(4, bridgeID.uuidString)
        statement.bind(5, projection.state.rawValue); statement.bind(6, Int64(projection.revision))
        statement.bind(7, projection.updatedAt.timeIntervalSince1970)
        statement.bind(8, projection.errorCode); statement.bind(9, projection.errorSummary)
        try statement.run()
    }

    /// A result may arrive before its request. Store it keyed by message id; the link is made when
    /// the request lands. Dropping it would lose the only copy of the answer.
    private func applyResult(_ result: BridgeResult, now: Date) throws {
        let statement = try database.prepare("""
            INSERT INTO results (scope_key, message_id, body, completed_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (scope_key, message_id) DO NOTHING
            """)
        statement.bind(1, scopeKey); statement.bind(2, result.messageID.uuidString)
        statement.bind(3, try RecordCoding.encoder().encode(result))
        statement.bind(4, result.completedAt.timeIntervalSince1970)
        try statement.run()

        // A stored result is the terminal evidence: the projection follows it, never the other way.
        let state: DeliveryState
        switch result.terminalStatus {
        case .completed: state = .completed
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        let current = try executionProjection(messageID: result.messageID)
        let update = ExecutionUpdate(messageID: result.messageID, state: state,
                                     revision: max(current?.revision ?? -1, 0) + 1,
                                     updatedAt: result.completedAt)
        if case .applied(let projection) = MessageReducer.project(current: current, incoming: update) {
            try writeExecution(projection)
        }
    }

    /// A cancel that arrives before the turn was dispatched must prevent the dispatch locally.
    /// One that arrives afterwards is only a request for the Mac to interrupt.
    private func applyControl(_ control: BridgeControl) throws {
        let statement = try database.prepare("""
            INSERT OR IGNORE INTO controls (scope_key, control_id, message_id, bridge_id, kind, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        statement.bind(1, scopeKey); statement.bind(2, control.controlID.uuidString)
        statement.bind(3, control.messageID.uuidString); statement.bind(4, control.bridgeID.uuidString)
        statement.bind(5, control.kind.rawValue); statement.bind(6, control.createdAt.timeIntervalSince1970)
        try statement.run()
        guard database.changes > 0, control.kind == .cancel else { return }

        let current = try executionProjection(messageID: control.messageID)
        guard let current, current.state == .received else { return }
        try writeExecution(ExecutionProjection(messageID: control.messageID, state: .cancelled,
                                               revision: current.revision + 1,
                                               updatedAt: control.createdAt,
                                               errorCode: "cancelled_before_dispatch",
                                               errorSummary: nil))
    }

    private func upsertDevice(_ device: BridgeDevice) throws {
        let statement = try database.prepare("""
            INSERT INTO devices (scope_key, bridge_id, body, last_seen_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (scope_key, bridge_id) DO UPDATE SET body = excluded.body,
                last_seen_at = excluded.last_seen_at
            """)
        statement.bind(1, scopeKey); statement.bind(2, device.bridgeID.uuidString)
        statement.bind(3, try RecordCoding.encoder().encode(device))
        statement.bind(4, device.lastSeenAt.timeIntervalSince1970)
        try statement.run()
    }

    /// A deleted request stops new executions. A deleted result never re-runs anything: the journal
    /// keeps its terminal state, because "the answer was removed" is not "the turn did not happen".
    private func applyDeletion(recordName: String) throws {
        if let messageID = Self.requestMessageID(recordName) {
            let statement = try database.prepare("""
                UPDATE executions SET state = ?, updated_at = ?
                WHERE scope_key = ? AND message_id = ? AND state IN (?, ?, ?)
                """)
            statement.bind(1, DeliveryState.cancelled.rawValue)
            statement.bind(2, Date().timeIntervalSince1970)
            statement.bind(3, scopeKey); statement.bind(4, messageID.uuidString)
            statement.bind(5, DeliveryState.received.rawValue)
            statement.bind(6, DeliveryState.queuedLocal.rawValue)
            statement.bind(7, DeliveryState.uploaded.rawValue)
            try statement.run()
        }
        let delete = try database.prepare("DELETE FROM outbox WHERE scope_key = ? AND record_name = ?")
        delete.bind(1, scopeKey); delete.bind(2, recordName)
        try delete.run()
    }

    private func quarantine(recordName: String, reason: QuarantineReason, body: Data, now: Date) throws {
        let statement = try database.prepare("""
            INSERT INTO quarantine (scope_key, record_name, reason, body, received_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (scope_key, record_name) DO UPDATE SET reason = excluded.reason
            """)
        statement.bind(1, scopeKey); statement.bind(2, recordName)
        statement.bind(3, reason.rawValue); statement.bind(4, body)
        statement.bind(5, now.timeIntervalSince1970)
        try statement.run()
    }

    public func quarantinedRecords() throws -> [(recordName: String, reason: String)] {
        let statement = try database.prepare("""
            SELECT record_name, reason FROM quarantine WHERE scope_key = ? ORDER BY received_at
            """)
        statement.bind(1, scopeKey)
        var rows: [(String, String)] = []
        while try statement.step() {
            rows.append((statement.text(0) ?? "", statement.text(1) ?? ""))
        }
        return rows
    }

    // MARK: - Execution lifecycle (Mac side)

    /// Commit "I am about to call Hermes" before the call leaves the process. Second call refuses.
    public func beginDispatch(messageID: UUID, now: Date = Date()) throws {
        let current = try executionProjection(messageID: messageID)
        guard let current else { throw StoreError.unknownMessage(messageID) }
        guard current.state == .received else {
            throw StoreError.notReceived(messageID: messageID, state: current.state)
        }
        try writeExecution(ExecutionProjection(messageID: messageID, state: .dispatching,
                                               revision: current.revision + 1, updatedAt: now))
    }

    /// Hermes accepted the input. Only this transition may follow `dispatching`.
    public func recordAdmission(messageID: UUID, admission: Admission, storedSessionID: String?,
                                now: Date = Date()) throws {
        let current = try executionProjection(messageID: messageID)
        guard let current else { throw StoreError.unknownMessage(messageID) }
        guard current.state == .dispatching || current.state == .accepted else {
            throw StoreError.notReceived(messageID: messageID, state: current.state)
        }
        try writeExecution(ExecutionProjection(messageID: messageID, state: .accepted,
                                               revision: current.revision + 1, updatedAt: now))
        if let storedSessionID {
            let statement = try database.prepare("""
                UPDATE executions SET hermes_stored_session_id = ?
                WHERE scope_key = ? AND message_id = ?
                """)
            statement.bind(1, storedSessionID); statement.bind(2, scopeKey)
            statement.bind(3, messageID.uuidString)
            try statement.run()
        }
    }

    public func markRunning(messageID: UUID, now: Date = Date()) throws {
        let current = try executionProjection(messageID: messageID)
        guard let current, current.state == .accepted || current.state == .dispatching else { return }
        try writeExecution(ExecutionProjection(messageID: messageID, state: .running,
                                               revision: current.revision + 1, updatedAt: now))
    }

    public func markWaitingOnMac(messageID: UUID, summary: String?, now: Date = Date()) throws {
        let current = try executionProjection(messageID: messageID)
        guard let current, current.state.isActivelyDispatching else { return }
        try writeExecution(ExecutionProjection(messageID: messageID, state: .waitingOnMac,
                                               revision: current.revision + 1, updatedAt: now,
                                               errorCode: current.errorCode, errorSummary: summary))
    }

    public func markUncertain(messageID: UUID, summary: String?, now: Date = Date()) throws {
        let current = try executionProjection(messageID: messageID)
        guard let current, !current.state.isTerminal, current.state != .uncertain else { return }
        try writeExecution(ExecutionProjection(messageID: messageID, state: .uncertain,
                                               revision: current.revision + 1, updatedAt: now,
                                               errorCode: current.errorCode, errorSummary: summary))
    }

    public func fail(messageID: UUID, code: String?, summary: String?, now: Date = Date()) throws {
        let current = try executionProjection(messageID: messageID)
        guard let current, !current.state.isTerminal else { return }
        try writeExecution(ExecutionProjection(messageID: messageID, state: .failed,
                                               revision: current.revision + 1, updatedAt: now,
                                               errorCode: code, errorSummary: summary))
    }

    /// Persist the final answer and its outbox entry in one transaction.
    ///
    /// After this returns, the turn is `completed` locally no matter what CloudKit does: a failed
    /// upload retries the same result record, it never asks Hermes again.
    @discardableResult
    public func finish(messageID: UUID, result: BridgeResult, now: Date = Date()) throws -> OutboundRecord {
        try result.validated()
        let record = OutboundRecord(recordName: try Self.recordName(for: result),
                                    kind: .result,
                                    payload: try RecordCoding.encoder().encode(result))
        try database.transaction {
            if armedFaults.contains(.beforeFinishCommit) { throw StoreError.injected(.beforeFinishCommit) }

            let insert = try database.prepare("""
                INSERT INTO results (scope_key, message_id, body, completed_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (scope_key, message_id) DO NOTHING
                """)
            insert.bind(1, scopeKey); insert.bind(2, messageID.uuidString)
            insert.bind(3, record.payload); insert.bind(4, result.completedAt.timeIntervalSince1970)
            try insert.run()

            let current = try executionProjection(messageID: messageID)
            try writeExecution(ExecutionProjection(messageID: messageID,
                                                   state: Self.state(for: result.terminalStatus),
                                                   revision: (current?.revision ?? 0) + 1,
                                                   updatedAt: result.completedAt))
            try upsertOutbox(record, now: now)
        }
        return record
    }

    private static func state(for status: TerminalStatus) -> DeliveryState {
        switch status {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    // MARK: - Reads

    public func executionProjection(messageID: UUID) throws -> ExecutionProjection? {
        let statement = try database.prepare("""
            SELECT state, revision, updated_at, error_code, error_summary FROM executions
            WHERE scope_key = ? AND message_id = ?
            """)
        statement.bind(1, scopeKey); statement.bind(2, messageID.uuidString)
        guard try statement.step() else { return nil }
        guard let raw = statement.text(0), let state = DeliveryState(rawValue: raw) else { return nil }
        return ExecutionProjection(messageID: messageID, state: state,
                                   revision: Int(statement.int(1) ?? 0),
                                   updatedAt: Date(timeIntervalSince1970: statement.double(2) ?? 0),
                                   errorCode: statement.text(3), errorSummary: statement.text(4))
    }

    public func request(messageID: UUID) throws -> BridgeRequest? {
        let statement = try database.prepare("""
            SELECT message_id, conversation_id, bridge_id, profile_id, source_device_id,
                   kind, text, previous_message_id, created_at
            FROM requests WHERE scope_key = ? AND message_id = ?
            """)
        statement.bind(1, scopeKey); statement.bind(2, messageID.uuidString)
        guard try statement.step() else { return nil }
        return Self.decodeRequest(statement)
    }

    /// The durable Hermes session this message ran in, if one was recorded.
    public func hermesStoredSessionID(messageID: UUID) throws -> String? {
        let statement = try database.prepare(
            "SELECT hermes_stored_session_id FROM executions WHERE scope_key = ? AND message_id = ?")
        statement.bind(1, scopeKey); statement.bind(2, messageID.uuidString)
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    public func result(messageID: UUID) throws -> BridgeResult? {
        let statement = try database.prepare(
            "SELECT body FROM results WHERE scope_key = ? AND message_id = ?")
        statement.bind(1, scopeKey); statement.bind(2, messageID.uuidString)
        guard try statement.step(), let body = statement.blob(0) else { return nil }
        return try RecordCoding.decoder().decode(BridgeResult.self, from: body)
    }

    /// Ordered by creation time, which is the only order `dispatchDecision` accepts.
    public func conversationEntries(_ conversationID: UUID) throws -> [ConversationEntry] {
        let statement = try database.prepare("""
            SELECT r.message_id, r.previous_message_id, r.created_at, e.state
            FROM requests r JOIN executions e
              ON e.scope_key = r.scope_key AND e.message_id = r.message_id
            WHERE r.scope_key = ? AND r.conversation_id = ?
            ORDER BY r.created_at, r.message_id
            """)
        statement.bind(1, scopeKey); statement.bind(2, conversationID.uuidString)
        var entries: [ConversationEntry] = []
        while try statement.step() {
            guard let rawID = statement.text(0), let id = UUID(uuidString: rawID),
                  let rawState = statement.text(3), let state = DeliveryState(rawValue: rawState)
            else { continue }
            entries.append(ConversationEntry(messageID: id,
                                             previousMessageID: statement.text(1).flatMap(UUID.init(uuidString:)),
                                             state: state,
                                             createdAt: Date(timeIntervalSince1970: statement.double(2) ?? 0)))
        }
        return entries
    }

    /// Every conversation this device knows about, including ones whose record was never synced:
    /// the Mac may see a request before it sees the conversation record.
    public func conversationIDs() throws -> [UUID] {
        let statement = try database.prepare("""
            SELECT conversation_id FROM conversations WHERE scope_key = ?
            UNION
            SELECT DISTINCT conversation_id FROM requests WHERE scope_key = ?
            """)
        statement.bind(1, scopeKey); statement.bind(2, scopeKey)
        var ids: [UUID] = []
        while try statement.step() {
            if let raw = statement.text(0), let id = UUID(uuidString: raw) { ids.append(id) }
        }
        return ids
    }

    /// Tasks the Mac must reconcile after a restart. `dispatching` is included on purpose: the call
    /// may or may not have reached Hermes, which is exactly the ambiguity recovery has to resolve.
    public func recoverableExecutions(limit: Int = 100) throws -> [ExecutionJournal] {
        let statement = try database.prepare("""
            SELECT message_id, conversation_id, bridge_id, state, revision, updated_at,
                   hermes_stored_session_id, error_code, error_summary
            FROM executions
            WHERE scope_key = ? AND state IN (?, ?, ?, ?, ?)
            ORDER BY updated_at LIMIT ?
            """)
        statement.bind(1, scopeKey)
        statement.bind(2, DeliveryState.dispatching.rawValue)
        statement.bind(3, DeliveryState.accepted.rawValue)
        statement.bind(4, DeliveryState.running.rawValue)
        statement.bind(5, DeliveryState.waitingOnMac.rawValue)
        statement.bind(6, DeliveryState.uncertain.rawValue)
        statement.bind(7, Int64(limit))
        var journals: [ExecutionJournal] = []
        while try statement.step() {
            guard let rawID = statement.text(0), let id = UUID(uuidString: rawID),
                  let rawConversation = statement.text(1), let conversationID = UUID(uuidString: rawConversation),
                  let rawBridge = statement.text(2), let bridgeID = UUID(uuidString: rawBridge),
                  let rawState = statement.text(3), let state = DeliveryState(rawValue: rawState)
            else { continue }
            journals.append(ExecutionJournal(messageID: id, conversationID: conversationID,
                                             bridgeID: bridgeID, state: state,
                                             revision: Int(statement.int(4) ?? 0),
                                             updatedAt: Date(timeIntervalSince1970: statement.double(5) ?? 0),
                                             hermesStoredSessionID: statement.text(6),
                                             errorCode: statement.text(7),
                                             errorSummary: statement.text(8)))
        }
        return journals
    }

    public func devices() throws -> [BridgeDevice] {
        let statement = try database.prepare(
            "SELECT body FROM devices WHERE scope_key = ? ORDER BY last_seen_at DESC")
        statement.bind(1, scopeKey)
        var devices: [BridgeDevice] = []
        while try statement.step() {
            guard let body = statement.blob(0) else { continue }
            if let device = try? RecordCoding.decoder().decode(BridgeDevice.self, from: body) {
                devices.append(device)
            }
        }
        return devices
    }

    public func pendingCancelMessageIDs() throws -> [UUID] {
        let statement = try database.prepare("""
            SELECT c.message_id FROM controls c
            JOIN executions e ON e.scope_key = c.scope_key AND e.message_id = c.message_id
            WHERE c.scope_key = ? AND c.kind = ? AND e.state = ?
            """)
        statement.bind(1, scopeKey); statement.bind(2, ControlKind.cancel.rawValue)
        statement.bind(3, DeliveryState.running.rawValue)
        var ids: [UUID] = []
        while try statement.step() {
            if let raw = statement.text(0), let id = UUID(uuidString: raw) { ids.append(id) }
        }
        return ids
    }

    // MARK: - Helpers

    private func conversationID(forMessage messageID: UUID) throws -> UUID? {
        let statement = try database.prepare(
            "SELECT conversation_id FROM requests WHERE scope_key = ? AND message_id = ?")
        statement.bind(1, scopeKey); statement.bind(2, messageID.uuidString)
        guard try statement.step(), let raw = statement.text(0) else { return nil }
        return UUID(uuidString: raw)
    }

    private func bridgeID(forMessage messageID: UUID) throws -> UUID? {
        let statement = try database.prepare(
            "SELECT bridge_id FROM requests WHERE scope_key = ? AND message_id = ?")
        statement.bind(1, scopeKey); statement.bind(2, messageID.uuidString)
        guard try statement.step(), let raw = statement.text(0) else { return nil }
        return UUID(uuidString: raw)
    }

    private static func decodeRequest(_ statement: SQLiteStatement) -> BridgeRequest? {
        guard let rawID = statement.text(0), let messageID = UUID(uuidString: rawID),
              let rawConversation = statement.text(1), let conversationID = UUID(uuidString: rawConversation),
              let rawBridge = statement.text(2), let bridgeID = UUID(uuidString: rawBridge),
              let kindText = statement.text(5), let kind = RequestKind(rawValue: kindText)
        else { return nil }
        return BridgeRequest(messageID: messageID, conversationID: conversationID, bridgeID: bridgeID,
                             profileID: statement.text(3) ?? "", sourceDeviceID: statement.text(4) ?? "",
                             kind: kind, text: statement.text(6) ?? "",
                             previousMessageID: statement.text(7).flatMap(UUID.init(uuidString:)),
                             createdAt: Date(timeIntervalSince1970: statement.double(8) ?? 0))
    }

    static func recordName(for request: BridgeRequest) throws -> String {
        CloudRecordKind.request.recordNamePrefix + request.messageID.uuidString
    }

    static func recordName(for result: BridgeResult) throws -> String {
        CloudRecordKind.result.recordNamePrefix + result.messageID.uuidString
    }

    static func recordName(for conversation: BridgeConversation) -> String {
        CloudRecordKind.conversation.recordNamePrefix + conversation.conversationID.uuidString
    }

    static func recordName(for control: BridgeControl) -> String {
        CloudRecordKind.control.recordNamePrefix + control.controlID.uuidString
    }

    static func messageID(fromRecordName name: String) -> UUID? {
        for kind in [CloudRecordKind.request, .result] where name.hasPrefix(kind.recordNamePrefix) {
            return UUID(uuidString: String(name.dropFirst(kind.recordNamePrefix.count)))
        }
        return nil
    }

    private static func requestMessageID(_ name: String) -> UUID? {
        guard name.hasPrefix(CloudRecordKind.request.recordNamePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(CloudRecordKind.request.recordNamePrefix.count)))
    }
}
