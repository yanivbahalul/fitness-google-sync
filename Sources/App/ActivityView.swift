import Charts
import HealthKit
import SwiftUI

/// Daily activity and health data read back from Apple Health: either its merged numbers
/// (as the Health app shows them) or only what HealthBridge wrote (the band's data).
@MainActor
final class ActivityModel: ObservableObject {
    struct DayValue: Identifiable {
        let day: Date
        let value: Double
        var id: Date { day }
    }

    enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: return "שבוע"
            case .month: return "חודש"
            case .quarter: return "3 חודשים"
            }
        }
    }

    @Published var range: Range = .month
    @Published private(set) var steps: [DayValue] = []
    @Published private(set) var distanceKm: [DayValue] = []
    @Published private(set) var activeKcal: [DayValue] = []
    @Published private(set) var floors: [DayValue] = []
    @Published private(set) var sleepHours: [DayValue] = []
    @Published private(set) var restingHR: [DayValue] = []
    @Published private(set) var vo2Max: Double?
    @Published private(set) var loading = false

    private let store = HKHealthStore()
    /// Each refresh gets a number; only the newest one may publish its results, so an
    /// older, slower refresh never overwrites fresh data written by a sync.
    private var generation = 0

    func today(_ series: [DayValue]) -> Double {
        series.first { Calendar.current.isDateInToday($0.day) }?.value ?? 0
    }

    /// Average over complete days (today excluded) that have data.
    func average(_ series: [DayValue]) -> Double? {
        let past = series.filter { !Calendar.current.isDateInToday($0.day) && $0.value > 0 }
        guard !past.isEmpty else { return nil }
        return past.map(\.value).reduce(0, +) / Double(past.count)
    }

    func refresh() async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: today)!

        await HealthAuthorization.request()

        let steps = await daily(.stepCount, unit: .count(), from: start, cumulative: true)
        let distance = await daily(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), from: start, cumulative: true)
        let active = await daily(.activeEnergyBurned, unit: .kilocalorie(), from: start, cumulative: true)
        let floors = await daily(.flightsClimbed, unit: .count(), from: start, cumulative: true)
        let resting = await daily(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, cumulative: false)
        let sleep = await sleep(from: start)
        let vo2 = await latest(.vo2Max, unit: HKUnit(from: "ml/kg*min"))

        guard mine == generation else { return }
        self.steps = steps
        distanceKm = distance
        activeKcal = active
        self.floors = floors
        restingHR = resting
        sleepHours = sleep
        vo2Max = vo2
    }

    /// Only what HealthBridge wrote (the band's data from Google).
    private var ownSource: NSPredicate { HKQuery.predicateForObjects(from: HKSource.default()) }

    /// Show Apple Health's merged numbers (every source, de-duplicated by the Health app's
    /// source priority), the same as the Health app. Sleep always stays HealthBridge-only,
    /// because summing several sources' sleep stages would count the night twice.
    private var allSources: Bool { UserDefaults.standard.bool(forKey: AppSettings.activityAllSourcesKey) }

    private func daily(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, cumulative: Bool) async -> [DayValue] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
        ] + (allSources ? [] : [ownSource]))
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(id), quantitySamplePredicate: predicate,
                options: cumulative ? .cumulativeSum : .discreteAverage,
                anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, _ in
                var values: [DayValue] = []
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let q = cumulative ? stats.sumQuantity() : stats.averageQuantity()
                    if let v = q?.doubleValue(for: unit), v > 0 {
                        values.append(DayValue(day: stats.startDate, value: v))
                    }
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    /// Hours asleep per night, counted on the day you woke up (naps on their own day).
    private func sleep(from start: Date) async -> [DayValue] {
        let calendar = Calendar.current
        let from = calendar.date(byAdding: .hour, value: -12, to: start)!
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: from, end: nil, options: []), ownSource,
        ])
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        // A night belongs to the morning you wake up: shift by 6 hours so the "day" runs
        // 18:00-18:00. Stages on both sides of midnight land on the same day, and a
        // daytime nap counts for that same day.
        var byDay: [Date: Double] = [:]
        for s in samples where asleep.contains(s.value) {
            let day = calendar.startOfDay(for: s.startDate.addingTimeInterval(6 * 3600))
            guard day >= start else { continue }
            byDay[day, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600
        }
        return byDay.map { DayValue(day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: HKQuantityType(id), predicate: allSources ? nil : ownSource, limit: 1,
                                      sortDescriptors: [sort]) { _, results, _ in
                continuation.resume(returning: (results?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}

/// The activity screen: today's numbers and trends for steps, movement, sleep and heart.
struct ActivityPage: View {
    @StateObject private var model = ActivityModel()
    @EnvironmentObject private var sync: SyncCoordinator
    @AppStorage(AppSettings.stepGoalKey) private var stepGoal = 10000
    @State private var burnedToday: Int?
    @AppStorage(AppSettings.activityAllSourcesKey) private var allSources = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: DS.cardSpacing) {
                TodayStepsCard(model: model, goal: stepGoal, burned: burnedToday, dataThrough: sync.today?.dataThrough)
                Picker("תקופה", selection: $model.range) {
                    ForEach(ActivityModel.Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                StepsTrendCard(model: model, goal: $stepGoal)
                SleepCard(model: model)
                HeartCard(model: model)
            }
            .padding(.horizontal, DS.pagePadding)
            .padding(.bottom, 24)
        }
        .task { await model.refresh() }
        .task(id: sync.lastSyncDate) { burnedToday = await sync.burned(on: Date()) }
        .refreshable { await model.refresh() }
        .onChange(of: model.range) { _ in Task { await model.refresh() } }
        .onChange(of: sync.lastSyncDate) { _ in Task { await model.refresh() } }
        .onChange(of: allSources) { _ in Task { await model.refresh() } }
        // A sync from a Shortcut or in the background happens while this screen isn't
        // visible (and Apple Health can't be read while the phone is locked), so reload
        // whenever the app comes back.
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await model.refresh()
                burnedToday = await sync.burned(on: Date())
            }
        }
    }
}

private struct TodayStepsCard: View {
    @ObservedObject var model: ActivityModel
    let goal: Int
    /// Total calories burned today (resting + active), the number Google Health shows.
    let burned: Int?
    let dataThrough: Date?

    var body: some View {
        let steps = model.today(model.steps)
        let fraction = goal > 0 ? min(steps / Double(goal), 1) : 0
        Card {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.walk")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("היום")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(Int(safe: steps).formatted()) צעדים")
                        .font(.title2.bold())
                        .monospacedDigit()
                    Text(steps >= Double(goal)
                         ? "הגעת ליעד של \(goal.formatted())"
                         : "נשארו \(Int(safe: Double(goal) - steps).formatted()) ליעד")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                StatTile(title: "ק״מ", value: String(format: "%.1f", model.today(model.distanceKm)), symbol: "map.fill")
                let active = Int(safe: model.today(model.activeKcal))
                if let burned {
                    StatTile(title: "נשרפו, \(active.formatted()) בפעילות", value: burned.formatted(), symbol: "flame.fill")
                } else {
                    StatTile(title: "קלוריות פעילות", value: active.formatted(), symbol: "flame.fill")
                }
                StatTile(title: "קומות", value: Int(safe: model.today(model.floors)).formatted(), symbol: "figure.stairs")
            }
            Text(dataThrough.map { Calendar.current.isDateInToday($0)
                    ? "נתוני הצמיד עד \($0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .he)))"
                    : "הנתונים מתעדכנים בכל סנכרון." } ?? "הנתונים מתעדכנים בכל סנכרון.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StepsTrendCard: View {
    @ObservedObject var model: ActivityModel
    @Binding var goal: Int
    @State private var selected: ActivityModel.DayValue?

    var body: some View {
        let past = model.steps.filter { !Calendar.current.isDateInToday($0.day) }
        let reached = past.filter { $0.value >= Double(goal) }.count
        Card {
            CardHeader(title: "צעדים", symbol: "figure.walk")
            if model.steps.isEmpty {
                Text("אין עדיין נתוני צעדים. סנכרן כדי לטעון אותם.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ממוצע \(Int(safe: model.average(model.steps) ?? 0).formatted()) צעדים ביום")
                        .font(.title3.weight(.semibold))
                    Text("ב‑\(reached) מתוך \(past.count) ימים הגעת ליעד")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(model.steps) { d in
                        BarMark(x: .value("יום", d.day, unit: .day), y: .value("צעדים", d.value))
                            .foregroundStyle(d.value >= Double(goal) ? Theme.accent : Theme.accent.opacity(0.45))
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("יעד", goal))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .foregroundStyle(ChartColors.reference)
                    if let selected {
                        RuleMark(x: .value("יום", selected.day, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .annotation(position: .top) {
                                ValueBubble(title: selected.day.formatted(.dateTime.day().month(.wide).locale(.he)),
                                            value: "\(Int(safe: selected.value).formatted()) צעדים")
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(anchor: .trailing) {
                            if let v = value.as(Double.self) { Text(compact(v)).font(.caption) }
                        }
                    }
                }
                .dailyDateAxis(model.steps.map(\.day))
                .frame(height: 200)
                .environment(\.layoutDirection, .leftToRight)
                .chartOverlay { proxy in
                    SelectionOverlay(proxy: proxy) { date in
                        selected = model.steps.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
                    } onEnd: { selected = nil }
                }
                .accessibilityElement()
                .accessibilityLabel("גרף צעדים יומי")
            }
            Divider()
            HStack {
                Label("יעד צעדים", systemImage: "target").font(.subheadline)
                Spacer()
                Stepper(goal.formatted(), value: $goal, in: 1000...40000, step: 500)
                    .fixedSize()
            }
        }
    }
}

private struct SleepCard: View {
    @ObservedObject var model: ActivityModel

    var body: some View {
        Card {
            CardHeader(title: "שינה", symbol: "bed.double.fill")
            if model.sleepHours.isEmpty {
                Text("אין עדיין נתוני שינה.").foregroundStyle(.secondary)
            } else {
                let last = model.sleepHours.last
                VStack(alignment: .leading, spacing: 4) {
                    if let last {
                        Text("בלילה האחרון ישנת \(hoursText(last.value))")
                            .font(.title3.weight(.semibold))
                    }
                    if let avg = model.average(model.sleepHours) {
                        Text("ממוצע \(hoursText(avg)) בלילה")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Chart(model.sleepHours) { d in
                    BarMark(x: .value("לילה", d.day, unit: .day), y: .value("שעות", d.value))
                        .foregroundStyle(Theme.accent)
                        .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(anchor: .trailing) {
                            if let v = value.as(Double.self) { Text("\(Int(safe: v))").font(.caption) }
                        }
                    }
                }
                .dailyDateAxis(model.sleepHours.map(\.day))
                .chartYAxisLabel("שעות")
                .frame(height: 170)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityElement()
                .accessibilityLabel("גרף שעות שינה")
            }
        }
    }
}

private struct HeartCard: View {
    @ObservedObject var model: ActivityModel

    var body: some View {
        Card {
            CardHeader(title: "לב וכושר", symbol: "heart.fill")
            HStack(spacing: 8) {
                StatTile(title: "דופק במנוחה", value: model.restingHR.last.map { "\(Int(safe: $0.value))" } ?? "—",
                           symbol: "heart.fill")
                StatTile(title: "ממוצע בתקופה", value: model.average(model.restingHR).map { "\(Int(safe: $0))" } ?? "—",
                           symbol: "waveform.path.ecg")
                StatTile(title: "VO2 Max", value: model.vo2Max.map { String(format: "%.0f", $0) } ?? "—",
                           symbol: "lungs.fill")
            }
            if model.restingHR.count >= 2 {
                if let first = model.restingHR.first, let last = model.restingHR.last {
                    let diff = Int(safe: (last.value - first.value).rounded())
                    Text(diff < 0 ? "הדופק במנוחה ירד ב‑\(-diff) בתקופה הזו" :
                         diff > 0 ? "הדופק במנוחה עלה ב‑\(diff) בתקופה הזו" : "הדופק במנוחה יציב")
                        .font(.subheadline)
                }
                Chart(model.restingHR) { d in
                    LineMark(x: .value("יום", d.day), y: .value("דופק", d.value))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(anchor: .trailing) {
                            if let v = value.as(Double.self) { Text("\(Int(safe: v))").font(.caption) }
                        }
                    }
                }
                .dailyDateAxis(model.restingHR.map(\.day))
                .frame(height: 140)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityElement()
                .accessibilityLabel("גרף דופק במנוחה")
            }
        }
    }
}

private func hoursText(_ hours: Double) -> String {
    let minutes = Int(safe: (hours * 60).rounded())
    return "\(minutes / 60):\(String(format: "%02d", minutes % 60)) שעות"
}

private func compact(_ v: Double) -> String {
    v >= 1000 ? String(format: "%.0fK", v / 1000) : "\(Int(safe: v))"
}
