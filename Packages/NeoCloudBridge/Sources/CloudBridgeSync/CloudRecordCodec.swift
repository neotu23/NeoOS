import Foundation
import CloudBridgeCore

/// What the codec knows about the bridge it is talking to.
public struct RecordScope: Hashable, Sendable {
    public var bridgeID: UUID?
    public var profileID: String?

    public init(bridgeID: UUID? = nil, profileID: String? = nil) {
        self.bridgeID = bridgeID
        self.profileID = profileID
    }
}

public enum DecodedRecord: Hashable, Sendable {
    case change(RemoteChange)
    /// Kept for diagnostics: never executed, never applied.
    case quarantined(recordName: String, reason: QuarantineReason, raw: Data)
}

/// The one place that knows how a domain value becomes a record body and back.
///
/// CloudKit's own `CKRecord` shape lives behind the adapter, so this type stays testable without an
/// iCloud account. The envelope (`schemaVersion`, `bridgeID`, `profileID`) is carried with every body
/// on purpose: a record that cannot prove which bridge and profile it belongs to must be ignored, not
/// guessed at.
public struct CloudRecordCodec: Sendable {
    public var scope: RecordScope

    public init(scope: RecordScope = RecordScope()) {
        self.scope = scope
    }

    // MARK: - Envelope

    private struct Envelope: Codable {
        var schemaVersion: Int
        var recordType: String
        var bridgeID: String?
        var profileID: String?
        var payload: Data
    }

    private func envelope(_ kind: CloudRecordKind, bridgeID: UUID?, profileID: String?, payload: Data) throws -> Data {
        try RecordCoding.cloudBody(kind, bridgeID: bridgeID, profileID: profileID, payload: payload)
    }

    // MARK: - Encoding

    public func encode(_ request: BridgeRequest) throws -> OutboundRecord {
        try request.validated()
        return OutboundRecord(recordName: CloudRecordKind.request.recordNamePrefix + request.messageID.uuidString,
                              kind: .request,
                              payload: try envelope(.request, bridgeID: request.bridgeID,
                                                    profileID: request.profileID,
                                                    payload: try RecordCoding.encoder().encode(request)))
    }

    public func encode(_ result: BridgeResult) throws -> OutboundRecord {
        try result.validated()
        return OutboundRecord(recordName: CloudRecordKind.result.recordNamePrefix + result.messageID.uuidString,
                              kind: .result,
                              payload: try envelope(.result, bridgeID: result.bridgeID,
                                                    profileID: nil,
                                                    payload: try RecordCoding.encoder().encode(result)))
    }

    public func encode(_ journal: ExecutionJournal) throws -> OutboundRecord {
        let update = ExecutionUpdate(messageID: journal.messageID, state: journal.state,
                                     revision: journal.revision, updatedAt: journal.updatedAt,
                                     errorCode: journal.errorCode, errorSummary: journal.errorSummary)
        return try encode(update, bridgeID: journal.bridgeID, profileID: nil)
    }

    public func encode(_ update: ExecutionUpdate, bridgeID: UUID, profileID: String?) throws -> OutboundRecord {
        let body = try RecordCoding.encoder().encode(update)
        return OutboundRecord(recordName: CloudRecordKind.execution.recordNamePrefix + update.messageID.uuidString,
                              kind: .execution,
                              payload: try envelope(.execution, bridgeID: bridgeID, profileID: profileID, payload: body))
    }

    public func encode(_ conversation: BridgeConversation) throws -> OutboundRecord {
        OutboundRecord(recordName: CloudRecordKind.conversation.recordNamePrefix + conversation.conversationID.uuidString,
                       kind: .conversation,
                       payload: try envelope(.conversation, bridgeID: conversation.bridgeID,
                                             profileID: conversation.profileID,
                                             payload: try RecordCoding.encoder().encode(conversation)))
    }

    public func encode(_ control: BridgeControl) throws -> OutboundRecord {
        OutboundRecord(recordName: CloudRecordKind.control.recordNamePrefix + control.controlID.uuidString,
                       kind: .control,
                       payload: try envelope(.control, bridgeID: control.bridgeID, profileID: nil,
                                             payload: try RecordCoding.encoder().encode(control)))
    }

    public func encode(_ device: BridgeDevice) throws -> OutboundRecord {
        OutboundRecord(recordName: CloudRecordKind.device.recordNamePrefix + device.bridgeID.uuidString,
                       kind: .device,
                       payload: try envelope(.device, bridgeID: device.bridgeID, profileID: device.profileID,
                                             payload: try RecordCoding.encoder().encode(device)))
    }

    // MARK: - Decoding

