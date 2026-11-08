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
    @AppStorage(MealModel.settingsKey) private var mealModel = MealModel.opus.rawValue
    @State private var apiKey = AnthropicKeyStore.key ?? ""
    @State private var keySaved = AnthropicKeyStore.key != nil

    private let expiry = Notifier.signingExpiry

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        StepsCheckView()
                    } label: {
                        SettingLabel("בדיקת צעדים מול Google", symbol: "checkmark.shield.fill", color: .green)
                    }
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
                        Label("מפתח שמור במכשיר", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Picker("מודל", selection: $mealModel) {
                        ForEach(MealModel.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Link(destination: URL(string: "https://console.anthropic.com/settings/keys")!) {
                        Label("יצירת מפתח ב‑console.anthropic.com", systemImage: "key.fill")
                    }
                } header: {
                    Text("ניתוח ארוחות (Claude)")
                }

                Section {
                    Stepper(value: $deficitGoal, in: 0...2000, step: 50) {
                        HStack {
                            SettingLabel("יעד גרעון יומי", symbol: "target", color: .green)
                            Spacer()
                            Text("\(deficitGoal.formatted()) קק\"ל")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("מאזן קלורי")
                }

                Section {
                    Toggle(isOn: $autoSyncOnOpen) {
                        SettingLabel("סנכרון בפתיחת האפליקציה", symbol: "iphone", color: .blue)
                    }
                    Toggle(isOn: $backgroundSync) {
                        SettingLabel("סנכרון ברקע", symbol: "moon.zzz.fill", color: .indigo)
                    }
                    .onChange(of: backgroundSync) { _ in BackgroundSync.schedule() }
                } header: {
                    Text("סנכרון אוטומטי")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingLabel("סנכרון יומי בשעה קבועה", symbol: "square.stack.3d.up.fill", color: .pink)
                        Text("קיצורים ← אוטומציה ← שעה ביום ← \"סנכרן את HealthBridge\"")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if #available(iOS 16.4, *) {
                        ShortcutsLink()
                            .shortcutsLinkStyle(.automaticOutline)
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("קיצורים")
                }

                Section {
                    Toggle(isOn: $notifyProblems) {
                        SettingLabel("התראה כשסנכרון אוטומטי נכשל", symbol: "bell.badge.fill", color: .red)
                    }
                    Toggle(isOn: $expiryReminder) {
                        SettingLabel("תזכורת לחידוש ב‑Xcode", symbol: "hammer.fill", color: .orange)
                    }
                    .onChange(of: expiryReminder) { on in Notifier.scheduleExpiryReminders(enabled: on) }
                    if let expiry {
                        LabeledContent("האפליקציה בתוקף עד", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("התראות")
                }

                Section {
                    LabeledContent("חשבון", value: auth.isSignedIn ? "מחובר" : "לא מחובר")
                    if auth.isSignedIn {
                        Button(role: .destructive) {
                            auth.signOut()
                        } label: {
                            Label("התנתק מ‑Google", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } header: {
                    Text("חשבון Google")
                }

                Section {
                    Link(destination: URL(string: "https://yanivbahalul.github.io/fitness-google-sync/privacy.html")!) {
                        Label("מדיניות פרטיות", systemImage: "hand.raised.fill")
                    }
                    Text("נתוני הבריאות עוברים ישירות מ‑Google Health אל Apple Health באייפון, בלי שרת. רק צילום או תיאור של ארוחה שאתה בוחר לנתח נשלח ל‑Claude (Anthropic), וברקוד נשלח ל‑Open Food Facts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("פרטיות")
                } footer: {
                    Text("ערכי המזון: מאגר התזונה הלאומי הישראלי (צמרת), משרד הבריאות, data.gov.il. מוצרים ארוזים: Open Food Facts.")
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
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct SettingLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 28)
            Text(title)
        }
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
                            IconBadge(symbol: entry.trigger.symbol,
                                      color: entry.failedTypes.isEmpty ? .green : (entry.syncedTypes == 0 ? .red : .orange),
                                      size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
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
        .environment(\.layoutDirection, .rightToLeft)
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
                                Text(row.day.formatted(.dateTime.weekday(.wide).day().month()))
                                    .font(.body.weight(.semibold))
                                Spacer()
                                Image(systemName: row.matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(row.matches ? .green : .orange)
                                    .accessibilityLabel(row.matches ? "תואם" : "לא תואם")
                            }
                            HStack(spacing: 8) {
                                NumberTile(title: "Google", value: row.google, color: Theme.blue)
                                NumberTile(title: "HealthBridge", value: row.stepsBridge, color: row.matches ? .green : .orange)
                                NumberTile(title: "Apple Health", value: row.appleHealth, color: Theme.pink)
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

private struct NumberTile: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
