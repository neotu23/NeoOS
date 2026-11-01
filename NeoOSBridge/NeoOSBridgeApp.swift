import SwiftUI
import CloudBridgeCore
import CloudBridgeSync
import HermesBridgeClient

/// The Mac side of the cloud mailbox.
///
/// It is a normal user-session app on purpose: no root daemon, no automatic login item, no sleep
/// prevention. Closing the window keeps it bridging; quitting stops it.
@main
struct NeoOSBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) private var appDelegate
    @State private var environment = BridgeEnvironment()

    var body: some Scene {
        WindowGroup("NeoOS 桥接") {
            BridgeRootView()
                .environment(environment)
                .onAppear { appDelegate.attach(environment) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// macOS receives CloudKit pushes through the app delegate, not through a UI scene.
///
/// A notification is only ever a hint: it says "something in the zone changed, pull". The payload is
/// never treated as a task.
@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    private weak var environment: BridgeEnvironment?
    private var lock: SingleInstanceLock?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let lock = SingleInstanceLock()
        if !lock.acquire() {
            // A second process with the same bridge identity must never run an executor.
            NSApp.terminate(nil)
        }
        self.lock = lock
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The window closing is not "stop bridging": the user says stop from the settings screen.
        false
    }

    /// Attached from the first appearance of the window; restoration runs as its own task so the
    /// scene does not wait on CloudKit.
    func attach(_ environment: BridgeEnvironment) {
        self.environment = environment
        Task { await environment.restore() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await environment?.handleRemoteNotification() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lock?.release()
    }
}

/// One executor per macOS user. `flock` on the user's own support directory: no daemon, no sudo.
final class SingleInstanceLock: @unchecked Sendable {
    private var descriptor: Int32 = -1

    private var lockURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NeoOSBridge", isDirectory: true)
    }

    func acquire() -> Bool {
        guard let directory = lockURL else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("executor.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

struct BridgeRootView: View {
    @Environment(BridgeEnvironment.self) private var environment

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { environment.selectedPane },
                                    set: { environment.selectedPane = $0 ?? .requests })) {
                Label("任务", systemImage: "tray.full").tag(BridgePane.requests)
                Label("设置", systemImage: "gearshape").tag(BridgePane.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch environment.selectedPane {
            case .requests: BridgeRequestsView()
            case .settings: BridgeSettingsView()
            }
        }
    }
}
