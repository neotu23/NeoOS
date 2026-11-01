import SwiftUI
import CloudBridgeCore

/// The settings screen: iCloud, loopback endpoint, credential, profile, start/stop.
struct BridgeSettingsView: View {
    @Environment(BridgeEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment
        Form {
            Section("iCloud") {
                TextField("容器标识", text: $environment.containerID)
                    .textFieldStyle(.roundedBorder)
                Picker("环境", selection: $environment.cloudEnvironment) {
                    Text("开发（development）").tag("development")
                    Text("生产（production）").tag("production")
                }
                Text("两端必须使用同一个容器和同一个环境。容器需要在 Apple Developer 页面创建并部署 Schema，详见 docs/CLOUDKIT_HERMES_SETUP.md。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本机 Hermes") {
                TextField("回环地址", text: $environment.endpointHost)
                    .textFieldStyle(.roundedBorder)
                TextField("端口", text: $environment.endpointPort)
                    .textFieldStyle(.roundedBorder)
                TextField("Profile", text: $environment.profileID)
                    .textFieldStyle(.roundedBorder)
                Text("首期只允许 localhost、127.0.0.1 或 ::1；不会使用 Tailscale 或公网地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("本机令牌（保存后清空输入框）", text: $environment.credentialInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存凭据") { Task { await environment.saveCredential() } }
                        .disabled(environment.credentialInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("删除凭据", role: .destructive) { environment.clearCredential() }
                        .disabled(!environment.credentialStored)
                    Label(environment.credentialStored ? "已保存在钥匙串" : "尚未保存",
                          systemImage: environment.credentialStored ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("测试连接") { Task { await environment.probeEndpoint() } }
            }

            Section("这台 Mac") {
                TextField("显示名称", text: $environment.bridgeName)
                    .textFieldStyle(.roundedBorder)
                Text("名称只用于在 iPhone 上区分不同的 Mac；设备标识由本机生成并复用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("桥接状态") {
                HStack {
                    Circle()
                        .fill(color(for: environment.phase))
                        .frame(width: 10, height: 10)
                    Text(label(for: environment.phase))
                    Spacer()
                    Button("开始") { Task { await environment.startBridging() } }
                        .disabled(environment.isRunning)
                    Button("暂停") { environment.pauseBridging() }
                        .disabled(!environment.isRunning)
                    Button("继续") { environment.resumeBridging() }
                        .disabled(environment.phase != .paused)
                    Button("停止", role: .destructive) { environment.stopBridging() }
                        .disabled(environment.phase == .stopped)
                }
                if let message = environment.statusMessage {
                    Text(message).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func label(for phase: BridgePhase) -> String {
        switch phase {
        case .stopped: "未运行"
        case .running: "桥接中"
        case .paused: "已暂停（不再派发新任务）"
        case .failed(let reason): "失败：\(reason)"
        }
    }

    private func color(for phase: BridgePhase) -> Color {
        switch phase {
        case .stopped: .secondary
        case .running: .green
        case .paused: .orange
        case .failed: .red
        }
    }
}
