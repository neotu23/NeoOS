import SwiftUI
import CloudBridgeCore
import CloudBridgeSync

/// The cloud-mode chat: conversations, messages, and an honest status for every message.
///
/// A second, simpler composer lives here on purpose: the direct composer is bound to `AppModel`'s
/// live socket, and teaching it about an asynchronous mailbox would put two state machines in one
/// view.
struct CloudChatView: View {
    @Bindable var cloud: CloudChatModel
    @Bindable var settings: CloudSettings

    var body: some View {
        NavigationStack {
            Group {
                switch cloud.status {
                case .unconfigured(let reason):
                    ContentUnavailableView("iCloud 异步模式未配置", systemImage: "icloud.slash",
                                           description: Text(reason))
                case .failed(let reason) where cloud.messages.isEmpty:
                    ContentUnavailableView("无法同步", systemImage: "exclamationmark.icloud",
                                           description: Text(reason))
                default:
                    conversation
                }
            }
            .navigationTitle("NeoOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        CloudConnectionView(cloud: cloud, settings: settings)
                    } label: {
                        Image(systemName: "icloud")
                    }
                    .accessibilityLabel(L("Connexion iCloud"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await cloud.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(L("Actualiser"))
                }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            statusBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if cloud.messages.isEmpty {
                            Text("在下面写一条消息。它会在 Mac 上的 NeoOS 桥接运行时被送到本机 Hermes。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(cloud.messages) { message in
                            messageBubble(message)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: cloud.messages.count) { _, _ in
                    if let last = cloud.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
            Text(statusText).font(.caption)
            Spacer()
            if let device = cloud.deviceName {
                Text(device).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.surface)
    }

    private var statusIcon: String {
        switch cloud.status {
        case .ready: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .failed: "exclamationmark.icloud"
        case .unconfigured: "icloud.slash"
        }
    }

    private var statusText: String {
        switch cloud.status {
        case .ready: cloud.lastSyncAt.map { "已同步 \($0.formatted(date: .omitted, time: .shortened))" } ?? "就绪"
        case .syncing: "正在同步…"
        case .failed(let reason): reason
        case .unconfigured(let reason): reason
        }
    }

    private func messageBubble(_ message: CloudMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .padding(12)
                .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            if let answer = message.answer {
                Text(answer)
                    .padding(12)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            HStack(spacing: 8) {
                Text(label(for: message.state)).font(.caption2).foregroundStyle(.secondary)
                if !message.state.isTerminal {
                    Button(L("Arrêter cette tâche")) {
                        Task { await cloud.requestCancel(messageID: message.id) }
                    }
                    .font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(message.id)
    }

    /// The three acknowledgements are labelled differently on purpose: "已上传" is not "正在执行".
    private func label(for state: DeliveryState) -> String {
        switch state {
        case .queuedLocal: "本机排队"
        case .uploaded: "已上传，等待 Mac"
        case .received: "Mac 已接收"
        case .dispatching: "Mac 即将提交"
        case .accepted: "Hermes 已接收"
        case .running: "Hermes 正在执行"
        case .waitingOnMac: "Mac 需要人工处理"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .uncertain: "不确定（不会自动重发）"
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(L("Écrire un message"), text: $cloud.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                Button {
                    Task { await cloud.enqueueText() }
                } label: {
                    Image(systemName: "paperplane.fill").padding(10)
                }
                .disabled(!cloud.canSend)
            }
            if !cloud.canSend, cloud.selectedBridgeID == nil {
                Text("先在 iCloud 设置里选择一台已运行 NeoOS 桥接的 Mac。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(AppTheme.background)
    }
}
