import Foundation
import CloudBridgeCore

// MARK: - Contract

/// What the Mac's executor needs from Hermes.
///
/// Every method is one call the verification in `docs/CLOUDKIT_HERMES_COMPATIBILITY.md` confirmed on
/// a live 0.22.2 backend, or an explicit "not available" answer.
public protocol HermesExecuting: Sendable {
    func probe() async throws -> HermesCapabilities
    func resolveConversation(_ conversation: BridgeConversation) async throws -> HermesSession
    func submit(_ request: BridgeRequest, in session: HermesSession) async throws -> Admission
    func recover(_ execution: ExecutionJournal) async throws -> RecoveryOutcome
    func interrupt(_ execution: ExecutionJournal) async throws
    func events() async -> AsyncStream<HermesBridgeEvent>
}

public enum HermesTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case timeout(String)
    case rpc(code: Int, message: String)
    case disconnected(String)
    case sessionNotFound(String)

    public var description: String {
        switch self {
        case .notConnected: "not connected to the local Hermes"
        case .timeout(let method): "\(method) timed out"
        case .rpc(let code, let message): "Hermes RPC \(code): \(message)"
        case .disconnected(let detail): "the Hermes connection dropped: \(detail)"
        case .sessionNotFound(let id): "Hermes does not know session \(id)"
        }
    }

    public var isAuthenticationFailure: Bool { code == 401 || code == 403 }

    private var code: Int {
        if case .rpc(let code, _) = self { return code }
        return 0
    }
}

/// The WebSocket seam. The real implementation wraps `URLSessionWebSocketTask`; tests script frames.
public protocol HermesSocketTransport: Sendable {
    func open(url: URL) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

public struct LocalHermesConfiguration: Sendable {
    public var endpoint: LoopbackEndpoint
    public var profileID: String
    /// Read per connection: a loopback token is a per-process fact, and it can change under us.
    public var tokenProvider: @Sendable () async throws -> String?

    public init(endpoint: LoopbackEndpoint, profileID: String = "default",
                tokenProvider: @escaping @Sendable () async throws -> String? = { nil }) {
        self.endpoint = endpoint
        self.profileID = profileID
        self.tokenProvider = tokenProvider
    }
}

// MARK: - Client

/// The adapter that speaks to a loopback `hermes serve`.
///
/// Rules that come straight from the verification (§5 of the plan):
/// * the durable conversation key is the **stored** session id; a runtime id is re-resolved every
///   time the socket is (re)opened;
/// * the JSON-RPC id is a request/response correlator, never an idempotency key;
/// * when the backend has no admission lookup, a lost acknowledgement is `unknown`, not "retry".
public final class LocalHermesClient: HermesExecuting, @unchecked Sendable {
    private let configuration: LocalHermesConfiguration
    private let transport: HermesSocketTransport
    private let eventHub = EventHub()
    private let connection = WireConnection()

    public init(configuration: LocalHermesConfiguration,
                transport: HermesSocketTransport = URLSessionHermesSocket()) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: Events

    public func events() async -> AsyncStream<HermesBridgeEvent> {
        eventHub.stream()
    }

    // MARK: Probe

    public func probe() async throws -> HermesCapabilities {
        try await connectIfNeeded()
        var capabilities = HermesCapabilities()

        // `client.capabilities` is what makes Hermes send interactive requests at all; declaring it
        // is how the bridge can *see* a question it is not allowed to answer.
        let negotiation = try await call("client.capabilities", .object(["server_requests": .bool(true)]))
        capabilities.interactiveMethods = Set(negotiation["server_requests"].array.map(\.string))

        if let pong = try? await call("ping"), pong["pong"].bool {
            capabilities.version = nil  // `session.info` carries the version; ping only proves liveness.
        }
        // Probe, do not assume: on 0.22.2 the canonical admission methods answer -32601.
        capabilities.supportsAdmissionReceipt = await probeMethod("prompt.receipt",
                                                                 treatUnknownParamsAsSupported: true)
        capabilities.supportsPromptCancel = await probeMethod("prompt.cancel",
                                                             treatUnknownParamsAsSupported: true)
        capabilities.supportsInterrupt = await probeMethod("session.interrupt", treatUnknownParamsAsSupported: true)
        capabilities.supportsEventsSince = await probeMethod("session.events.since", treatUnknownParamsAsSupported: true)
        return capabilities
    }

