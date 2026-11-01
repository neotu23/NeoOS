import Foundation
import Observation
import CloudBridgeCore
import CloudBridgeSync
import HermesBridgeClient

enum BridgePane: String, Hashable {
    case requests
    case settings
}

/// Owns the objects the two screens share.
///
/// Nothing is created until the user has an endpoint, a credential and an iCloud account: building a
/// CloudKit mailbox before that would produce confusing failures instead of a clear "not configured".
@MainActor
@Observable
final class BridgeEnvironment {
    // Configuration, persisted in UserDefaults (no secrets: the credential lives in the Keychain).
    var containerID: String {
        didSet { defaults.set(containerID, forKey: "containerID") }
    }
    var cloudEnvironment: String {
        didSet { defaults.set(cloudEnvironment, forKey: "cloudEnvironment") }
    }
    var endpointHost: String {
        didSet { defaults.set(endpointHost, forKey: "endpointHost") }
    }
    var endpointPort: String {
        didSet { defaults.set(endpointPort, forKey: "endpointPort") }
    }
    var profileID: String {
        didSet { defaults.set(profileID, forKey: "profileID") }
    }
    var bridgeName: String {
        didSet { defaults.set(bridgeName, forKey: "bridgeName") }
    }

    var selectedPane: BridgePane = .requests
    /// Typed once, moved to the Keychain immediately, then cleared from the field.
    var credentialInput: String = ""
    var statusMessage: String?
    var isConfigured = false
    private(set) var credentialStored = false

    private(set) var controller: BridgeController?
    private var store: BridgeStore?
    private let credentials = HermesKeychain()
    private let defaults = UserDefaults.standard

    init() {
        containerID = defaults.string(forKey: "containerID") ?? "iCloud.org.neil.NeoOS"
        cloudEnvironment = defaults.string(forKey: "cloudEnvironment") ?? "development"
        endpointHost = defaults.string(forKey: "endpointHost") ?? "127.0.0.1"
        endpointPort = defaults.string(forKey: "endpointPort") ?? "9119"
        profileID = defaults.string(forKey: "profileID") ?? "default"
        bridgeName = defaults.string(forKey: "bridgeName")
            ?? Host.current().localizedName
            ?? "这台 Mac"
        credentialStored = (try? credentials.token()) != nil
    }

    var phase: BridgePhase { controller?.phase ?? .stopped }
    var isRunning: Bool { controller?.phase == .running }

    // MARK: - Setup

    func restore() async {
        // The app can only start itself if the user already configured it once.
        guard isConfigured || defaults.bool(forKey: "configured") else { return }
        isConfigured = true
        await bootController(start: false)
    }

    func saveCredential() async {
        do {
            try credentials.save(token: credentialInput)
            credentialInput = ""
            credentialStored = true
            statusMessage = "凭据已保存到本机钥匙串。"
        } catch {
            statusMessage = "无法写入钥匙串：\(error)"
        }
    }

    func clearCredential() {
        do {
            try credentials.clear()
            credentialStored = false
            statusMessage = "已删除本机凭据。"
        } catch {
            statusMessage = "无法删除凭据：\(error)"
        }
    }

    /// Probe the loopback endpoint before promising anything works.
    func probeEndpoint() async {
        do {
            let endpoint = try makeEndpoint()
            let client = LocalHermesClient(configuration: LocalHermesConfiguration(
                endpoint: endpoint,
                profileID: profileID,
                tokenProvider: { [credentials] in try credentials.token() }))
            let capabilities = try await client.probe()
            var lines = ["已连接本机 Hermes。"]
            lines.append(capabilities.version.map { "版本 \($0)" } ?? "版本未知")
            lines.append(capabilities.supportsAdmissionReceipt
                         ? "支持提交状态查询（歧义可核对）。"
                         : "不支持提交状态查询：发送后断线将标记为「不确定」，不会自动重发。")
            statusMessage = lines.joined(separator: " ")
            await client.close()
        } catch {
            statusMessage = "连接失败：\(error)"
        }
    }

    func startBridging() async {
        await bootController(start: true)
    }

    func pauseBridging() {
        controller?.pause()
    }

    func resumeBridging() {
        controller?.resume()
    }

    func stopBridging() {
        controller?.stop()
    }

    func refreshNow() async {
        await controller?.refresh()
        await controller?.drainOne()
    }

    func handleRemoteNotification() async {
        // A push only triggers a pull.
        await controller?.refresh()
        await controller?.drainOne()
    }

    private func bootController(start: Bool) async {
        do {
            let endpoint = try makeEndpoint()
            let scope = try await currentScope()
            let databasePath = try storePath(scope: scope)
            let store = try BridgeStore(path: databasePath, scope: scope)
            self.store = store

            let adapter = CloudKitDatabaseAdapter(configuration: .init(containerIdentifier: containerID,
                                                                      environment: cloudEnvironment))
            let codec = CloudRecordCodec(scope: RecordScope(bridgeID: bridgeID(), profileID: profileID))
            let mailbox = CloudMailbox(store: store, adapter: adapter, codec: codec)
            let hermes = LocalHermesClient(configuration: LocalHermesConfiguration(
                endpoint: endpoint,
                profileID: profileID,
                tokenProvider: { [credentials] in try credentials.token() }))

            let controller = BridgeController(store: store, mailbox: mailbox, hermes: hermes,
                                              codec: codec, bridgeID: bridgeID(), bridgeName: bridgeName,
                                              profileID: profileID)
            self.controller = controller
            isConfigured = true
            defaults.set(true, forKey: "configured")
            await controller.refreshTasks()
            await controller.heartbeat()
            if start { controller.start() }
        } catch {
            statusMessage = "无法启动桥接：\(error)"
            isConfigured = false
        }
    }

    private func currentScope() async throws -> AccountScope {
        let adapter = CloudKitDatabaseAdapter(configuration: .init(containerIdentifier: containerID,
                                                                  environment: cloudEnvironment))
        return try await adapter.account()
    }

    private func makeEndpoint() throws -> LoopbackEndpoint {
        guard let port = Int(endpointPort) else { throw HermesEndpointError.invalidPort }
        return try LoopbackEndpoint(host: endpointHost, port: port)
    }

    /// One stable bridge identity per Mac, per container: a reinstalled app keeps its bridge id so the
    /// iPhone does not see a "new" Mac every launch.
    private func bridgeID() -> UUID {
        let key = "bridgeID-\(containerID)"
        if let stored = defaults.string(forKey: key), let id = UUID(uuidString: stored) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }

    /// The store lives in Application Support, never in an iCloud Drive folder: two sync engines on
    /// one file is exactly the failure mode this design avoids.
    private func storePath(scope: AccountScope) throws -> String {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw CocoaError(.fileNoSuchFile) }
        let directory = base.appendingPathComponent("NeoOSBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Per-account file: switching iCloud identities cannot even see the other account's rows.
        return directory.appendingPathComponent("mailbox-\(scope.storageKey).sqlite").path
    }
}
