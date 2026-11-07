import Charts
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                EnergyCard()
                AddFoodCard()
                TodayDiaryCard()
                ProgressSection(progress: progress)
                ImportCard(progress: progress)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .task { await progress.refresh(sync: sync, food: food) }
        .refreshable {
            await sync.refreshEnergy()
            await progress.refresh(sync: sync, food: food)
        }
        .onChange(of: food.entries) { _ in
            Task {
                await sync.refreshEnergy()
                await progress.refresh(sync: sync, food: food)
            }
        }
    }
}

// MARK: - Add food

private enum AddMode: String, Identifiable {
    case photo, text, search, barcode
    var id: String { rawValue }
}

private struct AddFoodCard: View {
    @State private var mode: AddMode?
    @State private var quickAdd = false
    @State private var quickText = ""

    var body: some View {
        Card {
            Label("הוסף אוכל", systemImage: "plus.circle.fill")
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
            case .photo: PhotoAnalyzeView()
            case .text: TextAnalyzeView()
            case .search: FoodSearchView()
            case .barcode: BarcodeAddView()
            }
        }
        .alert("הזנה מהירה", isPresented: $quickAdd) {
            TextField("קלוריות", text: $quickText).keyboardType(.numberPad)
            Button("הוסף") {
                if let kcal = Double(quickText.filter(\.isNumber)), kcal > 0 {
                    Task { await FoodLog.shared.addQuick(kcal: kcal) }
                }
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("כמה קלוריות להוסיף ליומן של היום?")
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

private struct TodayDiaryCard: View {
    @ObservedObject private var food = FoodLog.shared
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        let today = food.entries(on: Date())
        Card {
            HStack {
                Label("יומן היום", systemImage: "list.bullet.rectangle.fill")
                    .font(.headline)
                Spacer()
                Text("\(Int(today.map(\.kcal).reduce(0, +)).formatted()) קק\"ל")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if sync.manualEatenToday != nil {
                Notice(symbol: "info.circle.fill", color: .teal,
                       text: "יש להיום הזנה ידנית של סך הקלוריות, והיא קובעת את המאזן. כדי שהיומן ייספר, מחק אותה בכרטיס המאזן (עדכן נאכלו ← מחק הזנה).")
            }
            if today.isEmpty {
                Text("עדיין לא נרשם אוכל היום.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(today) { entry in
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

private struct ProgressSection: View {
    @ObservedObject var progress: ProgressModel
    @EnvironmentObject private var sync: SyncCoordinator
    @AppStorage("goalWeight") private var goalWeight = 0.0

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("התקדמות")
                    .font(.title3.bold())
                Spacer()
                Picker("טווח", selection: $progress.range) {
                    ForEach(ProgressModel.Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: progress.range) { _ in
                    Task { await progress.refresh(sync: sync, food: FoodLog.shared) }
                }
            }
            .padding(.top, 4)

            WeightCard(progress: progress, goalWeight: $goalWeight)
            BalanceCard(progress: progress)
            ExpectedVsActualCard(progress: progress)
            MacrosCard(progress: progress)
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil

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
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private func kg(_ v: Double, sign: Bool = false) -> String {
    let s = String(format: "%.1f", abs(v))
    guard sign else { return "\(s) ק״ג" }
    return (v < 0 ? "−" : v > 0 ? "+" : "") + "\(s) ק״ג"
}

private struct WeightCard: View {
    @ObservedObject var progress: ProgressModel
    @Binding var goalWeight: Double
    @State private var selected: ProgressModel.WeightPoint?

    var body: some View {
        Card {
            Label("משקל", systemImage: "scalemass.fill")
                .font(.headline)

            if progress.weights.isEmpty {
                Text("אין עדיין שקילות בטווח הזה. שקילות מגיעות מ‑Google (משקל) או מייבוא של Cali.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    StatTile(title: "עכשיו (ממוצע 7 ימים)", value: progress.currentWeight.map { kg($0) } ?? "—")
                    StatTile(title: "שינוי בטווח", value: progress.change.map { kg($0, sign: true) } ?? "—")
                    StatTile(title: "קצב שבועי", value: progress.weeklyRate.map { kg($0, sign: true) } ?? "—")
                }

                Chart {
                    ForEach(progress.weights) { p in
                        PointMark(x: .value("תאריך", p.date), y: .value("משקל", p.kg))
                            .symbolSize(40)
                            .foregroundStyle(by: .value("סדרה", "שקילה"))
                    }
                    ForEach(progress.trend) { p in
                        LineMark(x: .value("תאריך", p.date), y: .value("משקל", p.kg))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(by: .value("סדרה", "ממוצע 7 ימים"))
                    }
                    if goalWeight > 0 {
                        RuleMark(y: .value("יעד", goalWeight))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, alignment: .leading) {
                                Text("יעד \(kg(goalWeight))").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    if let selected {
                        RuleMark(x: .value("תאריך", selected.date))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .annotation(position: .top) {
                                Tooltip(title: selected.date.formatted(date: .abbreviated, time: .omitted),
                                        value: kg(selected.kg))
                            }
                    }
                }
                .chartForegroundStyleScale(["שקילה": ChartColors.blue.opacity(0.45), "ממוצע 7 ימים": ChartColors.blue])
                .chartYScale(domain: .automatic(includesZero: false))
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 220)
                .chartOverlay { proxy in selectionOverlay(proxy: proxy) }
                .accessibilityLabel("גרף משקל")
                .accessibilityValue(progress.change.map { "שינוי של \(kg($0, sign: true)) בטווח" } ?? "")
            }

            HStack {
                Text("משקל יעד")
                    .font(.subheadline)
                Spacer()
                Stepper(goalWeight > 0 ? kg(goalWeight) : "לא הוגדר", value: $goalWeight, in: 0...250, step: 0.5)
                    .fixedSize()
            }
            if goalWeight > 0, let weeks = progress.weeksToGoal(goalWeight) {
                let date = Calendar.current.date(byAdding: .day, value: Int(weeks * 7), to: Date()) ?? Date()
                Text("בקצב הנוכחי תגיע ליעד בעוד כ‑\(Int(weeks.rounded())) שבועות (\(date.formatted(.dateTime.day().month().year())))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectionOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = geo[proxy.plotAreaFrame].origin
                        guard let date: Date = proxy.value(atX: value.location.x - origin.x) else { return }
                        selected = progress.weights.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                    }
                    .onEnded { _ in selected = nil })
        }
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
        Card {
            Label("מאזן קלורי יומי", systemImage: "chart.bar.fill")
                .font(.headline)
            if progress.balances.isEmpty {
                Text("יופיע כאן כשיהיו ימים עם אוכל רשום וקלוריות שנשרפו מ‑Google (Google שומר עד כ‑90 יום אחורה).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    StatTile(title: "גרעון ממוצע ליום", value: progress.averageDeficit.map { "\(Int($0).formatted())" } ?? "—",
                             caption: "קק\"ל")
                    StatTile(title: "ימים נמדדים", value: "\(progress.balances.count)")
                    StatTile(title: "בגרעון", value: "\(progress.balances.filter { $0.deficit > 0 }.count)")
                }
                Chart {
                    ForEach(progress.balances) { b in
                        BarMark(x: .value("יום", b.day, unit: .day), y: .value("מאזן", b.deficit))
                            .foregroundStyle(by: .value("סוג", b.deficit >= 0 ? "גרעון" : "עודף"))
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("אפס", 0)).foregroundStyle(Color.secondary.opacity(0.5))
                    if let selected {
                        RuleMark(x: .value("יום", selected.day, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .annotation(position: .top) {
                                Tooltip(title: selected.day.formatted(date: .abbreviated, time: .omitted),
                                        value: "נשרפו \(Int(selected.burned)) · נאכלו \(Int(selected.eaten))")
                            }
                    }
                }
                .chartForegroundStyleScale(["גרעון": ChartColors.blue, "עודף": ChartColors.orange])
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 200)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let origin = geo[proxy.plotAreaFrame].origin
                                    guard let date: Date = proxy.value(atX: value.location.x - origin.x) else { return }
                                    selected = progress.balances.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
                                }
                                .onEnded { _ in selected = nil })
                    }
                }
                .accessibilityLabel("גרף מאזן קלורי יומי")
                Text("מעל הקו: גרעון (נשרף יותר משנאכל). רק ימים עם אוכל רשום נספרים.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExpectedVsActualCard: View {
    @ObservedObject var progress: ProgressModel

    var body: some View {
        if progress.comparison.contains(where: { $0.series == "צפוי לפי המאזן" }) {
            Card {
                Label("צפוי מול בפועל", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Chart(progress.comparison) { p in
                    LineMark(x: .value("תאריך", p.day), y: .value("שינוי", p.kg))
                        .foregroundStyle(by: .value("סדרה", p.series))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(["צפוי לפי המאזן": ChartColors.orange, "בפועל": ChartColors.blue])
                .chartLegend(position: .bottom, alignment: .leading)
                .chartYAxisLabel("ק״ג")
                .frame(height: 200)
                .accessibilityLabel("שינוי משקל צפוי מול בפועל")
                Text("\"צפוי\" מחושב מהגרעון המצטבר (כ‑7,700 קק\"ל לק\"ג). פער גדול בדרך כלל אומר שחלק מהאוכל לא נרשם, או שהערכת השריפה של הצמיד גבוהה מדי.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MacrosCard: View {
    @ObservedObject var progress: ProgressModel

    var body: some View {
        if let m = progress.macros7 {
            Card {
                Label("ממוצע 7 ימים אחרונים", systemImage: "chart.pie.fill")
                    .font(.headline)
                HStack(spacing: 8) {
                    StatTile(title: "קלוריות", value: Int(m.kcal).formatted())
                    StatTile(title: "חלבון", value: "\(Int(m.protein)) ג׳")
                    StatTile(title: "פחמימות", value: "\(Int(m.carbs)) ג׳")
                    StatTile(title: "שומן", value: "\(Int(m.fat)) ג׳")
                }
                Text("ממוצע על ימים שבהם נרשם אוכל.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Cali import

private struct ImportCard: View {
    @ObservedObject var progress: ProgressModel
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var picking = false
    @State private var message: String?
    @State private var importing = false

    var body: some View {
        Card {
            Label("ייבוא מ‑Cali", systemImage: "square.and.arrow.down.fill")
                .font(.headline)
            Text("ב‑Cali ייצא את הנתונים לקובץ CSV ובחר אותו כאן. היומן והשקילות ייכנסו להיסטוריה ול‑Apple Health. ייבוא חוזר של אותו קובץ לא יוצר כפילויות.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                picking = true
            } label: {
                HStack {
                    if importing { ProgressView() }
                    Label("בחר קובץ CSV", systemImage: "doc.badge.plus")
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .disabled(importing)
            if let message {
                Text(message).font(.footnote)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            importing = true
            Task {
                defer { importing = false }
                do {
                    let s = try await CaliImporter.importFile(at: url)
                    var text = "יובאו \(s.newFoods) רשומות אוכל חדשות (מתוך \(s.foods)) ו‑\(s.newWeights) שקילות חדשות."
                    if let a = s.firstDay, let b = s.lastDay {
                        text += " טווח: \(a.formatted(date: .abbreviated, time: .omitted)) – \(b.formatted(date: .abbreviated, time: .omitted))."
                    }
                    message = text
                    await progress.refresh(sync: sync, food: FoodLog.shared)
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }
}