    public func decode(recordName: String, body: Data) -> DecodedRecord {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else {
            return decodeLegacy(recordName: recordName, body: body)
        }
        // Version first: a newer writer may have changed every other field, and guessing would be
        // worse than ignoring it.
        guard envelope.schemaVersion == CloudSchema.version else {
            return .quarantined(recordName: recordName, reason: .unknownSchemaVersion, raw: body)
        }
        guard let kind = CloudRecordKind(rawValue: envelope.recordType),
              recordName.hasPrefix(kind.recordNamePrefix)
        else {
            return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
        }
        if let expected = scope.bridgeID, let received = envelope.bridgeID.map(UUID.init(uuidString:)),
           expected != received {
            return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
        }
        if let expected = scope.profileID, let received = envelope.profileID, expected != received {
            return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
        }

        let decoder = RecordCoding.decoder()
        switch kind {
        case .request:
            guard let request = try? decoder.decode(BridgeRequest.self, from: envelope.payload),
                  (try? request.validated()) != nil
            else { return .quarantined(recordName: recordName, reason: .malformedBody, raw: body) }
            guard matchesScope(request.bridgeID, request.profileID) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            return .change(.request(request))
        case .result:
            guard let result = try? decoder.decode(BridgeResult.self, from: envelope.payload),
                  (try? result.validated()) != nil,
                  result.role == .assistant
            else { return .quarantined(recordName: recordName, reason: .malformedBody, raw: body) }
            guard matchesScope(result.bridgeID, nil) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            return .change(.result(result))
        case .execution:
            guard let update = try? decoder.decode(ExecutionUpdate.self, from: envelope.payload) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            return .change(.execution(update))
        case .conversation:
            guard let conversation = try? decoder.decode(BridgeConversation.self, from: envelope.payload) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            guard matchesScope(conversation.bridgeID, conversation.profileID) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            return .change(.conversation(conversation))
        case .control:
            guard let control = try? decoder.decode(BridgeControl.self, from: envelope.payload) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            guard matchesScope(control.bridgeID, nil) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            return .change(.control(control))
        case .device:
            guard let device = try? decoder.decode(BridgeDevice.self, from: envelope.payload) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            guard matchesScope(device.bridgeID, device.profileID) else {
                return .quarantined(recordName: recordName, reason: .malformedBody, raw: body)
            }
            return .change(.device(device))
        }
    }

    /// Early builds wrote bare domain JSON into their durable outboxes. Accept only those two
    /// exact shapes; malformed/new-version envelopes must never fall back to a legacy decode.
    private func decodeLegacy(recordName: String, body: Data) -> DecodedRecord {
        let invalid = DecodedRecord.quarantined(recordName: recordName, reason: .malformedBody, raw: body)
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["schemaVersion"] == nil, object["recordType"] == nil else { return invalid }
        let decoder = RecordCoding.decoder()
        if let request = try? decoder.decode(BridgeRequest.self, from: body),
           recordName == CloudRecordKind.request.recordNamePrefix + request.messageID.uuidString,
           matchesScope(request.bridgeID, request.profileID), (try? request.validated()) != nil {
            return .change(.request(request))
        }
        if let result = try? decoder.decode(BridgeResult.self, from: body),
           recordName == CloudRecordKind.result.recordNamePrefix + result.messageID.uuidString,
           result.role == .assistant, matchesScope(result.bridgeID, nil), (try? result.validated()) != nil {
            return .change(.result(result))
        }
        return invalid
    }

    private func matchesScope(_ bridgeID: UUID, _ profileID: String?) -> Bool {
        if let expected = scope.bridgeID, expected != bridgeID { return false }
        if let expected = scope.profileID, let profileID, expected != profileID { return false }
        return true
    }
}

/// Execution journals are mutable, but a delayed upload must never roll a newer revision back.
enum MutableRecordPolicy {
    static func shouldReplace(_ existing: AdapterRecord, with incoming: OutboundRecord) throws -> Bool {
        guard incoming.kind == .execution else { return true }
        let codec = CloudRecordCodec()
        guard case .change(.execution(let current)) = codec.decode(recordName: existing.recordName, body: existing.body),
              case .change(.execution(let next)) = codec.decode(recordName: incoming.recordName, body: incoming.payload),
              current.messageID == next.messageID else { throw MailboxError.conflict(incoming.recordName) }
        if current.revision > next.revision { return false }
        if current.revision == next.revision {
            guard CloudMailbox.businessContentMatches(existing.body, incoming.payload) else {
                throw MailboxError.conflict(incoming.recordName)
            }
            return false
        }
        return true
    }
}
