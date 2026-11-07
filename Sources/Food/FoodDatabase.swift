import Foundation

/// One food from the Israeli national nutrition database (Tzameret, Ministry of Health,
/// data.gov.il). Nutrient values are per 100 g.
struct FoodItem: Identifiable, Hashable {
    let code: Int
    let name: String
    let englishName: String
    let kcal: Double
    let protein: Double
    let fat: Double
    let carbs: Double
    /// Household measures, e.g. ("יחידה בינונית", 146 g).
    let portions: [Portion]

    var id: Int { code }

    struct Portion: Hashable {
        let name: String
        let grams: Double
    }
}

/// The bundled Tzameret database (Sources/Food/tzameret.json, ~4,600 foods), searchable
/// offline in Hebrew or English.
final class FoodDatabase {
    static let shared = FoodDatabase()

    private(set) var foods: [FoodItem] = []
    private var normalizedNames: [String] = []
    private var loaded = false
    private let lock = NSLock()

    /// Where the data comes from (shown in the app for attribution).
    private(set) var source = "מאגר התזונה הלאומי (צמרת), משרד הבריאות"

    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "tzameret", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let units = json["units"] as? [String],
              let rows = json["foods"] as? [[Any]]
        else { return }
        if let s = json["source"] as? String { source = s }

        foods = rows.compactMap { row in
            guard row.count >= 8,
                  let code = row[0] as? Int,
                  let name = row[1] as? String else { return nil }
            func num(_ i: Int) -> Double { (row[i] as? NSNumber)?.doubleValue ?? 0 }
            let portions = (row[7] as? [[NSNumber]] ?? []).compactMap { pair -> FoodItem.Portion? in
                guard pair.count == 2, units.indices.contains(pair[0].intValue) else { return nil }
                return FoodItem.Portion(name: units[pair[0].intValue], grams: pair[1].doubleValue)
            }
            return FoodItem(code: code, name: name, englishName: row[2] as? String ?? "",
                            kcal: num(3), protein: num(4), fat: num(5), carbs: num(6), portions: portions)
        }
        normalizedNames = foods.map { Self.normalize($0.name + " " + $0.englishName) }
    }

    /// Best matches for a free-text query ("שניצל עוף", "hummus").
    func search(_ query: String, limit: Int = 40) -> [FoodItem] {
        loadIfNeeded()
        let tokens = Self.normalize(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        var scored: [(score: Double, index: Int)] = []
        for (i, name) in normalizedNames.enumerated() {
            var matched = 0
            var score = 0.0
            for token in tokens {
                if name.hasPrefix(token + " ") || name.hasPrefix(token) && name.count == token.count {
                    score += 4; matched += 1        // the food's name starts with the word
                } else if name.contains(" " + token) || name.hasPrefix(token) {
                    score += 3; matched += 1        // a word starts with it
                } else if name.contains(token) {
                    score += 1; matched += 1        // somewhere inside a word
                }
            }
            guard matched > 0 else { continue }
            if matched == tokens.count { score += 10 }
            score -= Double(foods[i].name.count) / 40   // prefer simpler, shorter names
            scored.append((score, i))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map { foods[$0.index] }
    }

    /// Lower-cases, removes punctuation and Hebrew niqqud, collapses spaces.
    static func normalize(_ s: String) -> String {
        let cleaned = s.lowercased().unicodeScalars.map { scalar -> Character in
            if (0x0591...0x05C7).contains(scalar.value) { return " " }  // niqqud / cantillation
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}
