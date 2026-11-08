import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var showSettings = false
    @State private var showHistory = false
    /// 0 = activity, 1 = nutrition. Swipe sideways or tap the switcher.
    @AppStorage("mainPage") private var page = 0

    var body: some View {
        NavigationStack {
            Group {
                if auth.isSignedIn {
                    VStack(spacing: 0) {
                        Picker("מסך", selection: $page) {
                            Label("פעילות", systemImage: "figure.walk").tag(0)
                            Label("תזונה", systemImage: "fork.knife").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, DS.pagePadding)
                        .padding(.vertical, 8)

                        SyncBanner()

                        TabView(selection: $page) {
                            ActivityPage().tag(0)
                            NutritionPage().tag(1)
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                } else {
                    ScrollView {
                        ConnectCard().padding(DS.pagePadding)
                    }
                }
            }
            .pageBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("הגדרות")
                }
                ToolbarItem(placement: .principal) {
                    if auth.isSignedIn {
                        SyncButton()
                    } else {
                        Text("HealthBridge").font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("יומן סנכרונים")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) { HistoryView() }
        }
        .appChrome()
    }
}

/// Compact "Sync now" button in the navigation bar; shows progress while syncing.
private struct SyncButton: View {
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        Button {
            Task { await sync.syncNow() }
        } label: {
            HStack(spacing: 6) {
                if sync.isSyncing {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("\(Int(safe: sync.progress * 100))%").monospacedDigit()
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("סנכרן עכשיו")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(sync.isSyncing || sync.enabledCount == 0)
        .accessibilityLabel(sync.isSyncing ? "מסנכרן" : "סנכרן עכשיו")
        .accessibilityValue(sync.isSyncing
            ? "\(Int(safe: sync.progress * 100)) אחוז"
            : sync.lastSyncDate.map { "סנכרון אחרון \($0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .he)))" } ?? "")
    }
}

/// Sync problems, shown under the page switcher only when there is one.
private struct SyncBanner: View {
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        VStack(spacing: 8) {
            if sync.needsReconnect {
                Notice(symbol: "key.fill", color: .orange,
                       text: "חסרה הרשאה לחלק מהנתונים. בהגדרות: התנתק, התחבר מחדש ואשר את כל ההרשאות.")
            }
            if let error = sync.lastError {
                Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: error)
            }
        }
        .padding(.horizontal, DS.pagePadding)
    }
}

// MARK: - Connect

private struct ConnectCard: View {
    @EnvironmentObject private var auth: GoogleAuthManager

    var body: some View {
        Card {
            CardHeader(title: "חיבור ל‑Google Health", symbol: "person.crop.circle.badge.checkmark")
            Text("כדי להתחיל, התחבר לחשבון Google שאליו הצמיד מסונכרן.")
                .font(.body)
            PrimaryButton(title: "התחבר ל‑Google Health") {
                Task { await auth.signIn() }
            }
            if let error = auth.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Calorie balance

struct EnergyCard: View {
    let day: Date
    @EnvironmentObject private var sync: SyncCoordinator
    @ObservedObject private var food = FoodLog.shared
    @AppStorage(AppSettings.deficitGoalKey) private var goal = 500
    @State private var burned: Int?
    @State private var otherApps = 0
    @State private var loadingBurned = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        let eaten = Int(safe: food.total(on: day).rounded()) + otherApps
        Card {
            CardHeader(title: isToday ? "מאזן קלורי היום" : "מאזן קלורי", symbol: "chart.bar.xaxis") {
                if loadingBurned { ProgressView() }
            }

            HStack(spacing: 8) {
                StatTile(title: isToday ? "נשרפו עד עכשיו (קק\"ל)" : "נשרפו (קק\"ל)",
                         value: burned.map { $0.formatted() } ?? "—", symbol: "flame.fill")
                StatTile(title: otherApps > 0 ? "נאכלו, כולל Cali (קק\"ל)" : "נאכלו (קק\"ל)",
                         value: eaten.formatted(), symbol: "fork.knife")
            }

            if let burned {
                let deficit = burned - eaten
                let reached = deficit >= goal
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(deficit >= 0 ? "גרעון" : "עודף")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(abs(deficit).formatted()) קק\"ל")
                            .font(.title2.bold())
                            .monospacedDigit()
                    }
                    ProgressView(value: Double(max(0, min(deficit, goal))), total: Double(max(goal, 1)))
                        .tint(Theme.accent)
                    Text(reached
                         ? "הגעת ליעד הגרעון היומי (\(goal.formatted()) קק\"ל)"
                         : "יעד: \(goal.formatted()) קק\"ל גרעון · נשארו \(max(0, goal - deficit).formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if !loadingBurned {
                Text("אין נתון של קלוריות שנשרפו ביום הזה מ‑Google.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: day) {
            loadingBurned = true
            otherApps = Int(safe: (await food.otherAppsDailyKcal(from: day, days: 1)).values.reduce(0, +).rounded())
            burned = await sync.burned(on: day)
            loadingBurned = false
        }
    }
}

// MARK: - Categories

struct CategoryCard: View {
    @EnvironmentObject private var sync: SyncCoordinator
    let category: SyncCategory

    var body: some View {
        let items = sync.items(in: category)
        let onCount = items.filter(sync.isEnabled).count

        Card {
            Toggle(isOn: Binding(
                get: { sync.allEnabled(in: category) },
                set: { sync.setAll(in: category, $0) }
            )) {
                HStack(spacing: 12) {
                    SoftIcon(symbol: category.symbol, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.headline)
                        Text("\(onCount) מתוך \(items.count) פעילים")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityLabel("\(category.title), הכול")
            .accessibilityValue("\(onCount) מתוך \(items.count) פעילים")

            if items.count > 1 || items.first?.name != category.title {
                Divider()
                ForEach(items) { item in
                    ItemRow(item: item)
                }
            } else if let item = items.first, let status = sync.status(for: item) {
                HStack { StatusIcon(status: status); Text(status.text).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .disabled(sync.isSyncing)
    }
}

private struct ItemRow: View {
    @EnvironmentObject private var sync: SyncCoordinator
    let item: SyncItem

    var body: some View {
        Toggle(isOn: Binding(
            get: { sync.isEnabled(item) },
            set: { sync.setEnabled(item, $0) }
        )) {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(item.name)
                    .font(.body)
                Spacer(minLength: 4)
                StatusIcon(status: sync.status(for: item))
            }
        }
        .frame(minHeight: 44)
    }
}

extension ItemStatus {
    var text: String {
        switch self {
        case .synced(let count): return "סונכרן · \(count) רשומות"
        case .failed(let message): return message
        }
    }
}

private struct StatusIcon: View {
    let status: ItemStatus?

    var body: some View {
        switch status {
        case .synced(let count):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("סונכרן, \(count) רשומות")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("לא סונכרן: \(message)")
        case nil:
            EmptyView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.auth)
        .environmentObject(AppState.sync)
}
