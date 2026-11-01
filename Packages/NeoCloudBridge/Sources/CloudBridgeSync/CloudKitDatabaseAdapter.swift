import Foundation
import CloudKit
import CloudBridgeCore

/// The real CloudKit implementation of `CloudDatabaseAdapter`.
///
/// Every rule that matters (ordering, deduplication, retry, scope isolation) lives in
/// `CloudMailbox` and `BridgeStore`; this file only moves bytes and reports what CloudKit said,
/// including the parts that are easy to get wrong: `moreComing`, per-record save results,
/// `serverRecordChanged` and `retryAfter`.
///
/// **Verification status:** compiled, not exercised against a real iCloud account. The container,
/// environment and schema have to exist in CloudKit Console first — see
/// `docs/CLOUDKIT_HERMES_SETUP.md`. Nothing here falls back to the public database.
public final class CloudKitDatabaseAdapter: CloudDatabaseAdapter, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var containerIdentifier: String
        /// `development` or `production`. Declared, never inferred: a mismatch between the two
        /// devices looks exactly like "no data yet".
        public var environment: String
        public var zoneName: String
        public var subscriptionID: String

        public init(containerIdentifier: String, environment: String,
                    zoneName: String = CloudSchema.zoneName,
                    subscriptionID: String = "neoos-mailbox-changes") {
            self.containerIdentifier = containerIdentifier
            self.environment = environment
            self.zoneName = zoneName
            self.subscriptionID = subscriptionID
        }
    }

    private let configuration: Configuration
    private let container: CKContainer
    private let database: CKDatabase
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: configuration.zoneName,
                                                         ownerName: CKCurrentUserDefaultName) }

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.container = CKContainer(identifier: configuration.containerIdentifier)
        self.database = container.privateCloudDatabase
    }

    // MARK: - Account

    public func account() async throws -> AccountScope {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw AdapterError.accountUnavailable(error.localizedDescription)
        }
        guard status == .available else {
            throw AdapterError.accountUnavailable("iCloud account status is \(Self.describe(status))")
        }
        do {
            let recordID = try await container.userRecordID()
            return AccountScope(containerID: configuration.containerIdentifier,
                                environment: configuration.environment,
                                userRecordName: recordID.recordName)
        } catch {
            throw AdapterError.accountUnavailable(error.localizedDescription)
        }
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "noAccount"
        case .restricted: "restricted"
        case .couldNotDetermine: "couldNotDetermine"
        case .temporarilyUnavailable: "temporarilyUnavailable"
        @unknown default: "unknown"
        }
    }

    public func accountChanges() -> AsyncStream<AccountScope?> {
        AsyncStream { continuation in
            // The observer token is an `NSObjectProtocol`, which is not `Sendable`; keep it in a box
            // the termination handler can reach without capturing a non-Sendable value.
            let box = ObserverBox()
            box.observer = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
                    Task {
                        guard let self else { return continuation.finish() }
                        continuation.yield(try? await self.account())
                    }
                }
            continuation.onTermination = { _ in
                if let observer = box.observer { NotificationCenter.default.removeObserver(observer) }
            }
        }
    }

    private final class ObserverBox: @unchecked Sendable {
        var observer: (any NSObjectProtocol)?
    }

    // MARK: - Zone and subscription

    public func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await database.save(zone)
        } catch let error as CKError where error.code == .serverRejectedRequest || error.code == .zoneNotFound {
            // An existing zone saves as a no-op on some backends and as this error on others.
            // A missing zone after configuration is *not* recreated here: recreating it would
            // replay old work into a fresh zone.
            if error.code == .zoneNotFound { throw AdapterError.zoneMissing }
        } catch let error as CKError {
            throw Self.map(error)
        }
    }

    public func subscribe() async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID,
                                                    subscriptionID: configuration.subscriptionID)
        let notification = CKSubscription.NotificationInfo()
        // A notification only says "something changed, go pull". The body is never a task.
        notification.shouldSendContentAvailable = true
        subscription.notificationInfo = notification
        do {
            _ = try await database.save(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Already subscribed: the subscription is idempotent by ID.
        } catch let error as CKError {
            throw Self.map(error)
        }
    }

    // MARK: - Fetch

    public func fetchChanges(token: Data?, limit: Int) async throws -> AdapterChanges {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token.flatMap(Self.decodeToken)
        configuration.resultsLimit = limit

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: configuration])

        final class Collector: @unchecked Sendable {
            var records: [AdapterRecord] = []
            var deletions: [String] = []
            var newToken: Data?
            var moreComing = false
            var failure: CKError?
        }
        let collector = Collector()

        operation.recordWasChangedBlock = { _, result in
            guard case .success(let record) = result else {
                if case .failure(let error) = result, let ckError = error as? CKError {
                    collector.failure = ckError
                }
                return
            }
            // The body travels as opaque bytes: this adapter never interprets the domain payload.
            guard let body = record["body"] as? Data else { return }
            collector.records.append(AdapterRecord(recordName: record.recordID.recordName,
                                                   body: body,
                                                   changeTag: record.recordChangeTag))
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            collector.deletions.append(recordID.recordName)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let fetched):
                collector.newToken = Self.encodeToken(fetched.serverChangeToken)
                collector.moreComing = fetched.moreComing
            case .failure(let error):
                if let ckError = error as? CKError { collector.failure = ckError }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    collector.failure = error as? CKError
                    continuation.resume()
                }
            }
            database.add(operation)
        }

        if let failure = collector.failure { throw Self.map(failure) }
        return AdapterChanges(records: collector.records, deletedRecordNames: collector.deletions,
                              newToken: collector.newToken, moreComing: collector.moreComing)
    }

    public func fetch(recordName: String) async throws -> AdapterRecord? {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            let record = try await database.record(for: recordID)
            guard let body = record["body"] as? Data else { return nil }
            return AdapterRecord(recordName: recordName, body: body, changeTag: record.recordChangeTag)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError {
            throw Self.map(error)
        }
    }

    // MARK: - Save

    public func save(_ records: [OutboundRecord]) async throws -> [AdapterSaveOutcome] {
        guard !records.isEmpty else { return [] }
        let toSave = records.map { outbound -> CKRecord in
            let recordID = CKRecord.ID(recordName: outbound.recordName, zoneID: zoneID)
            let record = CKRecord(recordType: outbound.kind.rawValue, recordID: recordID)
            record["body"] = outbound.payload as NSData
            return record
        }

        final class Collector: @unchecked Sendable {
            var outcomes: [String: AdapterSaveOutcome] = [:]
            var transport: CKError?
        }
        let collector = Collector()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: toSave, recordIDsToDelete: nil)
            // Never overwrite somebody else's copy: a conflict is read back and compared instead.
            operation.savePolicy = .ifServerRecordUnchanged
            operation.perRecordSaveBlock = { recordID, result in
                switch result {
                case .success(let record):
                    collector.outcomes[recordID.recordName] = .saved(recordName: recordID.recordName,
                                                                    changeTag: record.recordChangeTag ?? "")
                case .failure(let error):
                    guard let ckError = error as? CKError else {
                        collector.outcomes[recordID.recordName] = .failed(recordName: recordID.recordName,
                                                                          code: "unknown",
                                                                          message: error.localizedDescription,
                                                                          retryAfter: nil)
                        return
                    }
                    switch ckError.code {
                    case .serverRecordChanged, .constraintViolation:
                        collector.outcomes[recordID.recordName] = .conflict(recordName: recordID.recordName)
                    default:
                        collector.outcomes[recordID.recordName] = .failed(
                            recordName: recordID.recordName,
                            code: String(ckError.code.rawValue),
                            message: ckError.localizedDescription,
                            retryAfter: Self.retryAfter(ckError))
                    }
                }
            }
            operation.modifyRecordsResultBlock = { result in
                if case .failure(let error) = result { collector.transport = error as? CKError }
                continuation.resume()
            }
            database.add(operation)
        }

        if let transport = collector.transport, collector.outcomes.isEmpty {
            throw Self.map(transport)
        }
        // Report one outcome per requested record, in request order.
        return records.map { record in
            collector.outcomes[record.recordName]
                ?? .failed(recordName: record.recordName, code: "missing_outcome",
                           message: "CloudKit did not report a result for this record", retryAfter: nil)
        }
    }

    // MARK: - Mapping

    private static func retryAfter(_ error: CKError) -> TimeInterval? {
        guard let value = error.userInfo[CKErrorRetryAfterKey] as? NSNumber else { return nil }
        return value.doubleValue
    }

    private static func map(_ error: CKError) -> AdapterError {
        switch error.code {
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return .accountUnavailable(error.localizedDescription)
        case .changeTokenExpired:
            return .tokenExpired
        case .zoneNotFound:
            return .zoneMissing
        case .permissionFailure, .managedAccountRestricted:
            return .permissionDenied(error.localizedDescription)
        case .requestRateLimited, .zoneBusy, .serviceUnavailable, .networkUnavailable, .networkFailure:
            return .transport(error.localizedDescription, retryAfter: retryAfter(error))
        default:
            return .transport(error.localizedDescription, retryAfter: retryAfter(error))
        }
    }

    private static func decodeToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
}
