import Foundation
import HealthKit

/// Weight-loss progress: weight trend from Apple Health (Google-synced and Cali-imported
/// weights), calories eaten (food diary + Cali import) vs burned (Google Health), and how
/// the actual weight change compares with what the calorie balance predicts.
@MainActor
final class ProgressModel: ObservableObject {
    struct WeightPoint: Identifiable {
        let date: Date
        let kg: Double
        var id: Date { date }
    }

    struct DayBalance: Identifiable {
        let day: Date
        let eaten: Double
        let burned: Double
        var deficit: Double { burned - eaten }
        var id: Date { day }
    }

    struct ComparePoint: Identifiable {
        let day: Date
        let series: String
        let kg: Double
        var id: String { "\(series)-\(day.timeIntervalSince1970)" }
    }

    enum Range: Int, CaseIterable, Identifiable {
        case month = 30, quarter = 90, half = 180
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .month: return "חודש"
            case .quarter: return "3 חודשים"
            case .half: return "חצי שנה"
            }
        }
    }

    /// Roughly 7,700 kcal per kg of body fat.
    static let kcalPerKg = 7700.0
    /// Fewer logged days than this and daily water swings outweigh the real change.
    static let minDaysForComparison = 7

    @Published var range: Range = .half
    @Published private(set) var weights: [WeightPoint] = []
    @Published private(set) var trend: [WeightPoint] = []
    @Published private(set) var balances: [DayBalance] = []
    @Published private(set) var comparison: [ComparePoint] = []
    @Published private(set) var macros7: (kcal: Double, protein: Double, carbs: Double, fat: Double)?
    @Published private(set) var loading = false

    private let store = HKHealthStore()

    /// Weight on `date`, linearly interpolated between the nearest weigh-ins.
    func weightAt(_ date: Date) -> Double? {
        let before = weights.last { $0.date <= date }
        let after = weights.first { $0.date > date }
        switch (before, after) {
        case let (b?, a?):
            let span = a.date.timeIntervalSince(b.date)
            guard span > 0 else { return b.kg }
            return b.kg + (a.kg - b.kg) * date.timeIntervalSince(b.date) / span
        case let (b?, nil): return b.kg
        case let (nil, a?): return a.kg
        default: return nil
        }
    }

    var currentWeight: Double? { trend.last?.kg ?? weights.last?.kg }
    var startWeight: Double? { trend.first?.kg ?? weights.first?.kg }
    var change: Double? {
        guard let a = startWeight, let b = currentWeight else { return nil }
        return b - a
    }

    /// kg per week from a least-squares fit over the range (negative = losing).
    var weeklyRate: Double? {
        guard weights.count >= 2,
              let first = weights.first?.date, let last = weights.last?.date,
              last.timeIntervalSince(first) >= 7 * 86400 else { return nil }
        let xs = weights.map { $0.date.timeIntervalSince(first) / (7 * 86400) }
        let ys = weights.map(\.kg)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        return den > 0 ? num / den : nil
    }

    var averageDeficit: Double? {
        guard !balances.isEmpty else { return nil }
        return balances.map(\.deficit).reduce(0, +) / Double(balances.count)
    }

    /// Weeks until `goal` at the current weekly rate (nil if not trending toward it).
    func weeksToGoal(_ goal: Double) -> Double? {
        guard let current = currentWeight, let rate = weeklyRate, rate != 0 else { return nil }
        let weeks = (goal - current) / rate
        // A near-zero rate gives an absurd (or infinite) answer; only show realistic ones.
        return weeks.isFinite && weeks > 0 && weeks < 520 ? weeks : nil
    }

    func refresh(sync: SyncCoordinator, food: FoodLog) async {
        loading = true
        defer { loading = false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: today)!

        // Weight (all sources in Apple Health).
        let massType = HKQuantityType(.bodyMass)
        try? await store.requestAuthorization(toShare: [], read: [massType])
        let raw = (try? await samples(of: massType, from: start)) ?? []
        // One point per day (the day's last reading).
        var byDay: [Date: HKQuantitySample] = [:]
        for s in raw {
            let d = calendar.startOfDay(for: s.startDate)
            if let existing = byDay[d], existing.startDate > s.startDate { continue }
            byDay[d] = s
        }
        weights = byDay.values.sorted { $0.startDate < $1.startDate }
            .map { WeightPoint(date: $0.startDate, kg: $0.quantity.doubleValue(for: .gramUnit(with: .kilo))) }
        trend = weights.map { p in
            let window = weights.filter { $0.date <= p.date && $0.date > p.date.addingTimeInterval(-7 * 86400) }
            return WeightPoint(date: p.date, kg: window.map(\.kg).reduce(0, +) / Double(window.count))
        }

        // Calorie balance: only days with logged food and a burned value from Google.
        let burned = await sync.dailyBurned(days: range.rawValue)
        var eatenTotals = food.dailyTotals()
        // Add food other apps (e.g. Cali) wrote to Apple Health.
        for (day, kcal) in await food.otherAppsDailyKcal(from: start, days: range.rawValue) {
            let t = eatenTotals[day] ?? (0, 0, 0, 0)
            eatenTotals[day] = (t.kcal + kcal, t.protein, t.carbs, t.fat)
        }
        let foodStart = AppSettings.foodTrackingStart
        var days: [DayBalance] = []
        for offset in 0..<range.rawValue {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            guard day < today, day >= foodStart else { continue }  // today is incomplete
            let eaten = eatenTotals[day]?.kcal ?? 0
            guard eaten > 0, let b = burned[day], b > 0 else { continue }
            days.append(DayBalance(day: day, eaten: eaten, burned: b))
        }
        balances = days

        // Expected (from the cumulative calorie balance) vs actual weight change, both in kg,
        // both measured from the same starting point: the weight on the food tracking start
        // date (interpolated between weigh-ins). Only meaningful after a week of logging.
        var points: [ComparePoint] = []
        if days.count >= Self.minDaysForComparison, let w0 = weightAt(foodStart) {
            let start0 = calendar.startOfDay(for: foodStart)
            points.append(ComparePoint(day: start0, series: "צפוי לפי המאזן", kg: 0))
            points.append(ComparePoint(day: start0, series: "בפועל", kg: 0))
            var cumulative = 0.0
            for b in days {
                cumulative += b.deficit
                // The effect of a day's balance shows at the end of that day.
                let end = calendar.date(byAdding: .day, value: 1, to: b.day)!
                points.append(ComparePoint(day: end, series: "צפוי לפי המאזן", kg: -cumulative / Self.kcalPerKg))
            }
            for p in weights where p.date > start0 {
                points.append(ComparePoint(day: p.date, series: "בפועל", kg: p.kg - w0))
            }
        }
        comparison = points

        // 7-day macro averages over days with logged food.
        let last7 = (1...7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .filter { $0 >= foodStart }
            .compactMap { eatenTotals[$0] }
        if !last7.isEmpty {
            let n = Double(last7.count)
            macros7 = (last7.map(\.kcal).reduce(0, +) / n, last7.map(\.protein).reduce(0, +) / n,
                       last7.map(\.carbs).reduce(0, +) / n, last7.map(\.fat).reduce(0, +) / n)
        } else {
            macros7 = nil
        }
    }

    private func samples(of type: HKQuantityType, from start: Date) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, results, error in
                if let error = error as? HKError, error.code == .errorNoData {
                    continuation.resume(returning: [])
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(query)
        }
    }
}
