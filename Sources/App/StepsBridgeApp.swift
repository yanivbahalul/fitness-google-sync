import SwiftUI

@main
struct StepsBridgeApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppSettings.registerDefaults()
        BackgroundSync.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppState.auth)
                .environmentObject(AppState.sync)
                .task {
                    await Notifier.requestPermission()
                    Notifier.scheduleExpiryReminders(enabled: AppSettings.expiryReminder)
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                autoSyncIfNeeded()
            case .background:
                BackgroundSync.schedule()
            default:
                break
            }
        }
    }

    /// Syncs when the app comes to the foreground, at most once every 30 minutes.
    @MainActor
    private func autoSyncIfNeeded() {
        let sync = AppState.sync
        guard AppSettings.autoSyncOnOpen, AppState.auth.isSignedIn, !sync.isSyncing else { return }
        if let last = sync.lastSyncDate, Date().timeIntervalSince(last) < 30 * 60 { return }
        Task { await sync.syncNow(trigger: .appOpen) }
    }
}
