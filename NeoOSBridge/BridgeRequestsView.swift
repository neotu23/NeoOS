import SwiftUI
import CloudBridgeCore

/// What the Mac is doing, and what it refuses to do.
///
/// The list is intentionally read-only apart from "stop" and "refresh": this channel does not answer
/// approvals, so there is no button that implies it could.
struct BridgeRequestsView: View {
    @Environment(BridgeEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let controller = environment.controller {
                List {
                    if let waiting = controller.waitingMessageID {
                        Section("等待人工处理") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("任务 \(waiting.uuidString.prefix(8))")
                                    .font(.callout.weight(.semibold))
                                Text(controller.waitingReason ?? "Hermes 需要确认才能继续。")
                                    .font(.callout)
                                Text("此通道首期不支持审批或补充回答；请用直接连接完成需要交互的任务。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("停止这次任务", role: .destructive) {
                                    Task { await controller.interruptActiveTask() }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section("任务") {
                        if controller.tasks.isEmpty {
                            Text("还没有任务。在 iPhone 的 NeoOS 云模式里发起一次对话。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(controller.tasks) { task in
                            row(task, controller: controller)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView("尚未配置",
                                       systemImage: "gearshape",
                                       description: Text("先在「设置」里填写 iCloud 容器和本机 Hermes 连接。"))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NeoOS 桥接").font(.title2.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await environment.refreshNow() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(environment.controller == nil)
        }
        .padding()
    }

    private var subtitle: String {
        guard let controller = environment.controller else { return "未配置" }
        var parts: [String] = []
        switch controller.phase {
        case .running: parts.append("桥接中")
        case .paused: parts.append("已暂停")
        case .stopped: parts.append("未运行")
        case .failed(let reason): parts.append("失败：\(reason)")
        }
        if let last = controller.lastSyncAt {
            parts.append("上次同步 " + Self.formatter.string(from: last))
        }
        if let error = controller.lastError { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func row(_ task: BridgeTaskSummary, controller: BridgeController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.text.isEmpty ? "（空消息）" : task.text)
                    .lineLimit(2)
                Spacer()
                Text(label(for: task.state))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(tint(for: task.state).opacity(0.18), in: Capsule())
                    .foregroundStyle(tint(for: task.state))
            }
            if let error = task.errorSummary {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(task.id.uuidString.prefix(8)).font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if !task.state.isTerminal {
                    Button("停止", role: .destructive) {
                        Task { await controller.cancel(messageID: task.id) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The three acknowledgements stay distinct in the UI too: uploaded is not running, and
    /// uncertain is not failed.
    private func label(for state: DeliveryState) -> String {
        switch state {
        case .queuedLocal: "本机排队"
        case .uploaded: "等待 Mac"
        case .received: "Mac 已接收"
        case .dispatching: "即将提交"
        case .accepted: "Hermes 已接收"
        case .running: "正在执行"
        case .waitingOnMac: "等待人工处理"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .uncertain: "不确定"
        }
    }

    private func tint(for state: DeliveryState) -> Color {
        switch state {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .uncertain: .orange
        case .waitingOnMac: .purple
        case .running, .accepted, .dispatching: .blue
        default: .secondary
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
