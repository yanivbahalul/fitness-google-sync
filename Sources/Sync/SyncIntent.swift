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

/// "How many calories did I eat today?" — sets today's eaten total (e.g. copied from Cali).
struct SetEatenIntent: AppIntent {
    static var title: LocalizedStringResource = "הזן קלוריות שנאכלו היום"
    static var description = IntentDescription("מעדכן את סך הקלוריות שנאכלו היום במאזן הקלורי של StepsBridge.")
    static var openAppWhenRun = false

    @Parameter(title: "קלוריות", requestValueDialog: IntentDialog("כמה קלוריות נאכלו היום בסך הכול?"))
    var calories: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppState.sync.setManualEatenToday(max(0, calories))
        return .result(dialog: IntentDialog(stringLiteral: await EnergyDialog.text(eaten: max(0, calories))))
    }
}

/// "Add 450 calories" — adds a meal to today's eaten total.
struct AddEatenIntent: AppIntent {
    static var title: LocalizedStringResource = "הוסף קלוריות שנאכלו"
    static var description = IntentDescription("מוסיף ארוחה לסך הקלוריות שנאכלו היום.")
    static var openAppWhenRun = false

    @Parameter(title: "קלוריות", requestValueDialog: IntentDialog("כמה קלוריות להוסיף?"))
    var calories: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sync = AppState.sync
        let total = max(0, (sync.manualEatenToday ?? 0) + calories)
        sync.setManualEatenToday(total)
        return .result(dialog: IntentDialog(stringLiteral: await EnergyDialog.text(eaten: total)))
    }
}

@MainActor
enum EnergyDialog {
    /// Spoken reply: eaten total plus today's deficit when Google's burned value is known.
    static func text(eaten: Int) async -> String {
        await AppState.sync.refreshEnergy()
        var text = "עודכן: \(eaten) קלוריות נאכלו היום."
        if let deficit = AppState.sync.energy?.deficit {
            text += deficit >= 0 ? " גרעון של \(deficit) קלוריות עד עכשיו." : " עודף של \(-deficit) קלוריות עד עכשיו."
        }
        return text
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
        AppShortcut(
            intent: SetEatenIntent(),
            phrases: [
                "הזן קלוריות ב\(.applicationName)",
                "עדכן קלוריות ב\(.applicationName)",
                "Log calories in \(.applicationName)",
            ]
        )
        AppShortcut(
            intent: AddEatenIntent(),
            phrases: [
                "הוסף קלוריות ב\(.applicationName)",
                "Add calories in \(.applicationName)",
            ]
        )
    }
}
