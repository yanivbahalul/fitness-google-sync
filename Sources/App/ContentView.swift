import SwiftUI

/// The app's main tabs (bottom bar).
enum MainTab: String, CaseIterable {
    case today, activity, progress

    var title: String {
        switch self {
        case .today: return "היום"
        case .activity: return "פעילות"
        case .progress: return "התקדמות"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "house.fill"
        case .activity: return "figure.walk"
        case .progress: return "chart.bar.fill"
        }
    }
}

/// Other ways to add food, opened from the scanner.
enum AddMode: String, Identifiable {
    case search, barcode
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var showSettings = false
    @State private var showHistory = false
    @AppStorage("mainTab") private var tab: MainTab = .today
    /// The day shown on the Today tab (never in the future).
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var scanning = false
    @State private var addMode: AddMode?
    @State private var pendingMode: AddMode?

    var body: some View {
        NavigationStack {
            Group {
                if auth.isSignedIn {
                    VStack(spacing: 0) {
                        SyncBanner()
                        switch tab {
                        case .today: NutritionPage(day: $day)
                        case .activity: ActivityPage()
                        case .progress: ProgressPage()
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        BottomBar(tab: $tab) { scanning = true }
                    }
                } else {
                    ScrollView {
                        ConnectCard().padding(DS.pagePadding)
                    }
                }
            }
            .appBackground()
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
            .fullScreenCover(isPresented: $scanning, onDismiss: {
                // Search or barcode chosen inside the scanner opens once it has closed.
                if let mode = pendingMode { pendingMode = nil; addMode = mode }
            }) {
                MealScannerView(day: day) { mode in
                    pendingMode = mode
                    scanning = false
                }
            }
            .sheet(item: $addMode) { mode in
                switch mode {
                case .search: FoodSearchView(day: day)
                case .barcode: BarcodeAddView(day: day)
                }
            }
        }
        .appChrome()
    }
}

/// Floating tab bar with a separate round "+" that opens the meal scanner.
private struct BottomBar: View {
    @Binding var tab: MainTab
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            .accessibilityLabel("הוסף אוכל")
            .accessibilityHint("פותח את סורק הארוחות")

            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol).font(.title3)
                            Text(item.title).font(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        .foregroundStyle(tab == item ? Theme.accent : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(tab == item ? Theme.accent.opacity(0.15) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(tab == item ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
        .padding(.horizontal, DS.pagePadding)
        .padding(.bottom, 6)
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

    @State private var showEaten = false

    var body: some View {
        let entries = food.entries(on: day)
        let eaten = Int(safe: entries.map(\.kcal).reduce(0, +).rounded()) + otherApps
        let expectedBurn = isToday ? (typicalBurn ?? burned) : burned
        let target = expectedBurn.map { max(0, $0 - goal) }
        let left = target.map { $0 - eaten }

        VStack(spacing: 12) {
            // Calories: what's left (tap to see what was eaten instead).
            Button { showEaten.toggle() } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if loading && target == nil {
                            ProgressView()
                        } else {
                            Text(showEaten ? eaten.formatted() : (left.map { abs($0).formatted() } ?? "—"))
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                        }
                        Text(showEaten ? "קלוריות נאכלו" : ((left ?? 0) < 0 ? "קלוריות מעל היעד" : "קלוריות נותרו"))
                            .font(.title3.weight(.semibold))
                        Text("הקש להחלפה")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    ring(eaten: eaten, target: target)
                }
                .padding(DS.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(showEaten
                ? "נאכלו \(eaten) קלוריות"
                : left.map { $0 < 0 ? "\(-$0) קלוריות מעל היעד" : "נותרו \($0) קלוריות" } ?? "אין עדיין יעד")
            .accessibilityHint("הקש כדי להחליף בין נותרו לנאכלו")

            // Macros left, from a 30 / 40 / 30 split of the calorie target.
            HStack(spacing: 10) {
                macro("חלבון", eaten: entries.map(\.protein).reduce(0, +),
                      target: target.map { Double($0) * 0.30 / 4 }, symbol: "fish.fill", color: .pink)
                macro("פחמימות", eaten: entries.map(\.carbs).reduce(0, +),
                      target: target.map { Double($0) * 0.40 / 4 }, symbol: "leaf.fill", color: .orange)
                macro("שומן", eaten: entries.map(\.fat).reduce(0, +),
                      target: target.map { Double($0) * 0.30 / 9 }, symbol: "drop.fill", color: .yellow)
            }

            if let burned {
                let deficit = burned - eaten
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").foregroundStyle(ChartColors.orange)
                    Text("נשרפו \(burned.formatted())\(isToday ? " עד עכשיו" : "") · \(deficit >= 0 ? "גרעון" : "עודף") \(abs(deficit).formatted()) · יעד גרעון \(goal.formatted())")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else if !loading {
                Text("אין עדיין נתון של קלוריות שנשרפו מ‑Google ליום הזה.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Ring filled by what was eaten out of the target, with a flame in the middle.
    private func ring(eaten: Int, target: Int?) -> some View {
        let fraction = target.map { $0 > 0 ? min(Double(eaten) / Double($0), 1) : 0 } ?? 0
        let over = target.map { eaten > $0 } ?? false
        return ZStack {
            Circle().stroke(ChartColors.orange.opacity(0.2), lineWidth: 10)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(over ? Color.red : ChartColors.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "flame.fill")
                .font(.title)
                .foregroundStyle(ChartColors.orange)
        }
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
    }

    private func macro(_ title: String, eaten: Double, target: Double?, symbol: String, color: Color) -> some View {
        let left = target.map { $0 - eaten }
        let fraction = target.map { $0 > 0 ? min(eaten / $0, 1) : 0 } ?? 0
        return VStack(spacing: 8) {
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.subheadline).foregroundStyle(color)
            }
            .frame(width: 48, height: 48)
            Text(left.map { "\(Int(safe: abs($0).rounded()))ג׳" } ?? "\(Int(safe: eaten.rounded()))ג׳")
                .font(.headline)
                .monospacedDigit()
            Text(left.map { $0 < 0 ? "\(title) מעל" : "\(title) נותרו" } ?? title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
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
