import XCTest
@testable import CloudBridgeCore

final class MessageReducerTests: XCTestCase {
    private let messageID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Terminal outcomes are sticky

    func testCompletedCannotRegressToRunning() {
        let completed = ExecutionProjection(messageID: messageID, state: .completed, revision: 4, updatedAt: epoch)
        let newerRevision = ExecutionUpdate(messageID: messageID, state: .running, revision: 5,
                                            updatedAt: epoch.addingTimeInterval(10))

        XCTAssertEqual(MessageReducer.project(current: completed, incoming: newerRevision),
                       .refusedTerminalRegression(current: .completed, incoming: .running),
                       "a stale notification must never un-complete a finished turn")

        let failure = ExecutionUpdate(messageID: messageID, state: .failed, revision: 6, updatedAt: epoch)
        XCTAssertEqual(MessageReducer.project(current: completed, incoming: failure),
                       .refusedTerminalRegression(current: .completed, incoming: .failed))
    }

    func testFailedIsReplacedOnlyByCompleted() {
        let failed = ExecutionProjection(messageID: messageID, state: .failed, revision: 2, updatedAt: epoch,
                                         errorCode: "provider", errorSummary: "no provider")

        let retry = ExecutionUpdate(messageID: messageID, state: .running, revision: 3, updatedAt: epoch)
        XCTAssertEqual(MessageReducer.project(current: failed, incoming: retry),
                       .refusedTerminalRegression(current: .failed, incoming: .running))

        let completed = ExecutionUpdate(messageID: messageID, state: .completed, revision: 4, updatedAt: epoch)
        guard case .applied(let projection) = MessageReducer.project(current: failed, incoming: completed) else {
            return XCTFail("a completed result is the terminal evidence and must win")
        }
        XCTAssertEqual(projection.state, .completed)
        XCTAssertEqual(projection.revision, 4)
        XCTAssertNil(projection.errorCode, "the winning projection replaces the failed details")
    }

    func testStaleAndDuplicateRevisionsAreIgnored() {
        let current = ExecutionProjection(messageID: messageID, state: .running, revision: 7, updatedAt: epoch)

        XCTAssertEqual(MessageReducer.project(current: current,
                                              incoming: ExecutionUpdate(messageID: messageID, state: .running,
                                                                        revision: 7, updatedAt: epoch)),
                       .ignoredStaleRevision(currentRevision: 7))
        XCTAssertEqual(MessageReducer.project(current: current,
                                              incoming: ExecutionUpdate(messageID: messageID, state: .accepted,
                                                                        revision: 6, updatedAt: epoch)),
                       .ignoredStaleRevision(currentRevision: 7),
                       "CloudKit may deliver an older record after a newer one")
    }

    func testFirstProjectionIsApplied() {
        let update = ExecutionUpdate(messageID: messageID, state: .received, revision: 0, updatedAt: epoch)
        guard case .applied(let projection) = MessageReducer.project(current: nil, incoming: update) else {
            return XCTFail("expected the first projection to apply")
        }
        XCTAssertEqual(projection.state, .received)
    }

    func testUncertainCanConvergeOnceEvidenceArrives() {
        let uncertain = ExecutionProjection(messageID: messageID, state: .uncertain, revision: 5, updatedAt: epoch)
        let accepted = ExecutionUpdate(messageID: messageID, state: .accepted, revision: 6, updatedAt: epoch)
        guard case .applied(let projection) = MessageReducer.project(current: uncertain, incoming: accepted) else {
            return XCTFail("uncertain is not terminal: later evidence must be able to resolve it")
        }
        XCTAssertEqual(projection.state, .accepted)
    }

    // MARK: - Schema quarantine

    func testUnknownSchemaIsQuarantined() {
        let future = ExecutionUpdate(messageID: messageID, schemaVersion: CloudSchema.version + 1,
                                     state: .running, revision: 1, updatedAt: epoch)
        XCTAssertEqual(MessageReducer.project(current: nil, incoming: future),
                       .quarantined(reason: .unknownSchemaVersion))

        let current = ExecutionProjection(messageID: messageID, state: .running, revision: 9, updatedAt: epoch)
        XCTAssertEqual(MessageReducer.project(current: current, incoming: future),
                       .quarantined(reason: .unknownSchemaVersion),
                       "a record we cannot read must never overwrite one we can")
    }

