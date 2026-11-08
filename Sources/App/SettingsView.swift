import SwiftUI
import AppIntents

struct SettingsView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.autoSyncOnOpenKey) private var autoSyncOnOpen = true
    @AppStorage(AppSettings.backgroundSyncKey) private var backgroundSync = true
    @AppStorage(AppSettings.notifyProblemsKey) private var notifyProblems = true
    @AppStorage(AppSettings.expiryReminderKey) private var expiryReminder = true
    @AppStorage(AppSettings.deficitGoalKey) private var deficitGoal = 500
    @State private var trackingStartChanged = false
    @ObservedObject private var food = FoodLog.shared
    @AppStorage(MealModel.settingsKey) private var mealModel = MealModel.opus.rawValue
    @State private var apiKey = AnthropicKeyStore.key ?? ""
    @State private var keySaved = AnthropicKeyStore.key != nil

    private let expiry = Notifier.signingExpiry

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Sync
                Section {
                    LabeledContent {
                        Text(auth.isSignedIn ? "מחובר" : "לא מחובר")
                            .foregroundStyle(auth.isSignedIn ? .green : .secondary)
                    } label: {
                        SettingLabel("Google Health", symbol: "person.crop.circle")
                    }
                    if let date = sync.lastSyncDate {
                        LabeledContent {
                            Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .he)))
                        } label: {
                            SettingLabel("סנכרון אחרון", symbol: "clock")
                        }
                    }
                    Picker(selection: $sync.range) {
                        ForEach(SyncRange.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingLabel("טווח סנכרון ידני", symbol: "calendar")
                    }
                    NavigationLink {
                        SyncTypesView()
                    } label: {
                        LabeledContent {
                            Text("\(sync.enabledCount) מתוך \(sync.items.count)")
                        } label: {
                            SettingLabel("מה לסנכרן", symbol: "checklist")
                        }
                    }
                    NavigationLink {
                        StepsCheckView()
                    } label: {
                        SettingLabel("בדיקת צעדים מול Google", symbol: "checkmark.shield")
                    }
                } header: {
                    Text("סנכרון")
                }

                Section {
                    Toggle(isOn: $autoSyncOnOpen) {
                        SettingLabel("בפתיחת האפליקציה", symbol: "iphone")
                    }
                    Toggle(isOn: $backgroundSync) {
                        SettingLabel("ברקע", symbol: "moon.zzz")
                    }
                    .onChange(of: backgroundSync) { _ in BackgroundSync.schedule() }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingLabel("בשעה קבועה (קיצורים)", symbol: "square.stack.3d.up")
                        Text("קיצורים ← אוטומציה ← שעה ביום ← \"סנכרן את HealthBridge\"")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    if #available(iOS 16.4, *) {
                        ShortcutsLink()
                            .shortcutsLinkStyle(.automaticOutline)
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("סנכרון אוטומטי")
                }

                // MARK: Nutrition
                Section {
                    Stepper(value: $deficitGoal, in: 0...2000, step: 50) {
                        LabeledContent {
                            Text("\(deficitGoal.formatted()) קק\"ל").monospacedDigit()
                        } label: {
                            SettingLabel("יעד גרעון יומי", symbol: "target")
                        }
                    }
                    DatePicker(selection: Binding(
                        get: { AppSettings.foodTrackingStart },
                        set: { AppSettings.foodTrackingStart = $0; trackingStartChanged.toggle() }
                    ), in: ...Date(), displayedComponents: .date) {
                        SettingLabel("סופרים אוכל החל מ", symbol: "calendar.badge.clock")
                    }
                    .id(trackingStartChanged)
                    let oldImports = FoodLog.shared.importedEntries(before: AppSettings.foodTrackingStart).count
                    if oldImports > 0 {
                        Button(role: .destructive) {
                            Task { await FoodLog.shared.deleteImported(before: AppSettings.foodTrackingStart) }
                        } label: {
                            Label("מחק \(oldImports) רשומות Cali ישנות", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("תזונה")
                }

                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(keySaved ? "עדכן מפתח" : "שמור מפתח") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        AnthropicKeyStore.save(trimmed.isEmpty ? nil : trimmed)
                        keySaved = !trimmed.isEmpty
                    }
                    if keySaved {
                        Label("מפתח שמור במכשיר", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Picker("מודל", selection: $mealModel) {
                        ForEach(MealModel.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                        Label("יצירת מפתח ב‑console.anthropic.com", systemImage: "key")
                    }
                } header: {
                    Text("ניתוח ארוחות (Claude)")
                }

                // MARK: Other
                Section {
                    Toggle(isOn: $notifyProblems) {
                        SettingLabel("כשסנכרון אוטומטי נכשל", symbol: "bell.badge")
                    }
                    Toggle(isOn: $expiryReminder) {
                        SettingLabel("תזכורת לחידוש ב‑Xcode", symbol: "hammer")
                    }
                    .onChange(of: expiryReminder) { on in Notifier.scheduleExpiryReminders(enabled: on) }
                    if let expiry {
                        LabeledContent("האפליקציה בתוקף עד", value: expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .he)))
                    }
                } header: {
                    Text("התראות")
                }

                Section {
                    if auth.isSignedIn {
                        Button(role: .destructive) {
                            auth.signOut()
                        } label: {
                            Label("התנתק מ‑Google", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                    Link(destination: URL(string: "https://yanivbahalul.github.io/fitness-google-sync/privacy.html")!) {
                        Label("מדיניות פרטיות", systemImage: "hand.raised")
                    }
                } header: {
                    Text("חשבון ופרטיות")
                } footer: {
                    Text("נתוני הבריאות עוברים ישירות מ‑Google Health ל‑Apple Health, בלי שרת. ערכי מזון: מאגר צמרת, משרד הבריאות. מוצרים ארוזים: Open Food Facts.")
                }
            }
            .navigationTitle("הגדרות")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סיום") { dismiss() }
                }
            }
        }
        .appChrome()
    }
}

