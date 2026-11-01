import XCTest
import CloudBridgeCore
@testable import HermesBridgeClient

/// A scripted wire. No socket, no server: the test decides exactly what each method answers.
final class FakeHermesSocket: HermesSocketTransport, @unchecked Sendable {
    enum Reply {
        case result(JSONValue)
        case error(code: Int, message: String)
    }

    private let lock = NSLock()
    private var openedURLs: [URL] = []
    private var inbox: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false
    private var handlers: [String: (JSONValue) -> Reply] = [:]
    private var sentFrames: [String] = []

    var openCount: Int { lock.withLock { openedURLs.count } }
    var urls: [URL] { lock.withLock { openedURLs } }
    var methods: [String] { lock.withLock { sentFrames } }

    func handle(_ method: String, _ reply: @escaping (JSONValue) -> Reply) {
        lock.withLock { handlers[method] = reply }
    }

    func pushEvent(_ payload: String) {
        deliver(payload)
    }

    // MARK: HermesSocketTransport

    func open(url: URL) async throws {
        lock.withLock {
            openedURLs.append(url)
            closed = false
        }
    }

    func send(_ text: String) async throws {
        guard let value = try? JSONValue.decode(Data(text.utf8)) else { return }
        let id = value["id"].string
        let method = value["method"].string
        let params = value["params"]
        lock.withLock { sentFrames.append(method) }
        let handler = lock.withLock { handlers[method] }

        let reply: String
        switch handler?(params) {
        case .result(let result):
            reply = Self.response(id: id, result: result)
        case .error(let code, let message):
            reply = Self.failure(id: id, code: code, message: message)
        case nil:
            // The default is the behaviour the live 0.22.2 backend showed for canonical methods.
            reply = Self.failure(id: id, code: -32601, message: "unknown method: \(method)")
        }
        deliver(reply)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> String? in
                if closed { return nil }
                return inbox.isEmpty ? nil : inbox.removeFirst()
            }
            if let immediate {
                continuation.resume(returning: immediate)
            } else {
                lock.withLock { waiters.append(continuation) }
            }
        }
    }

    func close() async {
        let pending = lock.withLock { () -> [CheckedContinuation<String, Error>] in
            closed = true
            let values = waiters
            waiters.removeAll()
            return values
        }
        for waiter in pending { waiter.resume(throwing: HermesTransportError.disconnected("closed")) }
    }

    private func deliver(_ frame: String) {
        let waiter = lock.withLock { () -> CheckedContinuation<String, Error>? in
            if waiters.isEmpty {
                inbox.append(frame)
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: frame)
    }

    static func response(id: String, result: JSONValue) -> String {
        let frame: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(id), "result": result])
        return String(decoding: (try? JSONValue.encode(frame)) ?? Data(), as: UTF8.self)
    }

    static func failure(id: String, code: Int, message: String) -> String {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .string(id),
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
        return String(decoding: (try? JSONValue.encode(frame)) ?? Data(), as: UTF8.self)
    }
}

