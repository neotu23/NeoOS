#if DEBUG
import Foundation
import CloudBridgeCore
import CloudBridgeSync

/// A deterministic mailbox for the cloud UI tests.
///
/// It exists only in DEBUG builds and only when the app is launched with `-neoCloudFixture`. Without
/// it, a UI test would need a real iCloud account, a signed container and a running Mac — none of
/// which belong in CI.
final class CloudFixtureMailbox: MailboxTransport, @unchecked Sendable {
    let offline: Bool

    init(offline: Bool) { self.offline = offline }

    func accountScope() async throws -> AccountScope {
        AccountScope(containerID: "iCloud.fixture.NeoOS", environment: "development",
                     userRecordName: "_fixture")
    }

    func synchronize() async throws -> SyncSummary {
        if offline { throw MailboxError.transport("offline (fixture)", retryAfter: nil) }
        return SyncSummary()
    }

    func publish(_ record: OutboundRecord) async throws -> PublishReceipt {
        if offline { throw MailboxError.transport("offline (fixture)", retryAfter: nil) }
        return PublishReceipt(recordName: record.recordName, confirmedAt: Date())
    }
}

extension CloudChatModel {
    /// Build the model against an in-memory store, optionally pre-seeded with one message per state so
    /// the labels can be compared without waiting for a real pipeline.
    static func fixture(offline: Bool, seedStates: Bool) async -> CloudChatModel {
        let model = CloudChatModel(defaults: UserDefaults(suiteName: "NeoOS.CloudFixture")!)
        let scope = AccountScope(containerID: "iCloud.fixture.NeoOS", environment: "development",
                                 userRecordName: "_fixture")
        guard let store = try? BridgeStore(inMemoryScope: scope) else { return model }
        let bridgeID = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
        model.attachFixture(store: store,
                            mailbox: CloudFixtureMailbox(offline: offline),
                            bridgeID: bridgeID)
        if seedStates { await model.seedFixtureStates(bridgeID: bridgeID) }
        return model
    }
}
#endif
