import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @State private var showSettings = false
    @State private var showHistory = false
    /// 0 = sync, 1 = nutrition. Swipe sideways or tap the picker to switch.
    @AppStorage("selectedPage") private var page = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("מסך", selection: $page) {
                    Label("סנכרון", systemImage: "arrow.triangle.2.circlepath").tag(0)
                    Label("תזונה", systemImage: "fork.knife").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                TabView(selection: $page) {
                    SyncPage().tag(0)
                    NutritionPage().tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("HealthBridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("הגדרות")
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
        .environment(\.layoutDirection, .rightToLeft)
    }
}

/// The sync screen: account, sync button and the data types to sync.
private struct SyncPage: View {
    @EnvironmentObject private var auth: GoogleAuthManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeaderCard()
                if auth.isSignedIn {
                    SyncCard()
                    ForEach(SyncCategory.allCases) { category in
                        CategoryCard(category: category)
                    }
                } else {
                    ConnectCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Theme

extension SyncCategory {
    var color: Color {
        switch self {
        case .activity: return .orange
        case .heart: return .red
        case .sleep: return .indigo
        case .body: return .purple
        case .nutrition: return .teal
        }
    }
}

enum Theme {
    /// Same blue → pink as the app icon (Google Health half → Apple Health half).
    static let blue = Color(red: 0.20, green: 0.52, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.30, blue: 0.42)
    static let gradient = LinearGradient(colors: [blue, pink], startPoint: .leading, endPoint: .trailing)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// SF Symbol on a tinted rounded square, like the Health app.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct Notice: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Header

private struct HeaderCard: View {
    @EnvironmentObject private var auth: GoogleAuthManager

    var body: some View {
        HStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("HealthBridge")
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Text("Google Health")
                    Image(systemName: "arrow.left").accessibilityHidden(true)
                    Text("Apple Health")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("מעביר נתונים מ‑Google Health אל Apple Health")
                StatusPill(connected: auth.isSignedIn)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusPill: View {
    let connected: Bool

    var body: some View {
        Label(connected ? "מחובר ל‑Google" : "לא מחובר", systemImage: connected ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(connected ? .green : .secondary)
            .background((connected ? Color.green : Color.gray).opacity(0.15), in: Capsule())
    }
}

// MARK: - Connect

private struct ConnectCard: View {
    @EnvironmentObject private var auth: GoogleAuthManager

    var body: some View {
        Card {
            Text("כדי להתחיל, התחבר לחשבון Google שאליו הצמיד מסונכרן.")
                .font(.body)
            Button {
                Task { await auth.signIn() }
            } label: {
                Label("התחבר ל‑Google Health", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            if let error = auth.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Sync

private struct SyncCard: View {
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        Card {
            Button {
                Task { await sync.syncNow() }
            } label: {
                VStack(spacing: 6) {
                    if sync.isSyncing {
                        ProgressView(value: sync.progress)
                            .tint(.white)
                            .padding(.horizontal, 24)
                        Text("מסנכרן… \(Int(sync.progress * 100))%")
                            .font(.headline)
                    } else {
                        Label("סנכרן עכשיו", systemImage: "arrow.triangle.2.circlepath")
                            .font(.title3.bold())
                        Text("\(sync.enabledCount) סוגי נתונים · \(sync.range.title)")
                            .font(.subheadline)
                            .opacity(0.9)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 88)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .opacity(sync.enabledCount == 0 ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(sync.isSyncing || sync.enabledCount == 0)
            .accessibilityLabel(sync.isSyncing ? "מסנכרן, \(Int(sync.progress * 100)) אחוז" : "סנכרן עכשיו, \(sync.enabledCount) סוגי נתונים")

            HStack {
                if let date = sync.lastSyncDate {
                    Label {
                        Text("הושלם: \(date.formatted(date: .abbreviated, time: .shortened))")
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    .font(.subheadline)
                } else {
                    Text("עדיין לא סונכרן").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                    Picker("טווח סנכרון", selection: $sync.range) {
                        ForEach(SyncRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                } label: {
                    Label(sync.range.title, systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .accessibilityLabel("טווח סנכרון: \(sync.range.title)")
                .disabled(sync.isSyncing)
            }

            Text(sync.range == .automatic
                 ? "אוטומטי: משלים כל סוג נתונים מאז הסנכרון האחרון שלו (אתמול והיום כשמסנכרנים כל יום, עד 14 יום)."
                 : "מסנכרן מחדש את \(sync.range.title) האחרונים, בלי כפילויות.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if sync.needsReconnect {
                Notice(symbol: "key.fill", color: .orange,
                       text: "חסרה הרשאה לחלק מהנתונים. בהגדרות: התנתק, התחבר מחדש ואשר את כל ההרשאות.")
            }
            if let error = sync.lastError {
                Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: error)
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
        let eaten = Int(food.total(on: day).rounded()) + otherApps
        Card {
            HStack {
                Label(isToday ? "מאזן קלורי היום" : "מאזן קלורי", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                if loadingBurned { ProgressView() }
            }

            HStack(spacing: 10) {
                EnergyTile(title: isToday ? "נשרפו עד עכשיו" : "נשרפו", value: burned, symbol: "flame.fill", color: .orange)
                EnergyTile(title: otherApps > 0 ? "נאכלו (כולל Cali)" : "נאכלו", value: eaten, symbol: "fork.knife", color: .teal)
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
                        .tint(reached ? .green : Theme.blue)
                    Text(reached
                         ? "הגעת ליעד הגרעון היומי (\(goal.formatted()) קק\"ל) 🎉"
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
            otherApps = Int((await food.otherAppsDailyKcal(from: day, days: 1)).values.reduce(0, +).rounded())
            burned = await sync.burned(on: day)
            loadingBurned = false
        }
    }
}

private struct EnergyTile: View {
    let title: String
    let value: Int?
    let symbol: String
    let color: Color
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Spacer()
                if let badge {
                    Image(systemName: badge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            Text(value.map { $0.formatted() } ?? "—")
                .font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(title) (קק\"ל)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Categories

private struct CategoryCard: View {
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
                    IconBadge(symbol: category.symbol, color: category.color, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.headline)
                        Text("\(onCount) מתוך \(items.count) פעילים")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(category.color)
            .accessibilityLabel("\(category.title), הכול")
            .accessibilityValue("\(onCount) מתוך \(items.count) פעילים")

            if items.count > 1 || items.first?.name != category.title {
                Divider()
                ForEach(items) { item in
                    ItemRow(item: item, color: category.color)
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
    let color: Color

    var body: some View {
        Toggle(isOn: Binding(
            get: { sync.isEnabled(item) },
            set: { sync.setEnabled(item, $0) }
        )) {
            HStack(spacing: 12) {
                IconBadge(symbol: item.symbol, color: color.opacity(0.85), size: 30)
                Text(item.name)
                    .font(.body)
                Spacer(minLength: 4)
                StatusIcon(status: sync.status(for: item))
            }
        }
        .tint(color)
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
