import Foundation

// MARK: - Scope

/// Namespace for everything a single iCloud identity owns.
///
/// Every database row, outbox entry, sync token and cached bridge discovery is keyed by this value.
/// A user who signs out of iCloud and back in as somebody else gets a different `userRecordName`,
/// and the old rows must never surface for the new one — that is the whole reason this type is the
/// first key in every table.
public struct AccountScope: Hashable, Codable, Sendable {
    public let containerID: String
    public let environment: String
    /// Internal namespace only: never written to a user-visible log or to CloudKit.
    public let userRecordName: String

    public init(containerID: String, environment: String, userRecordName: String) {
        self.containerID = containerID
        self.environment = environment
        self.userRecordName = userRecordName
    }

    /// A stable, non-reversible key for database columns. `userRecordName` itself is a CloudKit
    /// identifier; hashing it keeps it out of any accidental log line that prints a row.
    public var storageKey: String {
        let raw = "\(containerID)|\(environment)|\(userRecordName)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a, stable across processes and launches.
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Constants

public enum CloudSchema {
    /// Bumped only with a migration. A record carrying any other value is quarantined, never applied.
    public static let version = 1
    public static let zoneName = "NeoOSMailboxV1"
}

/// Product limits. These are decisions of this app, not Apple quota claims.
public enum BridgeLimits {
    /// A text request, measured in UTF-8 bytes.
    public static let requestTextBytes = 32 * 1024
    /// A result at or below this size travels inline in the `text` field.
    public static let inlineResultBytes = 128 * 1024
    /// Larger results travel as a `CKAsset`; beyond this the result is too large, not truncated.
    public static let resultAssetBytes = 5 * 1024 * 1024
}

// MARK: - Record kinds

public enum CloudRecordKind: String, Codable, Sendable, CaseIterable {
    case device = "BridgeDevice"
    case conversation = "BridgeConversation"
    case request = "BridgeRequest"
    case execution = "BridgeExecution"
    case result = "BridgeResult"
    case control = "BridgeControl"

    /// `recordName` prefixes from the plan. Keeping the prefix in one place stops a client from
    /// inventing a name shape the other side cannot parse.
    public var recordNamePrefix: String {
        switch self {
        case .device: "bridge_"
        case .conversation: "conversation_"
        case .request: "request_"
        case .execution: "execution_"
        case .result: "result_"
        case .control: "control_"
        }
    }
}

// MARK: - Conversation and request

public enum BridgeRole: String, Codable, Sendable {
    case user
    case assistant
}

/// The only request kind the first cloud release implements.
public enum RequestKind: String, Codable, Sendable, CaseIterable {
    case text

    public static let implemented: Set<RequestKind> = [.text]
}

public struct BridgeConversation: Hashable, Codable, Sendable, Identifiable {
    public let conversationID: UUID
    public let bridgeID: UUID
    public let profileID: String
    /// The iPhone that created the conversation. Only this device may append requests to it.
    public let sourceDeviceID: String
    public var title: String
    public let createdAt: Date

    public var id: UUID { conversationID }

    public init(conversationID: UUID = UUID(), bridgeID: UUID, profileID: String,
                sourceDeviceID: String, title: String, createdAt: Date) {
        self.conversationID = conversationID
        self.bridgeID = bridgeID
        self.profileID = profileID
        self.sourceDeviceID = sourceDeviceID
        self.title = title
        self.createdAt = createdAt
    }
}

public struct BridgeRequest: Hashable, Codable, Sendable, Identifiable {
    public let messageID: UUID
    public let conversationID: UUID
    public let bridgeID: UUID
    public let profileID: String
    public let sourceDeviceID: String
    public let kind: RequestKind
    public let text: String
    /// The request that must finish before this one runs; nil for the first request.
    public let previousMessageID: UUID?
    public let createdAt: Date

    public var id: UUID { messageID }

    public init(messageID: UUID = UUID(), conversationID: UUID, bridgeID: UUID, profileID: String,
                sourceDeviceID: String, kind: RequestKind = .text, text: String,
                previousMessageID: UUID? = nil, createdAt: Date) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.bridgeID = bridgeID
        self.profileID = profileID
        self.sourceDeviceID = sourceDeviceID
        self.kind = kind
        self.text = text
        self.previousMessageID = previousMessageID
        self.createdAt = createdAt
    }

    /// Blank and oversized text are refused before anything is written or uploaded: silently
    /// truncating a message would hand Hermes a different question than the user typed.
    public func validated() throws {
        guard RequestKind.implemented.contains(kind) else {
            throw BridgeValidationError.unsupportedKind(kind.rawValue)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeValidationError.blankText
        }
        let bytes = text.utf8.count
        guard bytes <= BridgeLimits.requestTextBytes else {
            throw BridgeValidationError.textTooLarge(limit: BridgeLimits.requestTextBytes, actual: bytes)
        }
    }
}

// MARK: - Result

public struct ResultAsset: Hashable, Codable, Sendable {
    public let fileToken: String
    public let byteCount: Int

