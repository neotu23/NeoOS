import SwiftUI
import CloudBridgeCore
import CloudBridgeSync

/// The cloud connection's settings: container, environment, mode switch, chosen Mac.
///
/// Kept apart from the direct connection's settings. Switching modes here never moves a queue, never
/// rewrites `SavedConnection` and never touches the credentials of the direct channel.
@MainActor
@Observable
final class CloudSettings {
    /// Presentation only: entering cloud mode from a direct screen opens its setup immediately.
    var showConnection = false

    var containerID: String {
        didSet { defaults.set(containerID, forKey: "cloudContainerID") }
    }
    var environment: String {
        didSet { defaults.set(environment, forKey: "cloudEnvironment") }
    }
    var mode: ConnectionMode {
        didSet { ConnectionModeStore.save(mode, defaults) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        containerID = defaults.string(forKey: "cloudContainerID") ?? "iCloud.org.neil.NeoOS"
        environment = defaults.string(forKey: "cloudEnvironment") ?? "development"
        mode = ConnectionModeStore.load(defaults)
    }
}

/// Available before a direct server has been saved, as well as in the connections menu.
struct CloudConnectionButton: View {
    @Environment(CloudSettings.self) private var settings

    var body: some View {
        Button {
            settings.showConnection = true
            settings.mode = .cloud
        } label: {
            Label(L(ConnectionMode.cloud.label), systemImage: "icloud")
        }
        .accessibilityIdentifier("open-cloud-connection")
    }
}

struct CloudConnectionView: View {
    @Bindable var cloud: CloudChatModel
    @Bindable var settings: CloudSettings
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [BridgeDevice] = []
    @State private var isConnecting = false
    @State private var discoveryError: String?

    var body: some View {
        Form {
            Section("模式") {
                Picker("Connexion", selection: $settings.mode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(L(mode.label)).tag(mode)
                            .accessibilityIdentifier("connection-mode-\(mode.rawValue)")
                    }
                }
                .pickerStyle(.inline)
                Text(L(settings.mode.detail)).font(.caption).foregroundStyle(.secondary)
                Text("切换模式不会搬移或重投队列：云端未发送的消息留在云端，直连的会话保持原样。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("iCloud") {
                TextField("容器标识", text: $settings.containerID)
                    .textFieldStyle(.roundedBorder)
                Picker("环境", selection: $settings.environment) {
                    Text("开发").tag("development")
                    Text("生产").tag("production")
                }
                Button("连接并同步") {
                    Task {
                        isConnecting = true
                        defer { isConnecting = false }
                        await cloud.configure(containerID: settings.containerID,
                                              environment: settings.environment)
                        devices = await loadDevices()
                    }
                }
                .disabled(isConnecting)
                if isConnecting {
                    ProgressView("正在连接并同步 iCloud…")
                } else {
                    syncStatus
                }
                #if targetEnvironment(simulator)
                Text("模拟器需要单独登录 iCloud。请打开模拟器内的「设置」，登录与 Mac 相同的 Apple 账号。")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }

            Section("这台 Mac") {
                if devices.isEmpty, discoveryError == nil, case .ready = cloud.status {
                    Text("同步成功，但还没有发现 Mac。请确认两端的 iCloud 账号、容器和环境相同，并检查 Mac 是否显示「设备信息已发布到 iCloud」。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    Button {
                        Task {
                            await cloud.selectDevice(device.bridgeID, name: device.name, profileID: device.profileID)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("profile \(device.profileID) · 最后联络 \(device.lastSeenAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if cloud.selectedBridgeID == device.bridgeID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let bridgeID = cloud.selectedBridgeID, !devices.isEmpty {
                    Button("新建对话") {
                        Task {
                            await cloud.startConversation(bridgeID: bridgeID, profileID: cloud.selectedProfileID)
                            if cloud.activeConversationID != nil { dismiss() }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("cloud-connection-settings")
        .navigationTitle("iCloud 异步连接")
        .task { devices = await loadDevices() }
    }

    @ViewBuilder private var syncStatus: some View {
        switch cloud.status {
        case .unconfigured(let reason), .failed(let reason):
            Label(reason, systemImage: "exclamationmark.icloud")
                .font(.caption).foregroundStyle(.red)
                .textSelection(.enabled)
        case .syncing:
            ProgressView("正在同步 iCloud…")
        case .ready:
            if let discoveryError {
                Label(discoveryError, systemImage: "exclamationmark.icloud")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Label("iCloud 已同步 · 发现 \(devices.count) 台 Mac", systemImage: "checkmark.icloud")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadDevices() async -> [BridgeDevice] {
        // Discovery is a pull: the Mac publishes a BridgeDevice record with its heartbeat.
        do {
            let devices = try await cloud.knownDevices()
            discoveryError = nil
            return devices
        } catch {
            discoveryError = "无法读取 Mac 列表：\(error)"
            return []
        }
    }
}
