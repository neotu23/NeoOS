import Foundation

/// One incoming `BridgeExecution` state, as the Mac published it.
public struct ExecutionUpdate: Hashable, Codable, Sendable {
    public let messageID: UUID
    public let schemaVersion: Int
    public let state: DeliveryState
    public let revision: Int
    public let updatedAt: Date
    public let errorCode: String?
    public let errorSummary: String?

    public init(messageID: UUID, schemaVersion: Int = CloudSchema.version, state: DeliveryState,
                revision: Int, updatedAt: Date, errorCode: String? = nil, errorSummary: String? = nil) {
        self.messageID = messageID
        self.schemaVersion = schemaVersion
        self.state = state
        self.revision = revision
        self.updatedAt = updatedAt
        self.errorCode = errorCode
        self.errorSummary = errorSummary
    }
}

public struct ExecutionProjection: Hashable, Sendable {
    public let messageID: UUID
    public let state: DeliveryState
    public let revision: Int
    public let updatedAt: Date
    public let errorCode: String?
    public let errorSummary: String?

    public init(messageID: UUID, state: DeliveryState, revision: Int, updatedAt: Date,
                errorCode: String? = nil, errorSummary: String? = nil) {
        self.messageID = messageID
        self.state = state
        self.revision = revision
        self.updatedAt = updatedAt
        self.errorCode = errorCode
        self.errorSummary = errorSummary
    }
}

public enum ProjectionOutcome: Hashable, Sendable {
    case applied(ExecutionProjection)
    /// The record is older (or the same revision) than what we already know. Ignoring an old
    /// notification is the normal case, not an error.
    case ignoredStaleRevision(currentRevision: Int)
    /// `completed` never goes back to `running`; a failed/cancelled task is only ever replaced by a
    /// completed result.
    case refusedTerminalRegression(current: DeliveryState, incoming: DeliveryState)
    /// A record this build cannot interpret. Kept for diagnostics, never applied.
    case quarantined(reason: QuarantineReason)
}

public enum QuarantineReason: String, Hashable, Sendable {
    case unknownSchemaVersion
    case unrecognisedState
    case malformedBody
}

/// Ordering information for one message in a conversation.
public struct ConversationEntry: Hashable, Sendable {
    public let messageID: UUID
    public let previousMessageID: UUID?
    public let state: DeliveryState
    public let createdAt: Date

    public init(messageID: UUID, previousMessageID: UUID?, state: DeliveryState, createdAt: Date) {
        self.messageID = messageID
        self.previousMessageID = previousMessageID
        self.state = state
        self.createdAt = createdAt
    }
}

public enum DispatchDecision: Hashable, Sendable {
    /// Nothing to do in this conversation.
    case idle
    /// A dependency-free request in `received` state, ready for the first submission.
    case dispatch(messageID: UUID)
    /// This conversation already has a task the bridge owns.
    case inFlight(messageID: UUID)
    /// The predecessor has not reached a terminal state yet.
    case waitForDependency(messageID: UUID, dependency: UUID)
    /// The predecessor ended badly. The plan forbids stepping over it: the user is asked to start a
    /// new conversation instead of the bridge making a silent judgement call.
    case blockedByPredecessor(messageID: UUID, predecessor: UUID, state: DeliveryState)
    /// Two devices appended to the same predecessor. Guessing an order from device clocks is not
    /// allowed, so the conversation stops and reports a conflict.
    case conversationConflict(predecessor: UUID, messageIDs: [UUID])
}

/// Pure state logic: no storage, no clock, no network. Every rule that decides "may this move?" or
/// "may this run?" lives here so both the Mac and the iPhone apply the identical rule set.
public enum MessageReducer {