    public init(fileToken: String, byteCount: Int) {
        self.fileToken = fileToken
        self.byteCount = byteCount
    }
}

/// `text` and `textAsset` are exclusive: exactly one carries the answer.
public enum BridgeResultContent: Hashable, Codable, Sendable {
    case inline(String)
    case asset(ResultAsset)

    public var inlineText: String? {
        if case .inline(let text) = self { return text }
        return nil
    }

    public var asset: ResultAsset? {
        if case .asset(let asset) = self { return asset }
        return nil
    }
}

public enum TerminalStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

public struct BridgeResult: Hashable, Codable, Sendable {
    public let messageID: UUID
    public let conversationID: UUID
    public let bridgeID: UUID
    public let role: BridgeRole
    public let content: BridgeResultContent
    /// SHA-256 of the full UTF-8 answer. Used for integrity and for comparing a retry of the same
    /// record; it says nothing about whether Hermes executed anything.
    public let contentSHA256: String
    public let completedAt: Date
    public let terminalStatus: TerminalStatus

    public init(messageID: UUID, conversationID: UUID, bridgeID: UUID,
                content: BridgeResultContent, contentSHA256: String,
                completedAt: Date, terminalStatus: TerminalStatus) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.bridgeID = bridgeID
        self.role = .assistant
        self.content = content
        self.contentSHA256 = contentSHA256
        self.completedAt = completedAt
        self.terminalStatus = terminalStatus
    }

    public func validated() throws {
        switch content {
        case .inline(let text):
            let bytes = text.utf8.count
            guard bytes <= BridgeLimits.inlineResultBytes else {
                throw BridgeValidationError.resultTooLarge(limit: BridgeLimits.inlineResultBytes, actual: bytes)
            }
        case .asset(let asset):
            guard asset.byteCount > 0, asset.byteCount <= BridgeLimits.resultAssetBytes else {
                throw BridgeValidationError.resultTooLarge(limit: BridgeLimits.resultAssetBytes,
                                                           actual: asset.byteCount)
            }
        }
    }
}

// MARK: - Delivery state

/// The projection the user sees for one message.
///
/// `queuedLocal` and `uploaded` are iPhone-side only; the Mac writes the rest. The distinction
/// between "CloudKit accepted it" and "Hermes is running it" is the reason this is not a Boolean.
public enum DeliveryState: String, Codable, Sendable, CaseIterable {
    case queuedLocal
    case uploaded
    case received
    case dispatching
    case accepted
    case running
    case waitingOnMac
    case completed
    case failed
    case cancelled
    case uncertain

    /// States after which nothing may change except a strictly better terminal outcome.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    /// True once the Mac owns the message, i.e. the iPhone must stop treating it as its own queue.
    public var isOwnedByBridge: Bool {
        switch self {
        case .received, .dispatching, .accepted, .running, .waitingOnMac: true
        default: false
        }
    }

    /// The states in which the Mac is doing something right now. `received` is deliberately not
    /// here: a received row is the *input* of scheduling, not proof that a turn is under way.
    public var isActivelyDispatching: Bool {
        switch self {
        case .dispatching, .accepted, .running, .waitingOnMac: true
        default: false
        }
    }

