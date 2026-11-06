import XCTest
import CloudBridgeCore
@testable import CloudBridgeSync

final class CloudRecordCodecTests: XCTestCase {
    private let bridgeID = UUID()
    private let conversationID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private var codec: CloudRecordCodec { CloudRecordCodec(scope: RecordScope(bridgeID: bridgeID, profileID: "default")) }

    // MARK: - Names

    func testRecordNamesAreTypedAndFreeOfUserText() throws {
        let request = makeRequest(text: "私人内容：我的地址是…")
        let record = try codec.encode(request)
        XCTAssertEqual(record.recordName, "request_\(request.messageID.uuidString)")
        XCTAssertEqual(record.kind, .request)
        XCTAssertFalse(record.recordName.contains("私人"), "a record name must never carry user text")

        let result = BridgeResult(messageID: request.messageID, conversationID: conversationID,
                                  bridgeID: bridgeID, content: .inline("OK"), contentSHA256: "s",
                                  completedAt: epoch, terminalStatus: .completed)
        XCTAssertEqual(try codec.encode(result).recordName, "result_\(request.messageID.uuidString)")

        let control = BridgeControl(messageID: request.messageID, bridgeID: bridgeID, createdAt: epoch)
        XCTAssertEqual(try codec.encode(control).recordName, "control_\(control.controlID.uuidString)")
    }

    // MARK: - Round trip

    func testRequestRoundTripThroughTheCodec() throws {
        let request = makeRequest(text: "只回复 OK 👋 你好")
        let record = try codec.encode(request)
        guard case .change(.request(let decoded)) = codec.decode(recordName: record.recordName, body: record.payload)
        else { return XCTFail("expected a request change") }
        XCTAssertEqual(decoded, request)
    }

    func testResultRoundTripKeepsInlineContent() throws {
        let result = BridgeResult(messageID: UUID(), conversationID: conversationID, bridgeID: bridgeID,
                                  content: .inline("答案"), contentSHA256: "sha", completedAt: epoch,
                                  terminalStatus: .completed)
        let record = try codec.encode(result)
        guard case .change(.result(let decoded)) = codec.decode(recordName: record.recordName, body: record.payload)
        else { return XCTFail("expected a result change") }
        XCTAssertEqual(decoded.content.inlineText, "答案")
        XCTAssertEqual(decoded.terminalStatus, .completed)
    }

    func testLegacyDurableRequestIsReadableWithoutLosingScopeChecks() throws {
        let request = makeRequest(text: "旧版本已上传的消息")
        let name = "request_\(request.messageID.uuidString)"
        let body = try RecordCoding.encoder().encode(request)
        XCTAssertEqual(codec.decode(recordName: name, body: body), .change(.request(request)))
        let other = CloudRecordCodec(scope: RecordScope(bridgeID: UUID()))
        guard case .quarantined = other.decode(recordName: name, body: body) else {
            return XCTFail("legacy support must still enforce the selected bridge")
        }
        guard case .quarantined = codec.decode(recordName: "request_\(UUID().uuidString)", body: body) else {
            return XCTFail("legacy record name must match the payload ID")
        }
    }

    func testLegacyDurableResultIsReadable() throws {
        let result = BridgeResult(messageID: UUID(), conversationID: conversationID, bridgeID: bridgeID,
                                  content: .inline("旧版回复"), contentSHA256: "s", completedAt: epoch,
                                  terminalStatus: .completed)
        let body = try RecordCoding.encoder().encode(result)
        XCTAssertEqual(codec.decode(recordName: "result_\(result.messageID.uuidString)", body: body),
                       .change(.result(result)))
    }

    func testExecutionRecordCanAdvanceButCannotRegressOrRewriteSameRevision() throws {
        let messageID = UUID()
        let first = try codec.encode(ExecutionUpdate(messageID: messageID, state: .dispatching,
                                                    revision: 1, updatedAt: epoch),
                                     bridgeID: bridgeID, profileID: nil)
        let next = try codec.encode(ExecutionUpdate(messageID: messageID, state: .running,
                                                   revision: 2, updatedAt: epoch),
                                    bridgeID: bridgeID, profileID: nil)
        let existingFirst = AdapterRecord(recordName: first.recordName, body: first.payload)
        let existingNext = AdapterRecord(recordName: next.recordName, body: next.payload)
        XCTAssertTrue(try MutableRecordPolicy.shouldReplace(existingFirst, with: next))
        XCTAssertFalse(try MutableRecordPolicy.shouldReplace(existingNext, with: first))
        XCTAssertFalse(try MutableRecordPolicy.shouldReplace(existingNext, with: next))
        let conflicting = try codec.encode(ExecutionUpdate(messageID: messageID, state: .failed,
                                                          revision: 2, updatedAt: epoch),
                                           bridgeID: bridgeID, profileID: nil)
        XCTAssertThrowsError(try MutableRecordPolicy.shouldReplace(existingNext, with: conflicting))
    }

    // MARK: - Quarantine

