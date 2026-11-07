import Foundation
import HealthKit

/// Imports a Cali ("Cali - AI מעקב תזונתי") CSV export: the food diary ("יומן מזון") and
/// weights ("משקל"). Importing the same file again adds nothing new.
enum CaliImporter {
    struct Summary {
        var foods = 0
        var newFoods = 0
        var weights = 0
        var newWeights = 0
        var firstDay: Date?
        var lastDay: Date?
    }

    enum ImportError: LocalizedError {
        case unreadable, notCali
        var errorDescription: String? {
            switch self {
            case .unreadable: return "לא הצלחתי לקרוא את הקובץ."
            case .notCali: return "הקובץ לא נראה כמו ייצוא של Cali (חסר \"יומן מזון\" או \"משקל\")."
            }
        }
    }

    private static let weightKeysKey = "importedWeightKeys"

    @MainActor
    static func importFile(at url: URL) async throws -> Summary {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        else { throw ImportError.unreadable }

        var section = ""
        var foods: [FoodEntry] = []
        var weights: [(key: String, date: Date, kg: Double)] = []
        var summary = Summary()

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let fields = parseCSVLine(line)
            guard let first = fields.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else { continue }
            if fields.count == 1 && !first.hasPrefix("20") {
                section = first.replacingOccurrences(of: "\u{FEFF}", with: "")
                continue
            }
            guard first.hasPrefix("20") else { continue } // header rows ("תאריך", ...)

            func num(_ i: Int) -> Double { i < fields.count ? Double(fields[i]) ?? 0 : 0 }

            if section.contains("יומן מזון"), fields.count >= 10 {
                let time = fields[1].isEmpty ? "12:00" : fields[1]
                guard let date = dayFormatter.date(from: "\(first) \(time)") else { continue }
                let name = fields[3].isEmpty ? fields[2] : fields[3]
                let kcal = num(6)
                guard kcal > 0 else { continue }
                let grams = num(5)
                foods.append(FoodEntry(date: date, name: name, grams: grams > 0 ? grams : nil, kcal: kcal,
                                       protein: num(7), carbs: num(8), fat: num(9), source: .cali,
                                       importKey: "cali|\(first)|\(time)|\(name)|\(fields[6])"))
                summary.firstDay = min(summary.firstDay ?? date, date)
                summary.lastDay = max(summary.lastDay ?? date, date)
            } else if section.contains("משקל"), fields.count >= 2 {
                let kg = num(1)
                guard kg > 20, kg < 400, let date = dayFormatter.date(from: "\(first) 08:00") else { continue }
                weights.append(("cali|\(first)|\(fields[1])", date, kg))
            }
        }
        guard !foods.isEmpty || !weights.isEmpty else { throw ImportError.notCali }

        summary.foods = foods.count
        summary.newFoods = await FoodLog.shared.importEntries(foods)

        summary.weights = weights.count
        var known = Set(UserDefaults.standard.stringArray(forKey: weightKeysKey) ?? [])
        let newWeights = weights.filter { !known.contains($0.key) }
        if !newWeights.isEmpty {
            let store = HKHealthStore()
            let type = HKQuantityType(.bodyMass)
            try? await store.requestAuthorization(toShare: [type], read: [type])
            let samples = newWeights.map {
                HKQuantitySample(type: type, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: $0.kg),
                                 start: $0.date, end: $0.date, metadata: ["HealthBridge.caliImport": $0.key])
            }
            try? await store.save(samples)
            newWeights.forEach { known.insert($0.key) }
            UserDefaults.standard.set(Array(known), forKey: weightKeysKey)
        }
        summary.newWeights = newWeights.count
        return summary
    }

    /// Splits one CSV line, honoring quotes and doubled quotes ("נתרן (מ""ג)").
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = Array(line)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { current.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(current); current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }
}
