import Charts
import PhotosUI
import SwiftUI

/// The Today tab: the week strip, what's left to eat, and today's meals.
struct NutritionPage: View {
    @Binding var day: Date

    var body: some View {
        ScrollView {
            VStack(spacing: DS.cardSpacing) {
                WeekStrip(day: $day)
                EnergyCard(day: day)
                DiaryCard(day: day)
            }
            .padding(.horizontal, DS.pagePadding)
            .padding(.bottom, 24)
        }
    }
}

/// The Progress tab: weight, eaten vs burned, expected vs actual, macros.
struct ProgressPage: View {
    @EnvironmentObject private var sync: SyncCoordinator
    @ObservedObject private var food = FoodLog.shared
    @StateObject private var progress = ProgressModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            ProgressSection(progress: progress)
                .padding(.horizontal, DS.pagePadding)
                .padding(.bottom, 24)
        }
        .task { await progress.refresh(sync: sync, food: food) }
        .refreshable { await progress.refresh(sync: sync, food: food) }
        .onChange(of: food.entries) { _ in Task { await progress.refresh(sync: sync, food: food) } }
        .onChange(of: sync.lastSyncDate) { _ in Task { await progress.refresh(sync: sync, food: food) } }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await progress.refresh(sync: sync, food: food) }
        }
    }
}

/// The last 7 days as tappable pills (today at the start), plus a calendar for earlier days.
private struct WeekStrip: View {
    @Binding var day: Date
    @State private var picking = false
    private let calendar = Calendar.current

    private var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<7).map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button { picking = true } label: {
                    Image(systemName: "calendar")
                        .font(.title3)
                        .frame(width: DS.minTap, height: DS.minTap)
                }
                .accessibilityLabel("בחר תאריך")
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { d in
                    let selected = calendar.isDate(d, inSameDayAs: day)
                    Button { day = d } label: {
                        VStack(spacing: 4) {
                            Text(d.formatted(.dateTime.weekday(.narrow).locale(.he)))
                                .font(.caption.weight(.semibold))
                            Text(d.formatted(.dateTime.day().locale(.he)))
                                .font(.headline)
                                .monospacedDigit()
                            Circle()
                                .fill(FoodLog.shared.entries(on: d).isEmpty ? Color.clear : Theme.accent)
                                .frame(width: 5, height: 5)
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(selected ? Color(.secondarySystemGroupedBackground) : Color(.tertiarySystemFill).opacity(0.5),
                                    in: Capsule())
                        .overlay(Capsule().stroke(selected ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).day().month().locale(.he)))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                DatePicker("תאריך", selection: Binding(
                    get: { day },
                    set: { day = calendar.startOfDay(for: min($0, Date())); picking = false }
                ), in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("בחר יום")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("סגור") { picking = false } } }
            }
            .presentationDetents([.medium])
            .appChrome()
        }
    }

    private var title: String {
        if calendar.isDateInToday(day) { return "היום" }
        if calendar.isDateInYesterday(day) { return "אתמול" }
        return day.formatted(.dateTime.weekday(.wide).day().month().locale(.he))
    }
}

// MARK: - Diary

/// The day's food, grouped by meal like a food diary.
private struct DiaryCard: View {
    let day: Date
    @ObservedObject private var food = FoodLog.shared

    private enum Meal: Int, CaseIterable {
        case breakfast, lunch, dinner
        var title: String {
            switch self {
            case .breakfast: return "בוקר"
            case .lunch: return "צהריים"
            case .dinner: return "ערב"
            }
        }
        static func of(_ date: Date) -> Meal {
            let hour = Calendar.current.component(.hour, from: date)
            if (4..<11).contains(hour) { return .breakfast }
            if (11..<16).contains(hour) { return .lunch }
            return .dinner
        }
    }

