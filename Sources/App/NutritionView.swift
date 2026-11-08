import Charts
import PhotosUI
import SwiftUI

/// The nutrition screen: today's balance, adding food, today's diary and progress over time.
struct NutritionPage: View {
    @EnvironmentObject private var sync: SyncCoordinator
    @ObservedObject private var food = FoodLog.shared
    @StateObject private var progress = ProgressModel()
    /// The day being viewed/edited (never in the future).
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        ScrollView {
            VStack(spacing: DS.cardSpacing) {
                DayNavigator(day: $day)
                EnergyCard(day: day)
                AddFoodCard(day: day)
                DiaryCard(day: day)
                ProgressSection(progress: progress)
            }
            .padding(.horizontal, DS.pagePadding)
            .padding(.bottom, 24)
        }
        .task { await progress.refresh(sync: sync, food: food) }
        .refreshable { await progress.refresh(sync: sync, food: food) }
        .onChange(of: food.entries) { _ in
            Task { await progress.refresh(sync: sync, food: food) }
        }
    }
}

/// ‹ day › switcher with a date picker. Can't go past today.
private struct DayNavigator: View {
    @Binding var day: Date
    private let calendar = Calendar.current

    private var isToday: Bool { calendar.isDateInToday(day) }

    private var title: String {
        if isToday { return "היום" }
        if calendar.isDateInYesterday(day) { return "אתמול" }
        return day.formatted(.dateTime.weekday(.wide).day().month().locale(.he))
    }

    var body: some View {
        HStack(spacing: 12) {
            // RTL: "previous day" sits on the right, pointing right.
            Button { move(-1) } label: {
                Image(systemName: "chevron.right").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("יום קודם")

            Spacer()
            VStack(spacing: 2) {
                Text(title).font(.headline)
                DatePicker("בחר תאריך", selection: Binding(
                    get: { day },
                    set: { day = calendar.startOfDay(for: min($0, Date())) }
                ), in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
            }
            Spacer()

            Button { move(1) } label: {
                Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44)
            }
            .disabled(isToday)
            .accessibilityLabel("יום הבא")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottom) {
            if !isToday {
                Button("חזרה להיום") { day = calendar.startOfDay(for: Date()) }
                    .font(.caption.weight(.semibold))
                    .offset(y: 18)
            }
        }
        .padding(.bottom, isToday ? 0 : 14)
    }

    private func move(_ delta: Int) {
        guard let next = calendar.date(byAdding: .day, value: delta, to: day),
              next <= calendar.startOfDay(for: Date()) else { return }
        day = next
    }
}

// MARK: - Add food

private enum AddMode: String, Identifiable {
    case photo, text, search, barcode
    var id: String { rawValue }
}

private struct AddFoodCard: View {
    let day: Date
    @State private var mode: AddMode?
    @State private var quickAdd = false
    @State private var quickText = ""

    var body: some View {
        Card {
            CardHeader(title: Calendar.current.isDateInToday(day) ? "הוסף אוכל" : "הוסף אוכל ל‑\(day.formatted(.dateTime.day().month().locale(.he)))",
                       symbol: "plus")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                AddButton(title: "צילום", symbol: "camera.fill") { mode = .photo }
                AddButton(title: "תיאור", symbol: "text.bubble.fill") { mode = .text }
                AddButton(title: "חיפוש", symbol: "magnifyingglass") { mode = .search }
                AddButton(title: "ברקוד", symbol: "barcode.viewfinder") { mode = .barcode }
                AddButton(title: "מהיר", symbol: "bolt.fill") { quickText = ""; quickAdd = true }
            }
        }
        .sheet(item: $mode) { mode in
            switch mode {
            case .photo: PhotoAnalyzeView(day: day)
            case .text: TextAnalyzeView(day: day)
            case .search: FoodSearchView(day: day)
            case .barcode: BarcodeAddView(day: day)
            }
        }
        .alert("הזנה מהירה", isPresented: $quickAdd) {
            TextField("קלוריות", text: $quickText).keyboardType(.numberPad)
            Button("הוסף") {
                if let kcal = Double(quickText.filter(\.isNumber)), kcal > 0 {
                    Task { await FoodLog.shared.addQuick(kcal: kcal, at: FoodLog.entryDate(for: day)) }
                }
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text(Calendar.current.isDateInToday(day) ? "כמה קלוריות להוסיף ליומן של היום?" : "כמה קלוריות להוסיף ליומן של \(day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: .he)))?")
        }
    }
}

private struct AddButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                SoftIcon(symbol: symbol, size: 44)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("הוסף אוכל: \(title)")
    }
}

