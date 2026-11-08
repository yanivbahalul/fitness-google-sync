import Foundation
import HealthKit

/// One logged food (a meal can be several entries, e.g. from one photo).
struct FoodEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case photo, text, search, barcode, quick, cali

        var title: String {
            switch self {
            case .photo: return "צילום"
            case .text: return "תיאור"
            case .search: return "חיפוש"
            case .barcode: return "ברקוד"
            case .quick: return "הזנה מהירה"
            case .cali: return "Cali"
            }
        }

        var symbol: String {
            switch self {
            case .photo: return "camera.fill"
            case .text: return "text.bubble.fill"
            case .search: return "magnifyingglass"
            case .barcode: return "barcode.viewfinder"
            case .quick: return "bolt.fill"
            case .cali: return "square.and.arrow.down.fill"
            }
        }
    }

    var id = UUID()
    var date: Date
    var name: String
    /// Eaten amount in grams (nil for a quick calorie-only entry).
    var grams: Double?
    var kcal: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var source: Source
    /// Stable key for imported rows, so importing the same export twice adds nothing.
    var importKey: String?
}

/// A food the user is about to log (from a photo, text, search or barcode), editable before saving.
struct FoodDraft: Identifiable, Equatable {
    var id = UUID()
    /// What the AI or the user called it.
    var label: String
    /// Matched database food (nil = use the per-100 g values below).
    var food: FoodItem?
    var grams: Double
    /// Per-100 g values used when there is no database match (AI estimate or barcode).
    var kcalPer100: Double
    var proteinPer100: Double
    var carbsPer100: Double
    var fatPer100: Double
    var include = true

    var kcal: Double { (food?.kcal ?? kcalPer100) * grams / 100 }
    var protein: Double { (food?.protein ?? proteinPer100) * grams / 100 }
    var carbs: Double { (food?.carbs ?? carbsPer100) * grams / 100 }
    var fat: Double { (food?.fat ?? fatPer100) * grams / 100 }
    var displayName: String { food?.name ?? label }

    static func == (a: FoodDraft, b: FoodDraft) -> Bool {
        a.id == b.id && a.food == b.food && a.grams == b.grams && a.include == b.include && a.label == b.label
    }
}

/// The food diary: stored on the iPhone and mirrored into Apple Health
/// (dietary energy, protein, carbohydrates, fat).
@MainActor
final class FoodLog: ObservableObject {
    static let shared = FoodLog()
    static let entryKey = "HealthBridge.foodEntryID"

    @Published private(set) var entries: [FoodEntry] = []
    @Published var lastError: String?

    private let store = HKHealthStore()
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("food-log.json")
    }()

    private let types: [(HKQuantityTypeIdentifier, HKUnit)] = [
        (.dietaryEnergyConsumed, .kilocalorie()),
        (.dietaryProtein, .gram()),
        (.dietaryCarbohydrates, .gram()),
        (.dietaryFatTotal, .gram()),
    ]

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([FoodEntry].self, from: data) {
            entries = saved
        }
    }

    /// Timestamp for food logged "on" a day: now for today, the same time of day for a past day.
    static func entryDate(for day: Date) -> Date {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return Date() }
        let time = calendar.dateComponents([.hour, .minute], from: Date())
        return calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: 0,
                             of: calendar.startOfDay(for: day)) ?? day
    }

    func total(on day: Date) -> Double {
        entries(on: day).map(\.kcal).reduce(0, +)
    }

    func entries(on day: Date) -> [FoodEntry] {
        entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }.sorted { $0.date > $1.date }
    }

    func add(_ drafts: [FoodDraft], source: FoodEntry.Source, at date: Date = Date()) async {
        let new = drafts.filter { $0.include && $0.kcal > 0 }.map {
            FoodEntry(date: date, name: $0.displayName, grams: $0.grams, kcal: $0.kcal,
                      protein: $0.protein, carbs: $0.carbs, fat: $0.fat, source: source)
        }
        await add(new)
    }

    func addQuick(kcal: Double, name: String = "הזנה מהירה", at date: Date = Date()) async {
        await add([FoodEntry(date: date, name: name, grams: nil, kcal: kcal,
                             protein: 0, carbs: 0, fat: 0, source: .quick)])
    }

    /// Adds imported entries, skipping ones already imported. Returns how many were new.
    @discardableResult
    func importEntries(_ imported: [FoodEntry]) async -> Int {
        let existing = Set(entries.compactMap(\.importKey))
        let new = imported.filter { $0.importKey.map { !existing.contains($0) } ?? true }
        await add(new)
        return new.count
    }

    /// Total eaten per day (local midnight → kcal).
    func dailyTotals() -> [Date: (kcal: Double, protein: Double, carbs: Double, fat: Double)] {
        var result: [Date: (kcal: Double, protein: Double, carbs: Double, fat: Double)] = [:]
        let calendar = Calendar.current
        for e in entries {
            let day = calendar.startOfDay(for: e.date)
            let t = result[day] ?? (0, 0, 0, 0)
            result[day] = (t.kcal + e.kcal, t.protein + e.protein, t.carbs + e.carbs, t.fat + e.fat)
        }
        return result
    }

    /// Entries imported from Cali before `date`.
    func importedEntries(before date: Date) -> [FoodEntry] {
        entries.filter { $0.source == .cali && $0.date < date }
    }

    /// Deletes Cali-imported entries before `date` from the diary and Apple Health.
    func deleteImported(before date: Date) async {
        for entry in importedEntries(before: date) {
            await delete(entry)
        }
    }

        func delete(_ entry: FoodEntry) async {
        entries.removeAll { $0.id == entry.id }
        save()
        do {
            for (id, _) in types {
                let predicate = HKQuery.predicateForObjects(withMetadataKey: Self.entryKey,
                                                            allowedValues: [entry.id.uuidString])
                try await deleteObjects(of: HKQuantityType(id), predicate: predicate)
            }
        } catch {
            lastError = "המחיקה מ‑Apple Health נכשלה: \(error.localizedDescription)"
        }
    }

    private func add(_ new: [FoodEntry]) async {
        guard !new.isEmpty else { return }
        entries.append(contentsOf: new)
        save()
        do {
            await HealthAuthorization.request()
            var samples: [HKSample] = []
            for entry in new {
                let meta: [String: Any] = [Self.entryKey: entry.id.uuidString, HKMetadataKeyFoodType: entry.name]
                let values = [entry.kcal, entry.protein, entry.carbs, entry.fat]
                for ((id, unit), value) in zip(types, values) where value > 0 {
                    samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value),
                                                    start: entry.date, end: entry.date, metadata: meta))
                }
            }
            try await store.save(samples)
            lastError = nil
        } catch {
            lastError = "השמירה ב‑Apple Health נכשלה: \(error.localizedDescription)"
        }
    }

    /// Calories eaten per day that other apps (e.g. Cali) wrote to Apple Health, excluding
    /// what this app wrote, so nothing is counted twice.
    func otherAppsDailyKcal(from start: Date, days: Int) async -> [Date: Double] {
        let type = HKQuantityType(.dietaryEnergyConsumed)
        await HealthAuthorization.request()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: days, to: start)!
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default())),
        ])
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum, anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, _ in
                var totals: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    if let v = stats.sumQuantity()?.doubleValue(for: .kilocalorie()), v > 0 { totals[stats.startDate] = v }
                }
                continuation.resume(returning: totals)
            }
            store.execute(query)
        }
    }

    private func save() {
        // Keep a year of history on the device.
        let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date())!
        entries.removeAll { $0.date < cutoff }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                if let error = error as? HKError, error.code == .errorNoData {
                    continuation.resume()
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