    func testUnknownSchemaIsQuarantined() throws {
        let record = try codec.encode(makeRequest(text: "hi"))
        let bumped = try bumpSchemaVersion(record.payload, to: CloudSchema.version + 1)
        guard case .quarantined(_, let reason, _) = codec.decode(recordName: record.recordName, body: bumped) else {
            return XCTFail("a newer schema must be quarantined")
        }
        XCTAssertEqual(reason, .unknownSchemaVersion)
    }

    func testMalformedBodyIsQuarantined() {
        guard case .quarantined(_, let reason, _) = codec.decode(recordName: "request_\(UUID().uuidString)",
                                                                 body: Data("not json".utf8))
        else { return XCTFail("expected quarantine") }
        XCTAssertEqual(reason, .malformedBody)
    }

    func testMissingFieldsAreQuarantined() {
        // A well-formed envelope whose payload lacks the request fields.
        let body = Data(#"{"schemaVersion":1,"recordType":"BridgeRequest","payload":"e30="}"#.utf8)
        guard case .quarantined(_, let reason, _) = codec.decode(recordName: "request_\(UUID().uuidString)", body: body)
        else { return XCTFail("expected quarantine") }
        XCTAssertEqual(reason, .malformedBody)
    }

    func testWrongBridgeOrProfileIsQuarantined() throws {
        let otherBridge = BridgeRequest(conversationID: conversationID, bridgeID: UUID(), profileID: "default",
                                       sourceDeviceID: "d", text: "别的 Mac", createdAt: epoch)
        let record = try codec.encode(otherBridge)
        guard case .quarantined(_, _, _) = codec.decode(recordName: record.recordName, body: record.payload) else {
            return XCTFail("a record for another bridge must not be applied")
        }

        let otherProfile = BridgeRequest(conversationID: conversationID, bridgeID: bridgeID, profileID: "work",
                                         sourceDeviceID: "d", text: "别的 profile", createdAt: epoch)
        let profileRecord = try codec.encode(otherProfile)
        guard case .quarantined(_, _, _) = codec.decode(recordName: profileRecord.recordName,
                                                       body: profileRecord.payload) else {
            return XCTFail("a record for another profile must not be applied")
        }
    }

    func testRecordNamePrefixMustMatchTheRecordType() throws {
        let record = try codec.encode(makeRequest(text: "hi"))
        // Same body, wrong name: the pairing is part of the contract.
        guard case .quarantined(_, _, _) = codec.decode(recordName: "result_\(UUID().uuidString)",
                                                        body: record.payload) else {
            return XCTFail("a mismatched record name must be quarantined")
        }
    }

    func testOversizedTextNeverSurvivesEncoding() {
        let huge = String(repeating: "中", count: 12_000)
        let request = makeRequest(text: huge)
        XCTAssertThrowsError(try codec.encode(request))
    }

    func testBlankTextIsRefusedAtDecodeTime() throws {
        // Encoded without validation (a foreign writer), then decoded: blank must not be applied.
        let request = makeRequest(text: "x")
        let payload = try RecordCoding.encoder().encode(request)
        let tampered = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: #""text":"x""#,
                                                                                    with: #""text":"   ""#)
        let envelope = Data(#"{"schemaVersion":1,"recordType":"BridgeRequest","payload":"#.utf8)
            + Data("\"\(Data(tampered.utf8).base64EncodedString())\"".utf8) + Data("}".utf8)
        guard case .quarantined(_, let reason, _) = codec.decode(recordName: "request_\(request.messageID.uuidString)",
                                                                body: envelope)
        else { return XCTFail("blank text must be quarantined") }
        XCTAssertEqual(reason, .malformedBody)
    }

    func testResultContentIsExactlyOneOfTextOrAsset() throws {
        let result = BridgeResult(messageID: UUID(), conversationID: conversationID, bridgeID: bridgeID,
                                  content: .inline("text"), contentSHA256: "s", completedAt: epoch,
                                  terminalStatus: .completed)
        let record = try codec.encode(result)
        guard case .change(.result(let decoded)) = codec.decode(recordName: record.recordName, body: record.payload)
        else { return XCTFail("expected a result") }
        XCTAssertEqual(decoded.content.inlineText, "text")
        XCTAssertNil(decoded.content.asset, "text and asset are exclusive")
    }

    func testNonAssistantRoleIsRefused() {
        // A result record claiming to be a user row must not be applied.
        let body = Data(#"""
        {"schemaVersion":1,"recordType":"BridgeResult","payload":"e30="}
        """#.utf8)
        guard case .quarantined(_, _, _) = codec.decode(recordName: "result_\(UUID().uuidString)", body: body) else {
            return XCTFail("expected quarantine")
        }
    }

    // MARK: - Helpers

    private func makeRequest(text: String) -> BridgeRequest {
        BridgeRequest(conversationID: conversationID, bridgeID: bridgeID, profileID: "default",
                      sourceDeviceID: "device-A", text: text, createdAt: epoch)
    }

    /// Re-encode the envelope with a different `schemaVersion`, the way a future writer would.
    private func bumpSchemaVersion(_ body: Data, to version: Int) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw XCTSkip("unexpected envelope shape")
        }
        object["schemaVersion"] = version
        return try JSONSerialization.data(withJSONObject: object)
    }
}