// MARK: - Today's diary

private struct DiaryCard: View {
    let day: Date
    @ObservedObject private var food = FoodLog.shared

    var body: some View {
        let entries = food.entries(on: day)
        let isToday = Calendar.current.isDateInToday(day)
        Card {
            CardHeader(title: isToday ? "יומן היום" : "יומן", symbol: "list.bullet") {
                Text("\(Int(safe: entries.map(\.kcal).reduce(0, +)).formatted()) קק\"ל")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                Text(isToday ? "עדיין לא נרשם אוכל היום." : "לא נרשם אוכל ביום הזה.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
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
                            Button("מחק", role: .destructive) { Task { await food.delete(entry) } }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("אפשרויות עבור \(entry.name)")
                    }
                    .frame(minHeight: 40)
                }
            }
            if let error = food.lastError {
                Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: error)
            }
        }
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
                    StatTile(title: "המשקל עכשיו", value: progress.currentWeight.map { kg($0) } ?? "—")
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
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(Int(safe: v))").font(.caption) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(.he)).font(.caption)
                    }
                }
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
        let good = days.filter { $0.deficit > 0 }.count
        Card {
            CardHeader(title: "אכלתי מול שרפתי", symbol: "flame.fill")
            if days.isEmpty {
                Headline(text: "עוד אין מספיק נתונים")
            } else {
                Headline(text: "ב‑\(good) מתוך \(days.count) ימים אכלת פחות ממה ששרפת",
                         detail: progress.averageDeficit.map { avg in
                             avg >= 0 ? "בממוצע אכלת \(Int(safe: avg).formatted()) קלוריות פחות ממה ששרפת ביום."
                                      : "בממוצע אכלת \(Int(safe: -avg).formatted()) קלוריות יותר ממה ששרפת ביום."
                         })
                Chart {
                    ForEach(days) { b in
                        BarMark(x: .value("יום", b.day, unit: .day), y: .value("הפרש", b.deficit))
                            .foregroundStyle(b.deficit >= 0 ? ChartColors.blue : ChartColors.orange)
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("אפס", 0)).foregroundStyle(Color.secondary.opacity(0.6))
                    if let selected {
                        RuleMark(x: .value("יום", selected.day, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .annotation(position: .top) {
                                ValueBubble(title: shortDate(selected.day),
                                        value: "שרפת \(Int(safe: selected.burned)) · אכלת \(Int(safe: selected.eaten))")
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(Int(safe: v))").font(.caption) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(.he)).font(.caption)
                    }
                }
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
                .accessibilityValue("ב‑\(good) מתוך \(days.count) ימים אכלת פחות ממה ששרפת")

                HStack(spacing: 14) {
                    LegendItem(color: ChartColors.blue, text: "מעל הקו: אכלת פחות (טוב לירידה)")
                    LegendItem(color: ChartColors.orange, text: "מתחת: אכלת יותר")
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
                Headline(text: "יוצג אחרי \(ProgressModel.minDaysForComparison) ימים מלאים של רישום",
                         detail: "עד עכשיו: \(progress.balances.count) ימים. בטווח קצר יותר, תנודות של מים במשקל גדולות מהשינוי האמיתי.")
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
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(String(format: "%.0f", v)).font(.caption) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(.he)).font(.caption)
                    }
                }
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