    /// Fold one published execution state into what we already know about the message.
    ///
    /// - Parameters:
    ///   - current: the projection already stored, if any.
    ///   - incoming: the state just received.
    public static func project(current: ExecutionProjection?, incoming: ExecutionUpdate) -> ProjectionOutcome {
        guard incoming.schemaVersion == CloudSchema.version else {
            return .quarantined(reason: .unknownSchemaVersion)
        }
        // `revision` is the only ordering this protocol trusts. Device clocks are not comparable
        // across two machines, and CloudKit may deliver an older record after a newer one.
        if let current, incoming.revision <= current.revision {
            if incoming.revision == current.revision, incoming.state == current.state {
                return .ignoredStaleRevision(currentRevision: current.revision)
            }
            if incoming.revision < current.revision {
                return .ignoredStaleRevision(currentRevision: current.revision)
            }
        }
        if let current, refuses(current.state, incoming: incoming.state, incomingRevision: incoming.revision,
                                currentRevision: current.revision) {
            return .refusedTerminalRegression(current: current.state, incoming: incoming.state)
        }
        return .applied(ExecutionProjection(messageID: incoming.messageID, state: incoming.state,
                                            revision: incoming.revision, updatedAt: incoming.updatedAt,
                                            errorCode: incoming.errorCode, errorSummary: incoming.errorSummary))
    }

    /// Terminal outcomes are sticky. `completed` beats everything; `failed`/`cancelled` can only be
    /// replaced by a `completed` result (a valid final result is the terminal evidence).
    private static func refuses(_ current: DeliveryState, incoming: DeliveryState,
                                incomingRevision: Int, currentRevision: Int) -> Bool {
        guard current.isTerminal else { return false }
        if current == .completed { return incoming != .completed }
        if incoming == .completed { return false }
        return true
    }

    /// Which request, if any, the bridge may start now.
    ///
    /// `entries` is ordered by `createdAt`; the caller guarantees that.
    public static func dispatchDecision(in entries: [ConversationEntry]) -> DispatchDecision {
        guard !entries.isEmpty else { return .idle }

        if let conflict = forkConflict(in: entries) { return conflict }

        // At most one turn at a time: anything the Mac is already working on blocks the conversation.
        if let busy = entries.first(where: { $0.state.isActivelyDispatching }) {
            return .inFlight(messageID: busy.messageID)
        }

        let pending = entries.filter { !$0.state.isTerminal && $0.state != .queuedLocal && $0.state != .uploaded }
        guard let next = pending.first else { return .idle }

        if next.state == .uncertain {
            // Nothing may be replayed, and whatever queued behind it must not run unattended.
            guard let later = pending.dropFirst().first else { return .idle }
            return .blockedByPredecessor(messageID: later.messageID, predecessor: next.messageID,
                                         state: .uncertain)
        }
        guard next.state == .received else { return .idle }

        guard let previousID = next.previousMessageID else {
            return .dispatch(messageID: next.messageID)
        }
        guard let predecessor = entries.first(where: { $0.messageID == previousID }) else {
            // The predecessor has not synced yet. Waiting is the only safe answer: running now
            // would execute a later turn before the earlier one exists.
            return .waitForDependency(messageID: next.messageID, dependency: previousID)
        }
        switch predecessor.state {
        case .completed:
            return .dispatch(messageID: next.messageID)
        case .failed, .cancelled, .uncertain:
            return .blockedByPredecessor(messageID: next.messageID, predecessor: previousID,
                                         state: predecessor.state)
        default:
            return .waitForDependency(messageID: next.messageID, dependency: previousID)
        }
    }

    /// Two requests claiming the same predecessor means two devices wrote concurrently.
    private static func forkConflict(in entries: [ConversationEntry]) -> DispatchDecision? {
        var seen: [UUID: UUID] = [:]  // predecessor -> first message that claimed it
        var conflicted: [UUID: [UUID]] = [:]
        for entry in entries {
            guard let previous = entry.previousMessageID else { continue }
            if let first = seen[previous], first != entry.messageID {
                conflicted[previous, default: [first]].append(entry.messageID)
            } else {
                seen[previous] = entry.messageID
            }
        }
        guard let (predecessor, messageIDs) = conflicted.min(by: { $0.key.uuidString < $1.key.uuidString })
        else { return nil }
        return .conversationConflict(predecessor: predecessor, messageIDs: messageIDs)
    }

    /// Deduplicate a page of incoming message ids. CloudKit can deliver the same record twice; the
    /// second copy must not create a second execution.
    public static func newMessageIDs(in page: [UUID], known: Set<UUID>) -> [UUID] {
        var seen = known
        var result: [UUID] = []
        for id in page where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }
}
