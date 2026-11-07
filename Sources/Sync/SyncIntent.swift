import AppIntents

/// "Sync StepsBridge" action for the Shortcuts app. With a personal automation
/// (e.g. every day at 08:00 → Sync StepsBridge) the sync runs daily without opening the app.
struct SyncIntent: AppIntent {
    static var title: LocalizedStringResource = "סנכרן את StepsBridge"
    static var description = IntentDescription("מעביר את הנתונים החדשים מ‑Google Health אל Apple Health.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await AppState.sync.syncNow(trigger: .shortcut)
        return .result(dialog: IntentDialog(stringLiteral: outcome.summary))
    }
}

struct StepsBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "סנכרן את \(.applicationName)",
            ]
        )
    }
}