    /// A message the bridge may still make progress on.
    public var isInFlight: Bool {
        isOwnedByBridge || self == .uncertain
    }
}

public struct ExecutionJournal: Hashable, Codable, Sendable {
    public let messageID: UUID
    public let conversationID: UUID
    public let bridgeID: UUID
    public var state: DeliveryState
    /// Monotonic per message. An older revision can never move a message backwards.
    public var revision: Int
    public var updatedAt: Date
    /// Hermes' **stored** session id: the durable one. The runtime id is deliberately absent.
    public var hermesStoredSessionID: String?
    public var errorCode: String?
    public var errorSummary: String?

    public init(messageID: UUID, conversationID: UUID, bridgeID: UUID, state: DeliveryState,
                revision: Int, updatedAt: Date, hermesStoredSessionID: String? = nil,
                errorCode: String? = nil, errorSummary: String? = nil) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.bridgeID = bridgeID
        self.state = state
        self.revision = revision
        self.updatedAt = updatedAt
        self.hermesStoredSessionID = hermesStoredSessionID
        self.errorCode = errorCode
        self.errorSummary = errorSummary
    }
}

// MARK: - Control

public enum ControlKind: String, Codable, Sendable {
    /// Best effort: it prevents a not-yet-dispatched task and asks Hermes to interrupt a running one.
    case cancel
}

public struct BridgeControl: Hashable, Codable, Sendable {
    public let controlID: UUID
    public let messageID: UUID
    public let bridgeID: UUID
    public let kind: ControlKind
    public let createdAt: Date

    public init(controlID: UUID = UUID(), messageID: UUID, bridgeID: UUID,
                kind: ControlKind = .cancel, createdAt: Date) {
        self.controlID = controlID
        self.messageID = messageID
        self.bridgeID = bridgeID
        self.kind = kind
        self.createdAt = createdAt
    }
}

// MARK: - Bridge device

public struct BridgeDevice: Hashable, Codable, Sendable, Identifiable {
    public let bridgeID: UUID
    public var name: String
    public var protocolVersion: Int
    public var capabilities: [String]
    public var lastSeenAt: Date
    public var profileID: String

    public var id: UUID { bridgeID }

    public init(bridgeID: UUID, name: String, protocolVersion: Int = CloudSchema.version,
                capabilities: [String], lastSeenAt: Date, profileID: String) {
        self.bridgeID = bridgeID
        self.name = name
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
        self.profileID = profileID
    }

    /// A bridge is stale after this long without a heartbeat. It is an activity hint only: it never
    /// means a task failed, and it never moves a task to another Mac.
    public static let staleAfter: TimeInterval = 180
}

// MARK: - Sync primitives

public struct OutboundRecord: Hashable, Codable, Sendable {
    public let recordName: String
    public let kind: CloudRecordKind
    /// The encoded body the codec produced. Stored as bytes so the store never depends on CloudKit.
    public let payload: Data

    public init(recordName: String, kind: CloudRecordKind, payload: Data) {
        self.recordName = recordName
        self.kind = kind
        self.payload = payload
    }
}

public struct PublishReceipt: Hashable, Codable, Sendable {
    public let recordName: String
    public let confirmedAt: Date

    public init(recordName: String, confirmedAt: Date) {
        self.recordName = recordName
        self.confirmedAt = confirmedAt
    }
}

public struct SyncSummary: Hashable, Codable, Sendable {
    public var saved: Int
    public var received: Int
    public var failed: Int

    public init(saved: Int = 0, received: Int = 0, failed: Int = 0) {
        self.saved = saved
        self.received = received
        self.failed = failed
    }
}

// MARK: - Hermes domain

public struct HermesSession: Hashable, Codable, Sendable {
    public let storedSessionID: String
    /// Per-process handle. Never persisted as identity: it is reissued after a backend restart.
    public let runtimeSessionID: String
    public let profileID: String

    public init(storedSessionID: String, runtimeSessionID: String, profileID: String) {
        self.storedSessionID = storedSessionID
        self.runtimeSessionID = runtimeSessionID
        self.profileID = profileID
    }
}

