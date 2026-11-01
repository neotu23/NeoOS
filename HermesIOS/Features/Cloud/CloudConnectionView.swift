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

struct CloudConnectionView: View {
    @Bindable var cloud: CloudChatModel
    @Bindable var settings: CloudSettings
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [BridgeDevice] = []

    var body: some View {
        Form {
            Section("模式") {
                Picker("Connexion", selection: $settings.mode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(L(mode.label)).tag(mode)
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
                        await cloud.configure(containerID: settings.containerID,
                                              environment: settings.environment)
                        devices = await loadDevices()
                    }
                }
            }

            Section("这台 Mac") {
                if devices.isEmpty {
                    Text("还没有发现 Mac。请在那台 Mac 上运行 NeoOS 桥接，并在它的设置里开始桥接。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    Button {
                        cloud.selectDevice(device.bridgeID, name: device.name)
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
                        Task { await cloud.startConversation(bridgeID: bridgeID) }
                    }
                }
            }
        }
        .navigationTitle("iCloud 异步连接")
        .task { devices = await loadDevices() }
    }

    private func loadDevices() async -> [BridgeDevice] {
        // Discovery is a pull: the Mac publishes a BridgeDevice record with its heartbeat.
        await cloud.refresh()
        return (try? await cloud.knownDevices()) ?? []
    }
}