    private func probeMethod(_ method: String, treatUnknownParamsAsSupported: Bool = false,
                             params: JSONValue = .object([:])) async -> Bool {
        do {
            _ = try await call(method, params)
            return true
        } catch let error as HermesTransportError {
            if case .rpc(let code, _) = error {
                if code == -32601 { return false }
                // 4001/4007 mean the method exists and rejected empty params.
                if treatUnknownParamsAsSupported, code == 4001 || code == 4007 { return true }
                return false
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: Session

    public func resolveConversation(_ conversation: BridgeConversation) async throws -> HermesSession {
        try await connectIfNeeded()
        // A conversation that already ran carries its stored id in the journal; the caller passes it
        // separately, so this method also handles the first time (create).
        if let existing = conversation.storedSessionIDHint {
            return try await resume(storedID: existing)
        }
        let created = try await call("session.create", .object(["profile": .string(configuration.profileID)]))
        let stored = created["stored_session_id"].string
        let runtime = created["session_id"].string
        guard !stored.isEmpty, !runtime.isEmpty else {
            throw HermesTransportError.rpc(code: 0, message: "session.create returned no ids")
        }
        return HermesSession(storedSessionID: stored, runtimeSessionID: runtime,
                             profileID: configuration.profileID)
    }

    /// Attach to an existing conversation by its **stored** id.
    public func resume(storedID: String) async throws -> HermesSession {
        try await connectIfNeeded()
        do {
            let resumed = try await call("session.resume", .object(["session_id": .string(storedID)]))
            let runtime = resumed["session_id"].string
            guard !runtime.isEmpty else {
                throw HermesTransportError.rpc(code: 0, message: "session.resume returned no runtime id")
            }
            return HermesSession(storedSessionID: storedID, runtimeSessionID: runtime,
                                 profileID: configuration.profileID)
        } catch let error as HermesTransportError {
            if case .rpc(let code, _) = error, code == 4007 {
                throw HermesTransportError.sessionNotFound(storedID)
            }
            throw error
        }
    }

    // MARK: Submit

    public func submit(_ request: BridgeRequest, in session: HermesSession) async throws -> Admission {
        try request.validated()
        try await connectIfNeeded()
        // Ask the backend to resume the conversation through its stored id first: the runtime handle
        // we were given may have died with a previous backend process.
        let live = try await resume(storedID: session.storedSessionID)
        await connection.setActiveMessage(request.messageID)
        let result = try await call("prompt.submit", .object([
            "session_id": .string(live.runtimeSessionID),
            "text": .string(request.text),
        ]))
        let status = result["status"].string
        let kind: Admission.Kind
        switch status {
        case "streaming": kind = .streaming
        case "queued": kind = .queued
        case "steered": kind = .steered
        case "redirected": kind = .redirected
        default: kind = .unknown
        }
        // No durable input identity exists on this transport: the admission carries no id unless a
        // backend serves the canonical contract, which this adapter deliberately does not assume.
        return Admission(kind: kind, userRowID: result["user_row_id"].int, admissionID: nil)
    }

    // MARK: Recovery

    public func recover(_ execution: ExecutionJournal) async throws -> RecoveryOutcome {
        try await connectIfNeeded()
        switch execution.state {
        case .received:
            // Nothing was sent: the first submission is safe.
            return .confirmedNotSent
        case .completed, .failed, .cancelled:
            return .completed
        case .queuedLocal, .uploaded:
            return .confirmedNotSent
        case .dispatching, .accepted, .running, .waitingOnMac, .uncertain:
            break
        }

        // A durable identity would let us ask "did you get this?" — this backend has none, so the
        // honest answer is that we cannot know. Never replay on a guess.
        guard await probeMethod("prompt.receipt", treatUnknownParamsAsSupported: true) else { return .unknown }

        // Defensive branch for backends that do serve the canonical receipt contract.
        do {
            let receipt = try await call("prompt.receipt", .object([
                "session_id": .string(execution.hermesStoredSessionID ?? ""),
                "admission_id": .string(execution.messageID.uuidString),
                "include_result": .bool(false),
            ]))
            switch receipt["status"].string {
            case "terminal": return .completed
            case "queued", "started": return .pending
            case "unknown": return .unknown
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }

    public func interrupt(_ execution: ExecutionJournal) async throws {
        try await connectIfNeeded()
        guard let stored = execution.hermesStoredSessionID else {
            throw HermesTransportError.sessionNotFound(execution.messageID.uuidString)
        }
        let live = try await resume(storedID: stored)
        _ = try await call("session.interrupt", .object(["session_id": .string(live.runtimeSessionID)]))
    }

    // MARK: Connection

    private func connectIfNeeded() async throws {
        try await connection.connectIfNeeded { [configuration, transport, eventHub] in
            let token = try await configuration.tokenProvider()
            guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HermesTransportError.rpc(code: 401, message: "no local Hermes credential")
            }
            var components = URLComponents(url: configuration.endpoint.socketURL,
                                           resolvingAgainstBaseURL: false)
            // Loopback sockets authorise with a token query; the ticket route is gated-mode only.
            components?.queryItems = [URLQueryItem(name: "token", value: token)]
            guard let url = components?.url else {
                throw HermesTransportError.notConnected
            }
            try await transport.open(url: url)
            return ConnectionContext(transport: transport, eventHub: eventHub)
        }
    }

    private func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await connection.call(method, params: params, timeout: 45)
    }

    public func close() async {
        await connection.close()
    }
}

// MARK: - Conversation hint

extension BridgeConversation {
    /// The stored Hermes session this conversation maps to, when the caller already knows it.
    /// Kept as a separate lookup so `BridgeConversation` stays a pure value type in the record.
    public var storedSessionIDHint: String? {
        // A conversation created by this bridge carries the stored id in its title's trailing token
        // only if it was set explicitly; the executor normally gets it from the journal. This
        // accessor exists so tests and callers can pass one along without adding a schema field.
        if case let .some(hint) = ConversationHints.snapshot[conversationID] { return hint }
        return nil
    }
}

/// Process-local hints: the journal is the real store, this only avoids threading a parameter
/// through the `HermesExecuting` contract during the first cloud release.
public enum ConversationHints {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var values: [UUID: String] = [:]
    }
    private static let box = Box()

    public static var snapshot: [UUID: String] {
        box.lock.withLock { [UUID: String](uniqueKeysWithValues: box.values.map { ($0.key, $0.value) }) }
    }

    public static func remember(_ storedSessionID: String, for conversationID: UUID) {
        box.lock.withLock { box.values[conversationID] = storedSessionID }
    }

    public static func forget(_ conversationID: UUID) {
        box.lock.withLock { box.values[conversationID] = nil }
    }
}
