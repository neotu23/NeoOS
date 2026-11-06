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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch cloud.status {
                case .unconfigured(let reason):
                    ContentUnavailableView("iCloud 异步模式未配置", systemImage: "icloud.slash",
                                           description: Text(reason))
                case .failed(let reason) where !cloud.isConfigured:
                    ContentUnavailableView("无法同步", systemImage: "exclamationmark.icloud",
                                           description: Text(reason))
                default:
                    conversation
                }
            }
            .navigationDestination(isPresented: $settings.showConnection) {
                CloudConnectionView(cloud: cloud, settings: settings)
            }
            .navigationTitle("NeoOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        settings.showConnection = true
                    } label: {
                        Image(systemName: "icloud")
                    }
                    .accessibilityLabel(L("Connexion iCloud"))
                    .accessibilityIdentifier("open-cloud-connection")
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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Foreground notifications can be delayed. Poll only while this screen is visible;
            // typing never starts a sync, and leaving the screen cancels this task.
            while !Task.isCancelled {
                await cloud.refresh()
                let waiting = cloud.messages.contains { !$0.state.isTerminal && $0.state != .uncertain }
                let delay: Duration
                if case .failed = cloud.status { delay = .seconds(30) }
                else { delay = .seconds(waiting ? 3 : 15) }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            CloudChatStatusBar(cloud: cloud)
            CloudChatTranscript(cloud: cloud)
        }
        .background(AppTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CloudChatComposer(cloud: cloud)
        }
    }
}

/// Each component observes only what it displays. Draft changes never invalidate the transcript.
private struct CloudChatStatusBar: View {
    let cloud: CloudChatModel
    var body: some View { statusBar }

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


}

private struct CloudChatTranscript: View {
    let cloud: CloudChatModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if cloud.messages.isEmpty {
                        Text("在下面写一条消息。它会在 Mac 上的 NeoOS 桥接运行时被送到本机 Hermes。")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 24)
                    }
                    ForEach(cloud.messages) { message in
                        messageBubble(message)
                    }
                    Color.clear.frame(height: 1).id("cloud-bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: cloud.messages.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("cloud-bottom", anchor: .bottom) }
            }
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


}

private struct CloudChatComposer: View {
    @Bindable var cloud: CloudChatModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Écrire un message"), text: $cloud.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.body)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("cloud-composer")
                Button {
                    Task { await cloud.enqueueText() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(cloud.canSend ? AppTheme.accent : Color.secondary.opacity(0.28), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Envoyer"))
                .accessibilityIdentifier("cloud-send-message")
                .disabled(!cloud.canSend)
            }
            if cloud.selectedBridgeID == nil {
                Text("先在 iCloud 设置里选择一台已运行 NeoOS 桥接的 Mac。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.background)
    }
}
