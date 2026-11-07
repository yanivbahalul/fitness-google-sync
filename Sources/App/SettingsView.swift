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
    @AppStorage("overlapNoticeDismissed") private var overlapNoticeDismissed = false

    private let expiry = Notifier.signingExpiry

    var body: some View {
        NavigationStack {
            Form {
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
                } footer: {
                    Text("סנכרון ברקע הוא \"כמיטב היכולת\": iOS מחליט מתי להריץ אותו, בדרך כלל כמה פעמים ביום. הדרך האמינה ביותר לסנכרון יומי היא אוטומציה בקיצורים (למטה).")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingLabel("סנכרון יומי בשעה קבועה", symbol: "square.stack.3d.up.fill", color: .pink)
                        Text("בקיצורים ← אוטומציה ← + ← שעה ביום (למשל 08:00) ← הפעל מיד ← הוסף את הפעולה \"סנכרן את StepsBridge\".")
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
                } footer: {
                    Text("עם Apple ID חינמי האפליקציה פגה 7 ימים אחרי ההתקנה. תקבל התראה יום לפני, ואז מחברים את האייפון ל‑Mac ולוחצים ▶️ ב‑Xcode.")
                }

                Section {
                    Text("אפליקציית Google Health יכולה לכתוב בעצמה ל‑Apple Health צעדים, דופק, דופק במנוחה, שינה ואימונים. אם החיבור הזה פעיל אצלך, השאר אותם כבויים כאן.")
                        .font(.footnote)
                    Button("כבה את הסוגים הכפולים") { sync.disableOverlapping() }
                        .disabled(sync.enabledOverlapCount == 0)
                    if overlapNoticeDismissed {
                        Button("הצג שוב את ההודעה במסך הראשי") { overlapNoticeDismissed = false }
                    }
                } header: {
                    Text("כפילויות")
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
                    Text("הנתונים עוברים ישירות מ‑Google Health אל Apple Health באייפון. אין שרת, ושום מידע לא נשמר או נשלח לשום מקום אחר.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("פרטיות")
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
