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

/// The day at a glance, like the ring in calorie apps: how much is left to eat to stay on
/// the deficit goal, with eaten / target / burned and the day's macros.
///
/// Target = the day's expected burn − the deficit goal. For a past day the expected burn is
/// what Google measured for the whole day; for today, the average of the last 7 full days
/// (today's own number only covers the hours so far).
struct EnergyCard: View {
    let day: Date
    @EnvironmentObject private var sync: SyncCoordinator
    @ObservedObject private var food = FoodLog.shared
    @AppStorage(AppSettings.deficitGoalKey) private var goal = 500
    @State private var burned: Int?
    @State private var typicalBurn: Int?
    @State private var otherApps = 0
    @State private var loading = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        let entries = food.entries(on: day)
        let eaten = Int(safe: entries.map(\.kcal).reduce(0, +).rounded()) + otherApps
        let expectedBurn = isToday ? (typicalBurn ?? burned) : burned
        let target = expectedBurn.map { max(0, $0 - goal) }

        Card {
            HStack(spacing: 20) {
                ring(eaten: eaten, target: target)
                VStack(alignment: .leading, spacing: 10) {
                    figure("נאכלו", eaten, symbol: "fork.knife")
                    figure("יעד אכילה", target, symbol: "target")
                    figure(isToday ? "נשרפו עד עכשיו" : "נשרפו", burned, symbol: "flame.fill")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                macro("חלבון", entries.map(\.protein).reduce(0, +))
                macro("פחמימות", entries.map(\.carbs).reduce(0, +))
                macro("שומן", entries.map(\.fat).reduce(0, +))
            }

            if let burned {
                let deficit = burned - eaten
                Text(deficit >= 0
                     ? "גרעון \(isToday ? "עד עכשיו" : "ביום הזה"): \(deficit.formatted()) קק\"ל · יעד \(goal.formatted())"
                     : "עודף \(isToday ? "עד עכשיו" : "ביום הזה"): \((-deficit).formatted()) קק\"ל")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !loading {
                Text("אין עדיין נתון של קלוריות שנשרפו מ‑Google ליום הזה.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // Reload after every sync too, not only when the day changes.
        .task(id: "\(day.timeIntervalSince1970)-\(sync.lastSyncDate?.timeIntervalSince1970 ?? 0)") {
            loading = true
            otherApps = Int(safe: (await food.otherAppsDailyKcal(from: day, days: 1)).values.reduce(0, +).rounded())
            burned = await sync.burned(on: day)
            if isToday {
                let today = Calendar.current.startOfDay(for: Date())
                let past = await sync.dailyBurned(days: 8).filter { $0.key < today }.map(\.value)
                typicalBurn = past.isEmpty ? nil : Int(safe: (past.reduce(0, +) / Double(past.count)).rounded())
            }
            loading = false
        }
    }

    /// Ring filled by what was eaten out of the target, with what's left in the middle.
    private func ring(eaten: Int, target: Int?) -> some View {
        let fraction = target.map { $0 > 0 ? min(Double(eaten) / Double($0), 1) : 0 } ?? 0
        let left = target.map { $0 - eaten }
        let over = (left ?? 0) < 0
        return ZStack {
            Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(over ? ChartColors.orange : Theme.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if loading && target == nil {
                    ProgressView()
                } else if let left {
                    Text(abs(left).formatted())
                        .font(.title.bold())
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(over ? "מעל היעד" : "נשארו")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").font(.title.bold())
                }
            }
            .padding(16)
        }
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(left.map { over ? "\(abs($0)) קלוריות מעל היעד" : "נשארו \($0) קלוריות ליעד" } ?? "אין עדיין יעד")
    }

    private func figure(_ title: String, _ value: Int?, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.map { $0.formatted() } ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func macro(_ title: String, _ grams: Double) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(safe: grams.rounded())) ג׳")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: DS.minTap)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
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