final class LocalHermesClientTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Endpoint policy

    func testRejectsNonLoopbackEndpoint() {
        XCTAssertThrowsError(try LoopbackEndpoint(host: "192.168.1.10", port: 9119)) { error in
            XCTAssertEqual(error as? HermesEndpointError, .notLoopback("192.168.1.10"))
        }
        XCTAssertThrowsError(try LoopbackEndpoint(host: "my-mac.tailnet.ts.net", port: 9119))
        XCTAssertThrowsError(try LoopbackEndpoint(host: "127.0.0.1", port: 0)) { error in
            XCTAssertEqual(error as? HermesEndpointError, .invalidPort)
        }
        XCTAssertNoThrow(try LoopbackEndpoint(host: "127.0.0.1", port: 9119))
        XCTAssertNoThrow(try LoopbackEndpoint(host: "localhost", port: 9119))
        XCTAssertNoThrow(try LoopbackEndpoint(host: "::1", port: 9119))
    }

    // MARK: - Capabilities

    func testCapabilitiesUnknownDisablesSafeReplay() async throws {
        let socket = FakeHermesSocket()
        socket.handle("client.capabilities") { _ in
            .result(.object(["server_requests": .array([.string("approval"), .string("clarify")]),
                             "declines_not_shown": .bool(true)]))
        }
        socket.handle("ping") { _ in .result(.object(["pong": .bool(true)])) }
        // Every capability probe falls through to the -32601 default, exactly like the live backend.

        let client = makeClient(socket: socket)
        let capabilities = try await client.probe()

        XCTAssertFalse(capabilities.supportsAdmissionReceipt,
                       "0.22.2 /api/ws answers -32601 for prompt.receipt")
        XCTAssertFalse(capabilities.supportsPromptCancel)
        XCTAssertTrue(capabilities.interactiveMethods.contains("approval"))
        XCTAssertTrue(capabilities.requiresUncertainRecovery,
                      "without a receipt API an ambiguous send must stay uncertain")
    }

    func testCapabilitiesDetectAReceiptAPI() async throws {
        let socket = FakeHermesSocket()
        socket.handle("client.capabilities") { _ in .result(.object(["server_requests": .array([])])) }
        socket.handle("prompt.receipt") { _ in .error(code: 4007, message: "admission not found") }

        let client = makeClient(socket: socket)
        let capabilities = try await client.probe()
        XCTAssertTrue(capabilities.supportsAdmissionReceipt,
                      "a method that rejects params still exists")
    }

    // MARK: - Identity

    func testRPCIDIsNotDurableInputID() async throws {
        let socket = scriptedSession(createStored: "20260101_000000_abc")
        let client = makeClient(socket: socket)
        let conversation = makeConversation()
        let request = makeRequest(conversation: conversation, text: "只回复 OK")

        let session = try await client.resolveConversation(conversation)
        let admission = try await client.submit(request, in: session)

        XCTAssertNil(admission.admissionID,
                     "the JSON-RPC id correlates a response; it is not an idempotency key")
        XCTAssertEqual(admission.kind, .streaming)
        XCTAssertEqual(admission.userRowID, 3)
        XCTAssertEqual(session.storedSessionID, "20260101_000000_abc")
    }

    func testSubmitResumesByStoredIDNotRuntimeID() async throws {
        let socket = FakeHermesSocket()
        var resumeParams: [JSONValue] = []
        socket.handle("client.capabilities") { _ in .result(.object(["server_requests": .array([])])) }
        socket.handle("session.resume") { params in
            resumeParams.append(params)
            return .result(.object(["session_id": .string("runtime-new"),
                                    "stored_session_id": .string("stored-1")]))
        }
        socket.handle("prompt.submit") { _ in .result(.object(["status": .string("streaming"),
                                                              "user_row_id": .number(7)])) }

        let client = makeClient(socket: socket)
        let session = HermesSession(storedSessionID: "stored-1", runtimeSessionID: "runtime-old",
                                    profileID: "default")
        let request = makeRequest(conversation: makeConversation(), text: "hi")
        _ = try await client.submit(request, in: session)

        XCTAssertEqual(resumeParams.first?["session_id"].string, "stored-1")
        XCTAssertEqual(resumeParams.first?["session_id"].string,
                       "stored-1",
                       "the runtime id the caller passed is never used as the durable handle")
    }

    // MARK: - Credentials

    func testFreshTicketOnReconnect() async throws {
        let socket = FakeHermesSocket()
        socket.handle("client.capabilities") { _ in .result(.object(["server_requests": .array([])])) }
        let tokens = TokenSequence(["first-token", "second-token"])
        let client = makeClient(socket: socket, tokenProvider: { await tokens.next() })

        _ = try await client.probe()
        await client.close()
        _ = try await client.probe()

        let urls = socket.urls
        XCTAssertEqual(urls.count, 2, "a reconnect opens a new socket")
        XCTAssertTrue(urls[0].absoluteString.contains("token=first-token"))
        XCTAssertTrue(urls[1].absoluteString.contains("token=second-token"),
                      "the credential is re-read on every connection, never cached across reconnects")
    }

    func testMissingCredentialIsAPreSendBlocker() async throws {
        let socket = FakeHermesSocket()
        let client = makeClient(socket: socket, tokenProvider: { nil })
        do {
            _ = try await client.probe()
            XCTFail("expected a refusal")
        } catch let error as HermesTransportError {
            XCTAssertTrue(error.isAuthenticationFailure)
        }
        XCTAssertEqual(socket.openCount, 0, "no socket is opened without a credential")
    }

    // MARK: - Events

    func testTerminalEventCarriesTheAnswer() async throws {
        let socket = FakeHermesSocket()
        socket.handle("client.capabilities") { _ in .result(.object(["server_requests": .array([])])) }
        socket.handle("session.resume") { _ in
            .result(.object(["session_id": .string("runtime-1")]))
        }
        socket.handle("prompt.submit") { _ in .result(.object(["status": .string("streaming")])) }

        let client = makeClient(socket: socket)
        let request = makeRequest(conversation: makeConversation(), text: "只回复 OK")
        let stream = await client.events()
        var iterator = stream.makeAsyncIterator()
        _ = try await client.submit(request, in: HermesSession(storedSessionID: "stored-1",
                                                              runtimeSessionID: "runtime-1",
                                                              profileID: "default"))
        socket.pushEvent(#"""
        {"method":"event","params":{"type":"message.complete","session_id":"stored-1","seq":4,
         "payload":{"text":"OK","status":"ok","error":null}}}
        """#)

        let event = await iterator.next()
        XCTAssertEqual(event?.kind, .completed)
        XCTAssertEqual(event?.text, "OK")
        XCTAssertEqual(event?.messageID, request.messageID)
    }

    func testInteractiveRequestIsSurfacedNeverAnswered() async throws {
        let socket = FakeHermesSocket()
        socket.handle("client.capabilities") { _ in .result(.object(["server_requests": .array([])])) }
        let client = makeClient(socket: socket)
        let stream = await client.events()
        var iterator = stream.makeAsyncIterator()
        _ = try await client.probe()

        socket.pushEvent(#"""
        {"jsonrpc":"2.0","id":"srq-1","method":"approval","params":{"prompt":"Allow rm -rf?"}}
        """#)

        let event = await iterator.next()
        XCTAssertEqual(event?.kind, .interactive)
        XCTAssertFalse(socket.methods.contains("request.answer"),
                       "the cloud channel never answers an approval on the user's behalf")
    }

    // MARK: - Helpers

    private func makeClient(socket: FakeHermesSocket,
                            tokenProvider: @escaping @Sendable () async throws -> String? = { "local-token" })
    -> LocalHermesClient {
        LocalHermesClient(configuration: LocalHermesConfiguration(
            endpoint: loopbackEndpoint(),
            profileID: "default",
            tokenProvider: tokenProvider),
            transport: socket)
    }

    /// Only loopback hosts are constructed in these tests, so the throw is unreachable.
    private func loopbackEndpoint() -> LoopbackEndpoint {
        guard let endpoint = try? LoopbackEndpoint(host: "127.0.0.1", port: 19119) else {
            preconditionFailure("loopback endpoint construction cannot fail")
        }
        return endpoint
    }

    private func scriptedSession(createStored: String) -> FakeHermesSocket {
        let socket = FakeHermesSocket()
        socket.handle("client.capabilities") { _ in .result(.object(["server_requests": .array([])])) }
        socket.handle("session.create") { _ in
            .result(.object(["session_id": .string("runtime-1"),
                             "stored_session_id": .string(createStored),
                             "message_count": .number(0),
                             "messages": .array([]),
                             "info": .object([:])]))
        }
        socket.handle("session.resume") { _ in
            .result(.object(["session_id": .string("runtime-1"),
                             "stored_session_id": .string(createStored)]))
        }
        socket.handle("prompt.submit") { _ in
            .result(.object(["status": .string("streaming"), "user_row_id": .number(3)]))
        }
        return socket
    }

    private func makeConversation() -> BridgeConversation {
        BridgeConversation(bridgeID: UUID(), profileID: "default", sourceDeviceID: "device-A",
                           title: "Cloud", createdAt: epoch)
    }

    private func makeRequest(conversation: BridgeConversation, text: String) -> BridgeRequest {
        BridgeRequest(conversationID: conversation.conversationID, bridgeID: conversation.bridgeID,
                      profileID: conversation.profileID, sourceDeviceID: "device-A",
                      text: text, createdAt: epoch)
    }
}

/// Hands out credentials in order and fails afterwards, so a test can see re-reads.
actor TokenSequence {
    private var values: [String?]
    private var issued: [String] = []

    init(_ values: [String?]) { self.values = values }
    var issuedTokens: [String] { issued }

    func next() -> String? {
        guard !values.isEmpty else { return values.last ?? nil }
        let value = values.removeFirst()
        if let value { issued.append(value) }
        return value
    }
}
