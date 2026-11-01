import Foundation
import UIKit
import CloudKit
import CloudBridgeCore
import CloudBridgeSync

/// The iOS side of the cloud mailbox's lifecycle.
///
/// CloudKit notifications are *hints*: a push says "the zone changed, pull it". The payload is never
/// treated as a task, and a missing push is never a lost message — the foreground pull is the truth.
@MainActor
final class CloudRuntime {
    static let shared = CloudRuntime()

    private weak var model: CloudChatModel?
    /// A limited background task, not a permanent poller: iOS must be able to suspend us.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func attach(_ model: CloudChatModel) {
        self.model = model
    }

    /// Called from the existing notification delegate for CloudKit pushes only.
    /// Returns true when the payload belonged to the mailbox.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return false }
        await model?.refresh()
        return true
    }

    /// Entering the foreground: pull once. This is what makes a missed notification harmless.
    func becameActive() async {
        guard let model, model.isConfigured else { return }
        await model.refresh()
    }

    /// Going to the background: finish the current pull, then let iOS suspend us.
    func becameBackground() async {
        guard let model, model.isConfigured else { return }
        beginBackgroundTask()
        await model.refresh()
        endBackgroundTask()
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NeoOSCloudSync") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
