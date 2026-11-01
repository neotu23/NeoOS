import SwiftUI

@main
struct HermesIOSApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    @State private var push = PushNotifications.shared
    @State private var model = AppModel()
    @State private var cloud = CloudChatModel()
    @State private var cloudSettings = CloudSettings()
    @Environment(\.scenePhase) private var phase

    init() {
        _ = Localizer.shared
        AppTheme.configureNavigationBars()
        VoiceSamples.applyLaunchArguments()
    }

    /// Prepare the cloud model. UI tests inject a fixture here so the screen is testable without an
    /// iCloud account or a running Mac; production always goes through CloudKit.
    @MainActor
    private func configureCloudIfNeeded() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-neoCloudFixture") {
            let offline = ProcessInfo.processInfo.arguments.contains("-neoCloudOffline")
            let seeded = ProcessInfo.processInfo.arguments.contains("-neoCloudSeedStates")
            cloud = await CloudChatModel.fixture(offline: offline, seedStates: seeded)
            CloudRuntime.shared.attach(cloud)
            return
        }
        #endif
        guard cloudSettings.mode == .cloud else { return }
        await cloud.configure(containerID: cloudSettings.containerID,
                              environment: cloudSettings.environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, cloud: cloud, cloudSettings: cloudSettings)
                .tint(AppTheme.accent).toggleStyle(AppToggleStyle())
                .task {
                    CloudRuntime.shared.attach(cloud)
                    await configureCloudIfNeeded()
                    await model.boot()
                    await VoiceBench.autorun(model)
                    await push.configure(model.connections)
                    #if DEBUG
                    await push.authorizeFixtureIfRequested()
                    #endif
                }
                .task(id: push.pendingTarget?.id) {
                    guard let target = push.pendingTarget else { return }
                    await model.openNotification(target)
                }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: model.state) { _, value in
                    if value == .connected { Task { await model.refreshWidgets(retryUnavailable: true) } }
                }
                .onChange(of: phase) { _, value in
                    // A temporary inactive phase must not tear down the chat socket.
                    if value == .active {
                        Task { await model.setForeground(true); await push.configure(model.connections); await model.refreshWidgets() }
                        // A missed CloudKit notification is harmless: the foreground pull converges.
                        Task { await CloudRuntime.shared.becameActive() }
                    }
                    else if value == .inactive { model.appBecameInactive() }
                    else if value == .background {
                        Task { await model.setForeground(false) }
                        Task { await CloudRuntime.shared.becameBackground() }
                    }
                }
        }
    }
}
