import Charts
import PhotosUI
import SwiftUI

/// Chart colors: the validated reference categorical pair (blue / orange), stepped
/// separately for light and dark mode.
enum ChartColors {
    static let blue = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255, alpha: 1)
        : UIColor(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255, alpha: 1) })
    static let orange = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255, alpha: 1)
        : UIColor(red: 0xEB / 255, green: 0x68 / 255, blue: 0x34 / 255, alpha: 1) })
}

/// The nutrition screen: today's balance, adding food, today's diary and progress over time.
struct NutritionPage: View {
    @EnvironmentObject private var sync: SyncCoordinator
    @ObservedObject private var food = FoodLog.shared
    @StateObject private var progress = ProgressModel()
    /// The day being viewed/edited (never in the future).
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DayNavigator(day: $day)
                EnergyCard(day: day)
                AddFoodCard(day: day)
                DiaryCard(day: day)
                ProgressSection(progress: progress)
            }
            .padding(.horizontal, 16)
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
        return day.formatted(.dateTime.weekday(.wide).day().month())
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
            Label(Calendar.current.isDateInToday(day) ? "הוסף אוכל" : "הוסף אוכל ל‑\(day.formatted(.dateTime.day().month()))",
                  systemImage: "plus.circle.fill")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                AddButton(title: "צילום", symbol: "camera.fill", color: Theme.blue) { mode = .photo }
                AddButton(title: "תיאור", symbol: "text.bubble.fill", color: .purple) { mode = .text }
                AddButton(title: "חיפוש", symbol: "magnifyingglass", color: .teal) { mode = .search }
                AddButton(title: "ברקוד", symbol: "barcode.viewfinder", color: .indigo) { mode = .barcode }
                AddButton(title: "מהיר", symbol: "bolt.fill", color: .orange) { quickText = ""; quickAdd = true }
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
            Text(Calendar.current.isDateInToday(day) ? "כמה קלוריות להוסיף ליומן של היום?" : "כמה קלוריות להוסיף ליומן של \(day.formatted(date: .abbreviated, time: .omitted))?")
        }
    }
}

