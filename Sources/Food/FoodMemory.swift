import Foundation
import Vision

/// Foods the scanner has recognized before, kept on the iPhone, so a food seen before is
/// labelled on the phone at once instead of asking Claude again.
///
/// How it learns (few-shot, nearest neighbour on Vision's on-device image embeddings):
/// - Each food (by name) keeps up to 6 example fingerprints (Vision feature prints, not
///   photos) taken from different looks: angle, light, cup.
/// - A new look that is nearly identical to an existing example isn't stored twice; the
///   better-quality one of the two is kept (bigger, sharper, better lit).
/// - A new look that differs (another cup, other light) but is the same food per Claude
///   becomes another example, so recognition gets broader and faster with use.
/// - Matching compares an object with every example and takes the closest food, only when
///   it is clearly closer than the next food.
/// - User corrections rename the food's memory, so it is right next time.
@MainActor
final class FoodMemory {
    static let shared = FoodMemory()

    struct Example: Codable {
        /// Archived VNFeaturePrintObservation.
        var print: Data
        var quality: Float
        var lastSeen = Date()
    }

    struct Food: Codable {
        var id = UUID()
        var label: String
        var grams: Double
        var kcalPer100: Double
        var proteinPer100: Double
        var carbsPer100: Double
        var fatPer100: Double
        /// Tzameret food code when the values came from the database.
        var foodCode: Int?
        var examples: [Example] = []
        var lastSeen = Date()
        var uses = 1
    }

    private(set) var foods: [Food] = []
    private var decoded: [Data: VNFeaturePrintObservation] = [:]
    private let maxFoods = 200
    private let maxExamples = 6
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("food-memory-v2.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Food].self, from: data) {
            foods = saved
        }
    }

    /// Two looks closer than this are the same image for memory purposes.
    private var sameLook: Float {
        if #available(iOS 17.0, *) { return 0.25 } else { return 7 }
    }

    private func observation(_ data: Data) -> VNFeaturePrintObservation? {
        if let cached = decoded[data] { return cached }
        let print = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
        decoded[data] = print
        return print
    }

    /// Every example fingerprint, labelled with its food (excluding foods already shown).
    func prints(excluding ids: Set<UUID>) -> [(UUID, VNFeaturePrintObservation)] {
        foods.filter { !ids.contains($0.id) }.flatMap { food in
            food.examples.compactMap { ex in observation(ex.print).map { (food.id, $0) } }
        }
    }

    /// The remembered food as a new draft to show and log.
    func draft(for id: UUID) -> FoodDraft? {
        guard let i = foods.firstIndex(where: { $0.id == id }) else { return nil }
        foods[i].lastSeen = Date()
        foods[i].uses += 1
        save()
        let f = foods[i]
        let item = f.foodCode.flatMap { code in FoodDatabase.shared.foods.first { $0.code == code } }
        var draft = FoodDraft(label: f.label, food: item, grams: f.grams,
                              kcalPer100: f.kcalPer100, proteinPer100: f.proteinPer100,
                              carbsPer100: f.carbsPer100, fatPer100: f.fatPer100,
                              portionNote: "זוהה מהזיכרון")
        draft.id = UUID()
        return draft
    }

    /// Adds a look of a food. Returns the food's memory id.
    @discardableResult
    func learn(_ draft: FoodDraft, print: VNFeaturePrintObservation, quality: Float, foodID: UUID? = nil) -> UUID? {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return nil }
        let name = draft.label.trimmingCharacters(in: .whitespaces)
        let index = foodID.flatMap { id in foods.firstIndex { $0.id == id } }
            ?? foods.firstIndex { $0.label.trimmingCharacters(in: .whitespaces) == name }
        var food: Food
        if let index {
            food = foods[index]
        } else {
            let item = draft.food
            food = Food(label: name, grams: draft.grams,
                        kcalPer100: item?.kcal ?? draft.kcalPer100, proteinPer100: item?.protein ?? draft.proteinPer100,
                        carbsPer100: item?.carbs ?? draft.carbsPer100, fatPer100: item?.fat ?? draft.fatPer100,
                        foodCode: item?.code)
        }
        decoded[data] = print
        let example = Example(print: data, quality: quality)

        // Nearly the same look as an existing example: keep the better one.
        var closest: (index: Int, distance: Float)?
        for (i, ex) in food.examples.enumerated() {
            guard let known = observation(ex.print) else { continue }
            var d: Float = .greatestFiniteMagnitude
            try? print.computeDistance(&d, to: known)
            if d < (closest?.distance ?? .greatestFiniteMagnitude) { closest = (i, d) }
        }
        if let closest, closest.distance < sameLook {
            if quality > food.examples[closest.index].quality { food.examples[closest.index] = example }
            else { food.examples[closest.index].lastSeen = Date() }
        } else if food.examples.count < maxExamples {
            food.examples.append(example)
        } else {
            // Full: replace the weakest example (oldest of the lowest quality).
            let weakest = food.examples.indices.min { a, b in
                (food.examples[a].quality, food.examples[a].lastSeen) < (food.examples[b].quality, food.examples[b].lastSeen)
            }!
            food.examples[weakest] = example
        }
        food.lastSeen = Date()

        if let index { foods[index] = food } else { foods.append(food) }
        if foods.count > maxFoods {
            foods.sort { $0.lastSeen > $1.lastSeen }
            foods = Array(foods.prefix(maxFoods))
        }
        save()
        return food.id
    }

    /// The user said what a remembered food really is: rename it and take its values.
    func correct(_ foodID: UUID, with draft: FoodDraft) {
        guard let i = foods.firstIndex(where: { $0.id == foodID }) else { return }
        let item = draft.food
        foods[i].label = draft.label
        foods[i].grams = draft.grams
        foods[i].kcalPer100 = item?.kcal ?? draft.kcalPer100
        foods[i].proteinPer100 = item?.protein ?? draft.proteinPer100
        foods[i].carbsPer100 = item?.carbs ?? draft.carbsPer100
        foods[i].fatPer100 = item?.fat ?? draft.fatPer100
        foods[i].foodCode = item?.code
        save()
    }

    // MARK: Backup

    /// Writes the memory to a file for the share sheet (Files, AirDrop…).
    func exportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HealthBridge-food-memory.json")
        guard let data = try? JSONEncoder().encode(foods), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// Adds foods from an exported file: same-name foods get the new examples (no
    /// duplicates, up to the limit); new foods are added. Returns how many foods changed.
    @discardableResult
    func importFile(_ url: URL) -> Int {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let incoming = try? JSONDecoder().decode([Food].self, from: data) else { return 0 }
        var changed = 0
        for food in incoming {
            if let i = foods.firstIndex(where: { $0.label == food.label }) {
                let known = Set(foods[i].examples.map(\.print))
                let extra = food.examples.filter { !known.contains($0.print) }
                guard !extra.isEmpty else { continue }
                foods[i].examples = Array((foods[i].examples + extra)
                    .sorted { $0.quality > $1.quality }.prefix(maxExamples))
                changed += 1
            } else {
                foods.append(food)
                changed += 1
            }
        }
        save()
        return changed
    }

    private func save() {
        if let data = try? JSONEncoder().encode(foods) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
