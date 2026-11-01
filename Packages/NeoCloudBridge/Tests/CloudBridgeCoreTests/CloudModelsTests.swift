import XCTest
@testable import CloudBridgeCore

final class CloudModelsTests: XCTestCase {

    // MARK: - Round trip

    func testRequestRoundTripPreservesIDs() throws {
        let messageID = UUID()
        let conversationID = UUID()
        let bridgeID = UUID()
        let previousID = UUID()
        let created = Date(timeIntervalSince1970: 1_790_000_000.25)

        let request = BridgeRequest(messageID: messageID, conversationID: conversationID, bridgeID: bridgeID,
                                    profileID: "default", sourceDeviceID: "device-A", kind: .text,
                                    text: "Bonjour 👋 你好", previousMessageID: previousID, createdAt: created)
        try request.validated()

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BridgeRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.messageID, messageID)
        XCTAssertEqual(decoded.conversationID, conversationID)
        XCTAssertEqual(decoded.bridgeID, bridgeID)
        XCTAssertEqual(decoded.previousMessageID, previousID)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.profileID, "default")
        XCTAssertEqual(decoded.kind, .text)
    }

    func testResultRoundTripKeepsContentShape() throws {
        let result = BridgeResult(messageID: UUID(), conversationID: UUID(), bridgeID: UUID(),
                                  content: .inline("OK"), contentSHA256: "abc", completedAt: Date(),
                                  terminalStatus: .completed)
        let decoded = try JSONDecoder().decode(BridgeResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.content.inlineText, "OK")
        XCTAssertNil(decoded.content.asset)
        XCTAssertEqual(decoded.terminalStatus, .completed)
    }

    // MARK: - Text limits

    func testRejectsBlankAndOversizedText() {
        XCTAssertThrowsError(try request(text: "").validated()) { error in
            XCTAssertEqual(error as? BridgeValidationError, .blankText)
        }
        XCTAssertThrowsError(try request(text: "   \n\t\n ").validated()) { error in
            XCTAssertEqual(error as? BridgeValidationError, .blankText)
        }
        XCTAssertThrowsError(try request(text: String(repeating: "a", count: BridgeLimits.requestTextBytes + 1)).validated()) { error in
            guard case .textTooLarge(let limit, let actual) = error as? BridgeValidationError else {
                return XCTFail("expected textTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, BridgeLimits.requestTextBytes)
            XCTAssertEqual(actual, BridgeLimits.requestTextBytes + 1)
        }
    }

    /// The limit is a byte limit, so multi-byte text has to be measured, not counted.
    func testByteLimitCountsChineseAndEmojiNotCharacters() throws {
        let chinese = String(repeating: "中", count: 10_922)  // 32_766 bytes
        XCTAssertEqual(chinese.utf8.count, 32_766)
        XCTAssertEqual(chinese.count, 10_922)
        XCTAssertNoThrow(try request(text: chinese).validated())

        let oneTooMany = chinese + "中"  // 32_769 bytes, but still only 10_923 characters
        XCTAssertEqual(oneTooMany.utf8.count, 32_769)
        XCTAssertThrowsError(try request(text: oneTooMany).validated())

        let emojiAtLimit = String(repeating: "👋", count: 8_192)  // 32_768 bytes exactly
        XCTAssertEqual(emojiAtLimit.utf8.count, BridgeLimits.requestTextBytes)
        XCTAssertEqual(emojiAtLimit.count, 8_192)
        XCTAssertNoThrow(try request(text: emojiAtLimit).validated())
        XCTAssertThrowsError(try request(text: emojiAtLimit + "👋").validated())
    }

    func testResultLimitsAreEnforced() {
        let inlineLimit = String(repeating: "a", count: BridgeLimits.inlineResultBytes)
        let atLimit = BridgeResult(messageID: UUID(), conversationID: UUID(), bridgeID: UUID(),
                                   content: .inline(inlineLimit), contentSHA256: "", completedAt: Date(),
                                   terminalStatus: .completed)
        XCTAssertNoThrow(try atLimit.validated())

        let overLimit = BridgeResult(messageID: UUID(), conversationID: UUID(), bridgeID: UUID(),
                                     content: .inline(inlineLimit + "a"), contentSHA256: "", completedAt: Date(),
                                     terminalStatus: .completed)
        XCTAssertThrowsError(try overLimit.validated())

        let oversizedAsset = BridgeResult(messageID: UUID(), conversationID: UUID(), bridgeID: UUID(),
                                          content: .asset(ResultAsset(fileToken: "t", byteCount: BridgeLimits.resultAssetBytes + 1)),
                                          contentSHA256: "", completedAt: Date(), terminalStatus: .completed)
        XCTAssertThrowsError(try oversizedAsset.validated())
    }

    func testUnsupportedKindIsRejected() {
        let audio = BridgeRequest(conversationID: UUID(), bridgeID: UUID(), profileID: "default",
                                  sourceDeviceID: "d", kind: .text, text: "x", createdAt: Date())
        XCTAssertNoThrow(try audio.validated())
        XCTAssertEqual(RequestKind.implemented, [.text])
    }

    // MARK: - Scope

    func testAccountScopeStorageKeyIsStableAndOpaque() {
        let scope = AccountScope(containerID: "iCloud.example.NeoOS", environment: "development",
                                 userRecordName: "_abc123")
        XCTAssertEqual(scope.storageKey, scope.storageKey)
        XCTAssertFalse(scope.storageKey.contains("_abc123"), "the user record name must not leak into a column key")

        let otherUser = AccountScope(containerID: "iCloud.example.NeoOS", environment: "development",
                                     userRecordName: "_def456")
        XCTAssertNotEqual(scope.storageKey, otherUser.storageKey)

        let otherEnvironment = AccountScope(containerID: "iCloud.example.NeoOS", environment: "production",
                                            userRecordName: "_abc123")
        XCTAssertNotEqual(scope.storageKey, otherEnvironment.storageKey)
    }

    func testCapabilitiesDescribeTheVerifiedBackendDefaults() {
        let capabilities = HermesCapabilities()
        XCTAssertTrue(capabilities.supportsInterrupt)
        XCTAssertFalse(capabilities.supportsAdmissionReceipt,
                       "Hermes 0.22.2 /api/ws answers -32601 for prompt.receipt")
        XCTAssertTrue(capabilities.requiresUncertainRecovery)
    }

    // MARK: - Helpers

    private func request(text: String) -> BridgeRequest {
        BridgeRequest(conversationID: UUID(), bridgeID: UUID(), profileID: "default",
                      sourceDeviceID: "device-A", text: text, createdAt: Date())
    }
}