/// What a live connection actually advertised. Discovered per connection, never assumed: the
/// verification of Hermes 0.22.2 found the admission API to be *absent* on `/api/ws`.
public struct HermesCapabilities: Hashable, Codable, Sendable {
    public var version: String?
    /// Cheap probe result: does this backend answer `prompt.receipt`?
    public var supportsAdmissionReceipt: Bool
    public var supportsPromptCancel: Bool
    public var supportsInterrupt: Bool
    public var supportsEventsSince: Bool
    /// The `server_requests` list from `client.capabilities`.
    public var interactiveMethods: Set<String>

    public init(version: String? = nil, supportsAdmissionReceipt: Bool = false,
                supportsPromptCancel: Bool = false, supportsInterrupt: Bool = true,
                supportsEventsSince: Bool = true, interactiveMethods: Set<String> = []) {
        self.version = version
        self.supportsAdmissionReceipt = supportsAdmissionReceipt
        self.supportsPromptCancel = supportsPromptCancel
        self.supportsInterrupt = supportsInterrupt
        self.supportsEventsSince = supportsEventsSince
        self.interactiveMethods = interactiveMethods
    }

    /// Without a receipt API, a connection lost after submitting is unknowable: the bridge must
    /// keep the task `uncertain` instead of replaying it.
    public var requiresUncertainRecovery: Bool { !supportsAdmissionReceipt }
}

public struct Admission: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case streaming
        case queued
        case steered
        case redirected
        case unknown
    }

    public let kind: Kind
    /// Hermes' database row for the accepted input. Not a delivery identity.
    public let userRowID: Int?
    /// Present only on backends that serve the canonical admission contract.
    public let admissionID: String?

    public init(kind: Kind, userRowID: Int? = nil, admissionID: String? = nil) {
        self.kind = kind
        self.userRowID = userRowID
        self.admissionID = admissionID
    }
}

/// The result of asking "what happened to the execution I was in the middle of?".
/// Deliberately not a `Bool`: `unknown` is the information the user needs.
public enum RecoveryOutcome: String, Codable, Sendable {
    /// Hermes proved it never received the input; a first submission is safe.
    case confirmedNotSent
    /// Admitted and still running.
    case pending
    /// Admitted and produced a terminal result.
    case completed
    /// Hermes refused the input.
    case rejected
    /// Cannot be proved either way. Never retried automatically.
    case unknown
}

public struct HermesBridgeEvent: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case started
        case progress
        /// The terminal answer text.
        case completed
        case failed
        /// Hermes is asking a human something; the cloud channel cannot answer it.
        case interactive
        case interrupted
        case disconnected
    }

    public let kind: Kind
    public let messageID: UUID?
    public let storedSessionID: String?
    public let text: String?
    public let detail: String?

    public init(kind: Kind, messageID: UUID?, storedSessionID: String? = nil,
                text: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.messageID = messageID
        self.storedSessionID = storedSessionID
        self.text = text
        self.detail = detail
    }
}

// MARK: - Record bodies

/// The JSON body of a record, independent of CloudKit.
///
/// `CloudBridgeCore` never imports CloudKit: the store persists these bytes, and `CloudBridgeSync`
/// is the only place that knows how a body becomes a `CKRecord`. One encoder configuration, shared
/// by both sides, is what keeps a value written on the iPhone byte-identical when the Mac or a
/// fixture reads it back.
public enum RecordCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - Validation errors
public enum BridgeValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case blankText
    case textTooLarge(limit: Int, actual: Int)
    case resultTooLarge(limit: Int, actual: Int)
    case unsupportedKind(String)
    case unknownSchemaVersion(Int)
    case scopeMismatch(field: String)

    public var description: String {
        switch self {
        case .blankText: "the message is empty"
        case .textTooLarge(let limit, let actual): "the message is \(actual) bytes; the limit is \(limit)"
        case .resultTooLarge(let limit, let actual): "the result is too large (\(actual) bytes; limit \(limit))"
        case .unsupportedKind(let kind): "unsupported request kind: \(kind)"
        case .unknownSchemaVersion(let version): "unknown schema version \(version)"
        case .scopeMismatch(let field): "record does not match the current account scope (\(field))"
        }
    }
}
