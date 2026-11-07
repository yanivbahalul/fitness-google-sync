import BackgroundTasks
import Foundation

/// Shared objects, so the app UI, the Shortcuts action and background refresh all use
/// the same Google session and sync engine.
@MainActor
enum AppState {
    static let auth = GoogleAuthManager()
    static let sync = SyncCoordinator(auth: auth)
}

/// User settings (also read by the background and Shortcuts paths).
enum AppSettings {
    static let autoSyncOnOpenKey = "autoSyncOnOpen"
    static let backgroundSyncKey = "backgroundSync"
    static let notifyProblemsKey = "notifyProblems"
    static let expiryReminderKey = "expiryReminder"
    static let deficitGoalKey = "deficitGoal"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoSyncOnOpenKey: true,
            backgroundSyncKey: true,
            notifyProblemsKey: true,
            expiryReminderKey: true,
            deficitGoalKey: 500,
        ])
    }

    static var autoSyncOnOpen: Bool { UserDefaults.standard.bool(forKey: autoSyncOnOpenKey) }
    static var backgroundSync: Bool { UserDefaults.standard.bool(forKey: backgroundSyncKey) }
    static var notifyProblems: Bool { UserDefaults.standard.bool(forKey: notifyProblemsKey) }
    static var expiryReminder: Bool { UserDefaults.standard.bool(forKey: expiryReminderKey) }
}

/// Best-effort background sync. iOS decides when (and whether) it runs, typically a few
/// times a day when the phone is idle, charging or on Wi-Fi. Health data can only be
/// written while the phone has been unlocked since restart.
enum BackgroundSync {
    static let taskID = "com.yanivbahalul.stepsbridge.refresh"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task { @MainActor in
                _ = await AppState.sync.syncNow(trigger: .background)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
        guard AppSettings.backgroundSync else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