private struct AddButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            HStack {
                Label(isToday ? "יומן היום" : "יומן", systemImage: "list.bullet.rectangle.fill")
                    .font(.headline)
                Spacer()
                Text("\(Int(entries.map(\.kcal).reduce(0, +)).formatted()) קק\"ל")
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
                            Text([entry.date.formatted(date: .omitted, time: .shortened),
                                  entry.grams.map { "\(Int($0)) ג׳" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(entry.kcal))")
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
    d.formatted(.dateTime.day().month(.wide))
}

private struct ProgressSection: View {
    @ObservedObject var progress: ProgressModel
    @EnvironmentObject private var sync: SyncCoordinator
    @AppStorage("goalWeight") private var goalWeight = 0.0

    var body: some View {
        VStack(spacing: 16) {
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

/// Big, plain-language headline at the top of each chart card.
private struct Headline: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small colored dot + label, for a legend written in words.
private struct LegendItem: View {
    let color: Color
    let text: String
    var dashed = false

    var body: some View {
        HStack(spacing: 6) {
            if dashed {
                Capsule().stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(width: 16, height: 2)
            } else {
                Circle().fill(color).frame(width: 10, height: 10)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct WeightCard: View {
    @ObservedObject var progress: ProgressModel
    @Binding var goalWeight: Double
    @State private var selected: ProgressModel.WeightPoint?

    private var headline: (String, String?) {
        guard let change = progress.change, let first = progress.weights.first else {
            return ("עדיין אין שקילות בתקופה הזו", "שקילות מגיעות מהסנכרון עם Google.")
        }
        let since = "מאז \(shortDate(first.date))"
        if change <= -0.1 { return ("ירדת \(kg(change)) \(since) 🎉", nil) }
        if change >= 0.1 { return ("עלית \(kg(change)) \(since)", nil) }
        return ("המשקל יציב \(since)", nil)
    }

    var body: some View {
        Card {
            Label("משקל", systemImage: "scalemass.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
                    if goalWeight > 0 {
                        RuleMark(y: .value("יעד", goalWeight))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .foregroundStyle(Color.green)
                    }
                    if let selected {
                        RuleMark(x: .value("תאריך", selected.date))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .annotation(position: .top) {
                                Tooltip(title: shortDate(selected.date), value: kg(selected.kg))
                            }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(Int(v))").font(.caption) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption)
                    }
                }
                .frame(height: 220)
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
                    if goalWeight > 0 { LegendItem(color: .green, text: "יעד", dashed: true) }
                }
                Text("הקו מראה את המגמה (ממוצע של השבוע), כדי שתנודות יומיות לא יבלבלו. לחץ על הגרף לראות שקילה.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    let date = Calendar.current.date(byAdding: .day, value: Int(weeks * 7), to: Date()) ?? Date()
                    Text("נשארו \(kg(current - goalWeight)). בקצב הנוכחי תגיע ליעד בערך ב‑\(date.formatted(.dateTime.month(.wide).year())).")
                        .font(.subheadline)
                } else if current > goalWeight {
                    Text("נשארו \(kg(current - goalWeight)) ליעד.")
                        .font(.subheadline)
                } else {
                    Text("הגעת ליעד! 🎉").font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

/// Drag/tap on a chart to pick the nearest date.
private struct SelectionOverlay: View {
    let proxy: ChartProxy
    let onSelect: (Date) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = geo[proxy.plotAreaFrame].origin
                        if let date: Date = proxy.value(atX: value.location.x - origin.x) { onSelect(date) }
                    }
                    .onEnded { _ in onEnd() })
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct Tooltip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BalanceCard: View {
    @ObservedObject var progress: ProgressModel
    @State private var selected: ProgressModel.DayBalance?

    var body: some View {
        let days = progress.balances
        let good = days.filter { $0.deficit > 0 }.count
        Card {
            Label("אכלתי מול שרפתי", systemImage: "flame.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if days.isEmpty {
                Headline(text: "עוד אין מספיק נתונים",
                         detail: "צריך ימים עם אוכל ביומן ונתון שריפה מהצמיד (Google שומר עד כ‑90 יום אחורה).")
            } else {
                Headline(text: "ב‑\(good) מתוך \(days.count) ימים אכלת פחות ממה ששרפת",
                         detail: progress.averageDeficit.map { avg in
                             avg >= 0 ? "בממוצע אכלת \(Int(avg).formatted()) קלוריות פחות ממה ששרפת ביום."
                                      : "בממוצע אכלת \(Int(-avg).formatted()) קלוריות יותר ממה ששרפת ביום."
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
                                Tooltip(title: shortDate(selected.day),
                                        value: "שרפת \(Int(selected.burned)) · אכלת \(Int(selected.eaten))")
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(Int(v))").font(.caption) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption)
                    }
                }
                .frame(height: 200)
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
                Text("כל עמודה היא יום. לחץ על עמודה כדי לראות כמה אכלת וכמה שרפת.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExpectedVsActualCard: View {
    @ObservedObject var progress: ProgressModel

    var body: some View {
        let expected = progress.comparison.filter { $0.series == "צפוי לפי המאזן" }
        let actual = progress.comparison.filter { $0.series == "בפועל" }
        if let exp = expected.last, let act = actual.last {
            Card {
                Label("צפוי מול בפועל", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Headline(text: "לפי מה שאכלת היית אמור \(exp.kg <= 0 ? "לרדת" : "לעלות") \(kg(exp.kg)). בפועל \(act.kg <= 0 ? "ירדת" : "עלית") \(kg(act.kg)).",
                         detail: explanation(expected: exp.kg, actual: act.kg))
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
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption)
                    }
                }
                .frame(height: 180)
                .accessibilityElement()
                .accessibilityLabel("שינוי משקל צפוי מול בפועל")
                HStack(spacing: 14) {
                    LegendItem(color: ChartColors.blue, text: "בפועל (ק״ג)")
                    LegendItem(color: ChartColors.orange, text: "צפוי לפי האוכל (ק״ג)")
                }
            }
        }
    }

    private func explanation(expected: Double, actual: Double) -> String {
        let gap = actual - expected
        if abs(gap) < 0.8 { return "זה מתאים יפה: היומן משקף טוב את מה שקורה. 👍" }
        if gap > 0 { return "ירדת פחות מהצפוי. אולי חלק מהאוכל לא נרשם, או שהצמיד מעריך שריפה גבוהה מדי." }
        return "ירדת יותר מהצפוי. אולי נרשם יותר אוכל ממה שנאכל בפועל, או שהגוף איבד גם מים."
    }
}

private struct MacrosCard: View {
    @ObservedObject var progress: ProgressModel

    var body: some View {
        if let m = progress.macros7 {
            Card {
                Label("מה אכלתי בשבוע האחרון", systemImage: "fork.knife")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Headline(text: "בממוצע \(Int(m.kcal).formatted()) קלוריות ביום")
                HStack(spacing: 8) {
                    StatTile(title: "חלבון ביום", value: "\(Int(m.protein)) ג׳")
                    StatTile(title: "פחמימות ביום", value: "\(Int(m.carbs)) ג׳")
                    StatTile(title: "שומן ביום", value: "\(Int(m.fat)) ג׳")
                }
            }
        }
    }
}