    // MARK: - Dependency order

    func testFirstRequestOfAConversationDispatches() {
        let entry = ConversationEntry(messageID: messageID, previousMessageID: nil, state: .received, createdAt: epoch)
        XCTAssertEqual(MessageReducer.dispatchDecision(in: [entry]), .dispatch(messageID: messageID))
    }

    func testUndispatchedLocalMessageIsNotTheBridgesBusiness() {
        let local = ConversationEntry(messageID: messageID, previousMessageID: nil, state: .queuedLocal, createdAt: epoch)
        XCTAssertEqual(MessageReducer.dispatchDecision(in: [local]), .idle)
    }

    func testSecondRequestWaitsForItsPredecessor() {
        let first = UUID(), second = UUID()
        let entries = [
            ConversationEntry(messageID: first, previousMessageID: nil, state: .running, createdAt: epoch),
            ConversationEntry(messageID: second, previousMessageID: first, state: .received,
                              createdAt: epoch.addingTimeInterval(1)),
        ]
        XCTAssertEqual(MessageReducer.dispatchDecision(in: entries), .inFlight(messageID: first))
    }

    func testMissingDependencyWaits() {
        let second = UUID(), unknownPredecessor = UUID()
        let entries = [ConversationEntry(messageID: second, previousMessageID: unknownPredecessor,
                                         state: .received, createdAt: epoch)]
        XCTAssertEqual(MessageReducer.dispatchDecision(in: entries),
                       .waitForDependency(messageID: second, dependency: unknownPredecessor))
    }

    func testCompletedPredecessorReleasesTheNextRequest() {
        let first = UUID(), second = UUID()
        let entries = [
            ConversationEntry(messageID: first, previousMessageID: nil, state: .completed, createdAt: epoch),
            ConversationEntry(messageID: second, previousMessageID: first, state: .received,
                              createdAt: epoch.addingTimeInterval(1)),
        ]
        XCTAssertEqual(MessageReducer.dispatchDecision(in: entries), .dispatch(messageID: second))
    }

    func testFailedOrUncertainPredecessorBlocksTheRest() {
        for state in [DeliveryState.failed, .cancelled, .uncertain] {
            let first = UUID(), second = UUID()
            let entries = [
                ConversationEntry(messageID: first, previousMessageID: nil, state: state, createdAt: epoch),
                ConversationEntry(messageID: second, previousMessageID: first, state: .received,
                                  createdAt: epoch.addingTimeInterval(1)),
            ]
            XCTAssertEqual(MessageReducer.dispatchDecision(in: entries),
                           .blockedByPredecessor(messageID: second, predecessor: first, state: state),
                           "the bridge must not step over a \(state.rawValue) turn")
        }
    }

    func testForkedConversationIsAConflict() {
        let root = UUID(), left = UUID(), right = UUID()
        let entries = [
            ConversationEntry(messageID: root, previousMessageID: nil, state: .completed, createdAt: epoch),
            ConversationEntry(messageID: left, previousMessageID: root, state: .received,
                              createdAt: epoch.addingTimeInterval(1)),
            ConversationEntry(messageID: right, previousMessageID: root, state: .received,
                              createdAt: epoch.addingTimeInterval(2)),
        ]
        XCTAssertEqual(MessageReducer.dispatchDecision(in: entries),
                       .conversationConflict(predecessor: root, messageIDs: [left, right]),
                       "two devices appended to the same turn: device clocks cannot order them")
    }

    // MARK: - Deduplication

    func testDuplicateDeliveryIsCoalesced() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(MessageReducer.newMessageIDs(in: [a, b, a], known: []), [a, b])
        XCTAssertEqual(MessageReducer.newMessageIDs(in: [a, b], known: [a]), [b])
        XCTAssertEqual(MessageReducer.newMessageIDs(in: [a], known: [a]), [])
    }
}