private struct SettingLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 12) {
            SoftIcon(symbol: symbol, size: 28)
            Text(title)
        }
    }
}

/// Choose which data types to sync (moved here from the old sync page).
struct SyncTypesView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: DS.cardSpacing) {
                ForEach(SyncCategory.allCases) { category in
                    CategoryCard(category: category)
                }
            }
            .padding(DS.pagePadding)
        }
        .pageBackground()
        .navigationTitle("מה לסנכרן")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if sync.history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("עדיין אין סנכרונים ביומן")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(sync.history) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            SoftIcon(symbol: entry.trigger.symbol, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .he)))
                                    .font(.body.weight(.semibold))
                                Text("\(entry.trigger.title) · \(entry.rangeTitle) · \(entry.syncedTypes) סוגים · \(entry.records) רשומות")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !entry.failedTypes.isEmpty {
                                    Text("לא סונכרנו: \(entry.failedTypes.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("יומן סנכרונים")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סיום") { dismiss() }
                }
            }
        }
        .appChrome()
    }
}

struct StepsCheckView: View {
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var rows: [SyncCoordinator.StepsDay] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { ProgressView(); Text("בודק…").foregroundStyle(.secondary) }
                } else if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(row.day.formatted(.dateTime.weekday(.wide).day().month().locale(.he)))
                                    .font(.body.weight(.semibold))
                                Spacer()
                                Image(systemName: row.matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(row.matches ? .green : .orange)
                                    .accessibilityLabel(row.matches ? "תואם" : "לא תואם")
                            }
                            HStack(spacing: 8) {
                                StatTile(title: "Google", value: row.google.formatted())
                                StatTile(title: "HealthBridge", value: row.stepsBridge.formatted())
                                StatTile(title: "Apple Health", value: row.appleHealth.formatted())
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("אם רק Apple Health שונה: בריאות ← צעדים ← מקורות נתונים ← העבר את HealthBridge לראש הרשימה.")
                }
            }

            Section {
                Button {
                    Task {
                        await sync.syncNow()
                        await load()
                    }
                } label: {
                    Label("סנכרן ובדוק שוב", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(loading || sync.isSyncing)
            }
        }
        .navigationTitle("בדיקת צעדים")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            rows = try await sync.stepsComparison(days: 7)
        } catch {
            self.error = "הבדיקה נכשלה: \(error.localizedDescription)"
        }
    }
}

