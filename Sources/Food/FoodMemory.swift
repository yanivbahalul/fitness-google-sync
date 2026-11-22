import Foundation
import Vision

/// Foods the scanner has recognized before, kept on the iPhone: a visual fingerprint
/// (Vision feature print, not the photo) with the name and nutrition values. The scanner
/// checks new objects against it on the phone first, so a food seen before is labelled at
/// once without asking Claude. User corrections are learned too.
@MainActor
final class FoodMemory {
    static let shared = FoodMemory()

    struct Entry: Codable {
        var id = UUID()
        var label: String
        var grams: Double
        var kcalPer100: Double
        var proteinPer100: Double
        var carbsPer100: Double
        var fatPer100: Double
        /// Tzameret food code when the values came from the database.
        var foodCode: Int?
        /// Archived VNFeaturePrintObservation.
        var print: Data
        var lastSeen = Date()
        var uses = 1
    }

    private(set) var entries: [Entry] = []
    private var decoded: [UUID: VNFeaturePrintObservation] = [:]
    private let maxEntries = 300
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("food-memory.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Fingerprints of remembered foods (excluding ones already in use this session).
    func prints(excluding ids: Set<UUID>) -> [(UUID, VNFeaturePrintObservation)] {
        entries.compactMap { entry in
            guard !ids.contains(entry.id) else { return nil }
            if let cached = decoded[entry.id] { return (entry.id, cached) }
            guard let print = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self,
                                                                       from: entry.print) else { return nil }
            decoded[entry.id] = print
            return (entry.id, print)
        }
    }

    /// The remembered food as a new draft to show and log.
    func draft(for id: UUID) -> FoodDraft? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[i].lastSeen = Date()
        entries[i].uses += 1
        save()
        let e = entries[i]
        let food = e.foodCode.flatMap { code in FoodDatabase.shared.foods.first { $0.code == code } }
        return FoodDraft(label: e.label, food: food, grams: e.grams,
                         kcalPer100: e.kcalPer100, proteinPer100: e.proteinPer100,
                         carbsPer100: e.carbsPer100, fatPer100: e.fatPer100,
                         portionNote: "זוהה מהזיכרון")
    }

    /// Stores (or updates) a food with its fingerprint. Returns the memory entry's id.
    @discardableResult
    func learn(_ draft: FoodDraft, print: VNFeaturePrintObservation, entryID: UUID? = nil) -> UUID? {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return nil }
        let food = draft.food
        var entry = Entry(label: draft.label, grams: draft.grams,
                          kcalPer100: food?.kcal ?? draft.kcalPer100, proteinPer100: food?.protein ?? draft.proteinPer100,
                          carbsPer100: food?.carbs ?? draft.carbsPer100, fatPer100: food?.fat ?? draft.fatPer100,
                          foodCode: food?.code, print: data)
        if let entryID, let i = entries.firstIndex(where: { $0.id == entryID }) {
            entry.id = entryID
            entry.uses = entries[i].uses + 1
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        decoded[entry.id] = print
        // Keep the most recently seen foods.
        if entries.count > maxEntries {
            entries.sort { $0.lastSeen > $1.lastSeen }
            for removed in entries[maxEntries...] { decoded[removed.id] = nil }
            entries = Array(entries.prefix(maxEntries))
        }
        save()
        return entry.id
    }

    /// Updates what a remembered food is (after the user corrected it).
    func correct(_ entryID: UUID, with draft: FoodDraft) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let food = draft.food
        entries[i].label = draft.label
        entries[i].grams = draft.grams
        entries[i].kcalPer100 = food?.kcal ?? draft.kcalPer100
        entries[i].proteinPer100 = food?.protein ?? draft.proteinPer100
        entries[i].carbsPer100 = food?.carbs ?? draft.carbsPer100
        entries[i].fatPer100 = food?.fat ?? draft.fatPer100
        entries[i].foodCode = food?.code
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
