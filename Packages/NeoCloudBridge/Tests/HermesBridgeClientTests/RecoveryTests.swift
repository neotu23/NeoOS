import XCTest
import CloudBridgeCore
@testable import HermesBridgeClient

/// Recovery is the part of the bridge that decides whether a message can run again.
/// These tests pin the rule from the plan: a failure *before* the send is safe to retry, an
/// ambiguity *after* it is never replayed.
final class RecoveryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    func testFailureBeforeSendIsSafeToRetry() async throws {
        let socket = readySocket()
        let client = makeClient(socket: socket)

        for state in [DeliveryState.received, .queuedLocal, .uploaded] {
            let outcome = try await client.recover(journal(state: state))
            XCTAssertEqual(outcome, .confirmedNotSent,
                           "\(state.rawValue) means nothing was sent, so the first submit is safe")
        }
    }

    func testLostAckWithoutAnInquiryAPIStaysUnknown() async throws {
        let socket = readySocket()
        // The default handler answers -32601 for every canonical method, like the live backend.
        let client = makeClient(socket: socket)

        for state in [DeliveryState.dispatching, .accepted, .running, .waitingOnMac, .uncertain] {
            let outcome = try await client.recover(journal(state: state))
            XCTAssertEqual(outcome, .unknown,
                           "\(state.rawValue) may or may not have reached Hermes: never replay it")
        }
        XCTAssertFalse(socket.methods.contains("prompt.submit"),
                       "recovery must not submit anything")
    }

    func testDurableIdentityIsQueriedNotResubmitted() async throws {
        let socket = readySocket()
        let messageID = UUID()
        var receiptParams: [JSONValue] = []
        socket.handle("prompt.receipt") { params in
            receiptParams.append(params)
            return .result(.object(["status": .string("terminal"), "outcome": .string("ok")]))
        }
        let client = makeClient(socket: socket)

        let outcome = try await client.recover(journal(state: .dispatching, messageID: messageID))
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(receiptParams.last?["admission_id"].string, messageID.uuidString,
                       "the durable id is the question, not a new prompt")
        XCTAssertFalse(socket.methods.contains("prompt.submit"),
                       "a capability query must never turn into a resend")
    }

    func testReceiptPendingIsReportedAsPending() async throws {
        let socket = readySocket()
        socket.handle("prompt.receipt") { _ in
            .result(.object(["status": .string("started")]))
        }
        let client = makeClient(socket: socket)
        let outcome = try await client.recover(journal(state: .accepted))
        XCTAssertEqual(outcome, .pending)
    }

    func testTerminalJournalIsAlreadySettled() async throws {
        let socket = readySocket()
        let client = makeClient(socket: socket)
        let outcome = try await client.recover(journal(state: .completed))
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(socket.methods, [], "a settled turn needs no recovery call at all")
    }

    func testInterruptUsesTheStoredSession() async throws {
        let socket = readySocket()
        var resumeCalls: [String] = []
        socket.handle("session.resume") { params in
            resumeCalls.append(params["session_id"].string)
            return .result(.object(["session_id": .string("runtime-live")]))
        }
        var interruptParams: JSONValue = .null
        socket.handle("session.interrupt") { params in
            interruptParams = params
            return .result(.object(["status": .string("interrupted")]))
        }

        let client = makeClient(socket: socket)
        try await client.interrupt(journal(state: .running, stored: "20260101_000000_probe"))

        XCTAssertEqual(resumeCalls, ["20260101_000000_probe"])
        XCTAssertEqual(interruptParams["session_id"].string, "runtime-live",
                       "interrupt targets the live runtime id resolved from the stored one")
    }

    // MARK: - Fixtures

    func testRecordedFixturesDecodeIntoTheTypedEvents() throws {
        let ready = try fixture("gateway_ready")
        XCTAssertEqual(ready["params"]["type"].string, "gateway.ready")
        XCTAssertFalse(ready["params"]["payload"]["replay_epoch"].string.isEmpty)

        let complete = try fixture("message_complete_error")
        let event = HermesEventMapper.event(from: complete["params"], messageID: nil)
        XCTAssertEqual(event?.kind, .failed)
        XCTAssertTrue(event?.detail?.contains("401") ?? false)

        let syntheticOK = try fixture("message_complete_ok")
        let ok = HermesEventMapper.event(from: syntheticOK["params"], messageID: nil)
        XCTAssertEqual(ok?.kind, .completed)
        XCTAssertEqual(ok?.text, "OK")

        let submit = try fixture("prompt_submit_accepted")["result"]
        XCTAssertEqual(submit["status"].string, "streaming")
        XCTAssertEqual(submit["user_row_id"].int, 3)
        XCTAssertTrue(submit["admission_id"].isNull,
                      "the recorded frame has no durable input identity")

        let unknown = try fixture("error_unknown_method")
        XCTAssertEqual(unknown["error"]["code"].int, -32601)

        let notFound = try fixture("error_session_not_found")
        XCTAssertEqual(notFound["error"]["code"].int, 4007)

        let since = try fixture("session_events_since")["result"]
        XCTAssertEqual(since["latest_seq"].int, 3)
        XCTAssertFalse(since["truncated"].bool)

        let interrupt = try fixture("session_interrupt")["result"]
        XCTAssertEqual(interrupt["status"].string, "interrupted")
    }

    func testWireCodecSplitsMultipleFramesInOneMessage() throws {
        let ready = try fixture("gateway_ready")
        let capabilities = try fixture("client_capabilities")
        let combined = try [ready, capabilities]
            .map { String(decoding: try JSONValue.encode($0), as: UTF8.self) }
            .joined(separator: "\n")

        let frames = HermesWireCodec.frames(from: combined)
        XCTAssertEqual(frames.count, 2, "Hermes can put several frames in one WebSocket message")
        guard case .event(let params) = frames[0] else { return XCTFail("expected the ready event") }
        XCTAssertEqual(params["type"].string, "gateway.ready")
        guard case .response(_, let result) = frames[1] else { return XCTFail("expected a response") }
        XCTAssertTrue(result["server_requests"].array.contains { $0.string == "approval" })
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name).json is missing")
        }
        return try JSONValue.decode(try Data(contentsOf: url))
    }

    private func readySocket() -> FakeHermesSocket {
        let socket = FakeHermesSocket()
        socket.handle("client.capabilities") { _ in .result(.object(["server_requests": .array([])])) }
        socket.handle("ping") { _ in .result(.object(["pong": .bool(true)])) }
        return socket
    }

    private func makeClient(socket: FakeHermesSocket) -> LocalHermesClient {
        LocalHermesClient(configuration: LocalHermesConfiguration(
            endpoint: loopbackEndpoint(),
            profileID: "default",
            tokenProvider: { "local-token" }),
            transport: socket)
    }

    /// Only loopback hosts are constructed in these tests, so the throw is unreachable.
    private func loopbackEndpoint() -> LoopbackEndpoint {
        guard let endpoint = try? LoopbackEndpoint(host: "127.0.0.1", port: 19119) else {
            preconditionFailure("loopback endpoint construction cannot fail")
        }
        return endpoint
    }

    private func journal(state: DeliveryState, messageID: UUID = UUID(),
                         stored: String? = "20260101_000000_probe") -> ExecutionJournal {
        ExecutionJournal(messageID: messageID, conversationID: UUID(), bridgeID: UUID(),
                         state: state, revision: 1, updatedAt: epoch,
                         hermesStoredSessionID: stored)
    }
}
