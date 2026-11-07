import AppIntents

/// "Sync HealthBridge" action for the Shortcuts app. With a personal automation
/// (e.g. every day at 08:00 → Sync HealthBridge) the sync runs daily without opening the app.
struct SyncIntent: AppIntent {
    static var title: LocalizedStringResource = "סנכרן את HealthBridge"
    static var description = IntentDescription("מעביר את הנתונים החדשים מ‑Google Health אל Apple Health.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await AppState.sync.syncNow(trigger: .shortcut)
        return .result(dialog: IntentDialog(stringLiteral: outcome.summary))
    }
}

/// "Add 450 calories" - adds a quick entry to today's food diary.
struct AddEatenIntent: AppIntent {
    static var title: LocalizedStringResource = "הוסף קלוריות ליומן"
    static var description = IntentDescription("מוסיף הזנה מהירה של קלוריות ליומן האוכל של היום.")
    static var openAppWhenRun = false

    @Parameter(title: "קלוריות", requestValueDialog: IntentDialog("כמה קלוריות להוסיף?"))
    var calories: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let food = FoodLog.shared
        await food.addQuick(kcal: Double(max(0, calories)))
        let eaten = Int(food.total(on: Date()))
        var text = "נוסף. נאכלו היום \(eaten) קלוריות."
        if let burned = await AppState.sync.burned(on: Date()) {
            let deficit = burned - eaten
            text += deficit >= 0 ? " גרעון של \(deficit) עד עכשיו." : " עודף של \(-deficit) עד עכשיו."
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
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
            intent: AddEatenIntent(),
            phrases: [
                "הוסף קלוריות ב\(.applicationName)",
                "הזן קלוריות ב\(.applicationName)",
                "Add calories in \(.applicationName)",
                "Log calories in \(.applicationName)",
            ]
        )
    }
}