    var body: some View {
        let entries = food.entries(on: day)
        let isToday = Calendar.current.isDateInToday(day)
        Card {
            CardHeader(title: isToday ? "הארוחות של היום" : "הארוחות", symbol: "fork.knife") {
                Text("\(Int(safe: entries.map(\.kcal).reduce(0, +)).formatted()) קק\"ל")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                Text(isToday ? "עדיין לא נרשם אוכל היום. הקש על + כדי לצלם ארוחה." : "לא נרשם אוכל ביום הזה.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let groups = Dictionary(grouping: entries, by: { Meal.of($0.date) })
                ForEach(Meal.allCases, id: \.self) { meal in
                    if let items = groups[meal], !items.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(meal.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(Int(safe: items.map(\.kcal).reduce(0, +)).formatted()) קק\"ל")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(items.sorted { $0.date < $1.date }) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
            recents
            if let error = food.lastError {
                Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: error)
            }
        }
    }

    /// Recently eaten foods: one tap logs them again on this day.
    @ViewBuilder private var recents: some View {
        let recent = food.recentFoods(limit: 10)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("הוסף שוב").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recent) { entry in
                            Button {
                                Task {
                                    await food.relog(entry, at: FoodLog.entryDate(for: day))
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.subheadline).lineLimit(1)
                                    Text("\(Int(safe: entry.kcal)) קק\"ל").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: 180, minHeight: 52, alignment: .leading)
                                .background(Color(.tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("הוסף שוב \(entry.name), \(Int(safe: entry.kcal)) קלוריות")
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func row(_ entry: FoodEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.source.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline).lineLimit(2)
                Text([entry.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .he)),
                      entry.grams.map { "\(Int(safe: $0)) ג׳" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(safe: entry.kcal))")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Menu {
                Button {
                    Task { await food.relog(entry, at: FoodLog.entryDate(for: day)) }
                } label: { Label("הוסף שוב", systemImage: "plus.circle") }
                Button(role: .destructive) {
                    Task { await food.delete(entry) }
                } label: { Label("מחק", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.minTap, height: DS.minTap)
            }
            .accessibilityLabel("אפשרויות עבור \(entry.name)")
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Progress

private func kg(_ v: Double, sign: Bool = false) -> String {
    let s = String(format: "%.1f", abs(v))
    guard sign else { return "\(s) ק״ג" }
    return (v < 0 ? "−" : v > 0 ? "+" : "") + "\(s) ק״ג"
}

private func shortDate(_ d: Date) -> String {
    d.formatted(.dateTime.day().month(.wide).locale(.he))
}

private struct ProgressSection: View {
    @ObservedObject var progress: ProgressModel
    @EnvironmentObject private var sync: SyncCoordinator
    @AppStorage("goalWeight") private var goalWeight = 0.0

    var body: some View {
        VStack(spacing: DS.cardSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ההתקדמות שלי")
                    .font(.title2.bold())
                Picker("תקופה", selection: $progress.range) {
                    ForEach(ProgressModel.Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: progress.range) { _ in
                    Task { await progress.refresh(sync: sync, food: FoodLog.shared) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            WeightCard(progress: progress, goalWeight: $goalWeight)
            BalanceCard(progress: progress)
            ExpectedVsActualCard(progress: progress)
            MacrosCard(progress: progress)
        }
    }
}

private struct WeightCard: View {
    @ObservedObject var progress: ProgressModel
    @Binding var goalWeight: Double
    @State private var selected: ProgressModel.WeightPoint?

    /// Draw the goal line only when it's near the weights; a far-away goal would squash
    /// the chart and hide the real change. The goal is always shown in text below.
    private var goalVisible: Bool {
        guard goalWeight > 0, let lo = progress.weights.map(\.kg).min(),
              let hi = progress.weights.map(\.kg).max() else { return false }
        let margin = max(2, (hi - lo) * 0.5)
        return goalWeight >= lo - margin && goalWeight <= hi + margin
    }

    private var headline: (String, String?) {
        guard let change = progress.change, let first = progress.weights.first else {
            return ("עדיין אין שקילות בתקופה הזו", nil)
        }
        let since = "מאז \(shortDate(first.date))"
        if change <= -0.1 { return ("ירדת \(kg(change)) \(since)", nil) }
        if change >= 0.1 { return ("עלית \(kg(change)) \(since)", nil) }
        return ("המשקל יציב \(since)", nil)
    }

    var body: some View {
        Card {
            CardHeader(title: "משקל", symbol: "scalemass.fill")
            Headline(text: headline.0, detail: headline.1)

            if !progress.weights.isEmpty {
                HStack(spacing: 8) {
                    StatTile(title: progress.lastWeighIn.map { "שקילה אחרונה · \(shortDate($0))" } ?? "שקילה אחרונה",
                             value: progress.currentWeight.map { kg($0) } ?? "—")
                    StatTile(title: "קצב בשבוע", value: progress.weeklyRate.map { kg($0, sign: true) } ?? "—")
                }

                Chart {
                    ForEach(progress.weights) { p in
                        PointMark(x: .value("תאריך", p.date), y: .value("משקל", p.kg))
                            .symbolSize(50)
                            .foregroundStyle(ChartColors.blue.opacity(0.35))
                    }
                    ForEach(progress.trend) { p in
                        LineMark(x: .value("תאריך", p.date), y: .value("משקל", p.kg))
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(ChartColors.blue)
                    }
                    if goalVisible {
                        RuleMark(y: .value("יעד", goalWeight))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .foregroundStyle(ChartColors.reference)
                    }
                    if let selected {
                        RuleMark(x: .value("תאריך", selected.date))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .annotation(position: .top) {
                                ValueBubble(title: shortDate(selected.date), value: kg(selected.kg))
                            }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(anchor: .trailing) {
                            if let v = value.as(Double.self) { Text("\(Int(safe: v))").font(.caption) }
                        }
                    }
                }
                .dailyDateAxis(progress.weights.map(\.date))
                .frame(height: 220)
                // Time runs left to right like any chart, even in the right-to-left UI.
                .environment(\.layoutDirection, .leftToRight)
                .chartOverlay { proxy in
                    SelectionOverlay(proxy: proxy) { date in
                        selected = progress.weights.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    } onEnd: { selected = nil }
                }
                .accessibilityElement()
                .accessibilityLabel("גרף משקל")
                .accessibilityValue(headline.0)

                HStack(spacing: 14) {
                    LegendItem(color: ChartColors.blue, text: "מגמה")
                    LegendItem(color: ChartColors.blue.opacity(0.35), text: "שקילה")
                    if goalVisible { LegendItem(color: ChartColors.reference, text: "יעד", dashed: true) }
                }
            }

            Divider()
            HStack {
                Label("משקל יעד", systemImage: "target")
                    .font(.subheadline)
                Spacer()
                Stepper(goalWeight > 0 ? kg(goalWeight) : "לא הוגדר", value: $goalWeight, in: 0...250, step: 0.5)
                    .fixedSize()
            }
            if goalWeight > 0, let current = progress.currentWeight {
                if let weeks = progress.weeksToGoal(goalWeight) {
                    let date = Calendar.current.date(byAdding: .day, value: Int(safe: weeks * 7), to: Date()) ?? Date()
                    Text("נשארו \(kg(current - goalWeight)). בקצב הנוכחי תגיע ליעד בערך ב‑\(date.formatted(.dateTime.month(.wide).year().locale(.he))).")
                        .font(.subheadline)
                } else if current > goalWeight {
                    Text("נשארו \(kg(current - goalWeight)) ליעד.")
                        .font(.subheadline)
                } else {
                    Text("הגעת ליעד").font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

private struct BalanceCard: View {
    @ObservedObject var progress: ProgressModel
    @State private var selected: ProgressModel.DayBalance?

    var body: some View {
        let days = progress.balances
        let logged = days.filter(\.logged)
        let unlogged = days.count - logged.count
        let good = logged.filter { $0.deficit > 0 }.count
        Card {
            CardHeader(title: "אכלתי מול שרפתי", symbol: "flame.fill")
            if days.count < ProgressModel.minDaysForComparison {
                Headline(text: "יוצג אחרי \(ProgressModel.minDaysForComparison) ימים מתחילת המעקב",
                         detail: "עד עכשיו: \(days.count) ימים מלאים, מתוכם \(logged.count) עם רישום אוכל.")
            } else {
                Headline(text: "ב‑\(good) מתוך \(logged.count) ימים שנרשמו אכלת פחות ממה ששרפת",
                         detail: [progress.averageDeficit.map { avg in
                                     avg >= 0 ? "גרעון ממוצע של \(Int(safe: avg).formatted()) קלוריות ביום."
                                              : "עודף ממוצע של \(Int(safe: -avg).formatted()) קלוריות ביום."
                                  },
                                  unlogged > 0 ? "\(unlogged) ימים בלי רישום נספרו כמאוזנים (0)." : nil]
                             .compactMap { $0 }.joined(separator: " "))
                Chart {
                    ForEach(days) { b in
                        if b.logged {
                            BarMark(x: .value("יום", b.day, unit: .day), y: .value("הפרש", b.deficit))
                                .foregroundStyle(b.deficit >= 0 ? ChartColors.blue : ChartColors.orange)
                                .cornerRadius(3)
                        } else {
                            PointMark(x: .value("יום", b.day, unit: .day), y: .value("הפרש", 0))
                                .symbolSize(18)
                                .foregroundStyle(ChartColors.reference.opacity(0.6))
                        }
                    }
                    RuleMark(y: .value("אפס", 0)).foregroundStyle(Color.secondary.opacity(0.6))
                    if let selected {
                        RuleMark(x: .value("יום", selected.day, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .annotation(position: .top) {
                                ValueBubble(title: shortDate(selected.day),
                                            value: selected.logged
                                                ? "שרפת \(Int(safe: selected.burned)) · אכלת \(Int(safe: selected.eaten))"
                                                : "לא נרשם אוכל (נספר כ‑0)")
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(anchor: .trailing) {
                            if let v = value.as(Double.self) { Text("\(Int(safe: v))").font(.caption) }
                        }
                    }
                }
                .dailyDateAxis(days.map(\.day))
                .frame(height: 200)
                // Time runs left to right like any chart, even in the right-to-left UI.
                .environment(\.layoutDirection, .leftToRight)
                .chartOverlay { proxy in
                    SelectionOverlay(proxy: proxy) { date in
                        selected = days.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
                    } onEnd: { selected = nil }
                }
                .accessibilityElement()
                .accessibilityLabel("גרף אכלתי מול שרפתי")
                .accessibilityValue("ב‑\(good) מתוך \(logged.count) ימים שנרשמו אכלת פחות ממה ששרפת")

                HStack(spacing: 14) {
                    LegendItem(color: ChartColors.blue, text: "מעל הקו: אכלת פחות (טוב לירידה)")
                    LegendItem(color: ChartColors.orange, text: "מתחת: אכלת יותר")
                }
                if unlogged > 0 {
                    LegendItem(color: ChartColors.reference.opacity(0.6), text: "נקודה אפורה: יום בלי רישום (0)")
                }
            }
        }
    }
}

private struct ExpectedVsActualCard: View {
    @ObservedObject var progress: ProgressModel

    var body: some View {
        let expected = progress.comparison.filter { $0.series == "צפוי לפי המאזן" }
        let actual = progress.comparison.filter { $0.series == "בפועל" }
        if expected.count < 2 {
            Card {
                CardHeader(title: "צפוי מול בפועל", symbol: "scope")
                Headline(text: "יוצג אחרי \(ProgressModel.minDaysForComparison) ימים מתחילת המעקב",
                         detail: "עד עכשיו: \(progress.balances.count) ימים מלאים. בטווח קצר יותר, תנודות של מים במשקל גדולות מהשינוי האמיתי.")
            }
        } else if let exp = expected.last, let act = actual.last {
            Card {
                CardHeader(title: "צפוי מול בפועל", symbol: "scope")
                Headline(text: "לפי מה שאכלת היית אמור \(exp.kg <= 0 ? "לרדת" : "לעלות") \(kg(exp.kg)). בפועל \(act.kg <= 0 ? "ירדת" : "עלית") \(kg(act.kg)).",
                         detail: "מאז \(shortDate(AppSettings.foodTrackingStart)), לפי השקילות.")
                Chart(progress.comparison) { p in
                    LineMark(x: .value("תאריך", p.day), y: .value("שינוי", p.kg))
                        .foregroundStyle(by: .value("סדרה", p.series))
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(["צפוי לפי המאזן": ChartColors.orange, "בפועל": ChartColors.blue])
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(anchor: .trailing) {
                            if let v = value.as(Double.self) { Text(String(format: "%.0f", v)).font(.caption) }
                        }
                    }
                }
                .dailyDateAxis(progress.comparison.map(\.day))
                .frame(height: 180)
                // Time runs left to right like any chart, even in the right-to-left UI.
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityElement()
                .accessibilityLabel("שינוי משקל צפוי מול בפועל")
                HStack(spacing: 14) {
                    LegendItem(color: ChartColors.blue, text: "בפועל (ק״ג)")
                    LegendItem(color: ChartColors.orange, text: "צפוי לפי האוכל (ק״ג)")
                }
            }
        }
    }
}

private struct MacrosCard: View {
    @ObservedObject var progress: ProgressModel

    var body: some View {
        if let m = progress.macros7 {
            Card {
                CardHeader(title: "מה אכלתי בשבוע האחרון", symbol: "fork.knife")
                Headline(text: "בממוצע \(Int(safe: m.kcal).formatted()) קלוריות ביום")
                HStack(spacing: 8) {
                    StatTile(title: "חלבון ביום", value: "\(Int(safe: m.protein)) ג׳")
                    StatTile(title: "פחמימות ביום", value: "\(Int(safe: m.carbs)) ג׳")
                    StatTile(title: "שומן ביום", value: "\(Int(safe: m.fat)) ג׳")
                }
            }
        }
    }
}
