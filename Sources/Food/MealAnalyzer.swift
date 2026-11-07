import Foundation
import Security
import UIKit

/// Which Claude model analyzes meals (chosen in Settings).
enum MealModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }
    static let settingsKey = "mealModel"

    static var current: MealModel {
        MealModel(rawValue: UserDefaults.standard.string(forKey: settingsKey) ?? "") ?? .opus
    }

    var title: String {
        switch self {
        case .opus: return "Claude Opus 5.5 (הכי מדויק)"
        case .sonnet: return "Claude Sonnet 5.5 (מאוזן)"
        case .haiku: return "Claude Haiku 5.5 (הכי מהיר וזול)"
        }
    }

    /// Server-side refusal fallbacks ("default" mode) exist for Opus 5.5 and Sonnet 5.5.
    var supportsFallbacks: Bool { self != .haiku }
}

/// The user's Anthropic API key, kept only in the iPhone Keychain.
enum AnthropicKeyStore {
    private static let service = "com.yanivbahalul.stepsbridge.anthropic"
    private static let account = "apiKey"

    static var key: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum MealAnalyzerError: LocalizedError {
    case noKey, refused, badResponse(String), http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "חסר מפתח API של Anthropic. הוסף אותו בהגדרות ← ניתוח ארוחות."
        case .refused: return "המודל סירב לנתח את הבקשה. נסה צילום אחר או תיאור בטקסט."
        case .badResponse(let s): return "תשובה לא צפויה מהמודל: \(s)"
        case .http(401, _): return "מפתח ה‑API לא תקין. בדוק אותו בהגדרות."
        case .http(402, _), .http(403, _): return "אין קרדיט בחשבון Anthropic, או שהמפתח חסום. בדוק ב‑console.anthropic.com."
        case .http(429, _): return "יותר מדי בקשות. נסה שוב בעוד רגע."
        case .http(let code, let body): return "שגיאה \(code) מ‑Claude: \(body.prefix(200))"
        }
    }
}

/// Sends a meal photo or description to Claude and returns the foods it identifies with
/// estimated eaten grams. Calories are then computed from the Tzameret database where a
/// match is found, which is more accurate than the model's own calorie guess.
enum MealAnalyzer {
    struct Item: Decodable {
        let name_he: String
        let search_terms: [String]
        let grams: Double
        let kcal_per_100g: Double
        let protein_per_100g: Double
        let carbs_per_100g: Double
        let fat_per_100g: Double
    }

    private struct Result: Decodable {
        let items: [Item]
    }

    private static let instructions = """
    אתה עוזר תזונה. זהה כל מאכל ומשקה בארוחה ששלחו לך (בתמונה או בתיאור), והערך כמה גרם נאכלו מכל אחד.
    - name_he: שם קצר בעברית כפי שמקובל בישראל (למשל "שניצל עוף", "אורז לבן מבושל", "סלט ירקות").
    - search_terms: 1–3 מילות חיפוש בעברית למאגר מזון ישראלי, מהכללית לספציפית (למשל ["שניצל", "חזה עוף מטוגן"]).
    - grams: הכמות שנאכלה בגרמים (משקאות במ"ל ≈ גרם). אם בתיאור כתובה כמות ("2 פרוסות", "כוס"), המר לגרמים.
    - ערכים ל‑100 גרם (kcal, protein, carbs, fat): הערכה שלך, לשימוש רק אם המאכל לא יימצא במאגר.
    פרק מנה מורכבת לרכיביה העיקריים (למשל פיתה + פלאפל + חומוס). אל תכלול כלים, מפות או אריזות. אם אין אוכל, החזר רשימה ריקה.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name_he": ["type": "string"],
                        "search_terms": ["type": "array", "items": ["type": "string"]],
                        "grams": ["type": "number"],
                        "kcal_per_100g": ["type": "number"],
                        "protein_per_100g": ["type": "number"],
                        "carbs_per_100g": ["type": "number"],
                        "fat_per_100g": ["type": "number"],
                    ],
                    "required": ["name_he", "search_terms", "grams", "kcal_per_100g",
                                 "protein_per_100g", "carbs_per_100g", "fat_per_100g"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["items"],
        "additionalProperties": false,
    ]

    /// Analyzes a photo, a text description, or both.
    static func analyze(image: UIImage?, text: String?) async throws -> [FoodDraft] {
        guard let key = AnthropicKeyStore.key else { throw MealAnalyzerError.noKey }
        let model = MealModel.current

        var content: [[String: Any]] = []
        if let image, let jpeg = resized(image, maxSide: 1280).jpegData(compressionQuality: 0.8) {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
            ])
        }
        var prompt = instructions
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += "\n\nתיאור הארוחה מהמשתמש: \(text)"
        }
        content.append(["type": "text", "text": prompt])

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            // Low effort: a quick, focused answer (thinking stays on; it can't be disabled on these models).
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": content]],
        ]
        if model.supportsFallbacks { body["fallbacks"] = "default" }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if model.supportsFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else {
            throw MealAnalyzerError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MealAnalyzerError.badResponse("לא JSON")
        }
        if json["stop_reason"] as? String == "refusal" { throw MealAnalyzerError.refused }

        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let resultData = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(Result.self, from: resultData)
        else {
            throw MealAnalyzerError.badResponse(json["stop_reason"] as? String ?? "ללא טקסט")
        }

        let db = FoodDatabase.shared
        return result.items.map { item in
            // Try the model's search terms from most specific to most general, then the name.
            var match: FoodItem?
            for term in item.search_terms.reversed() + [item.name_he] {
                if let found = db.search(term, limit: 1).first { match = found; break }
            }
            return FoodDraft(label: item.name_he, food: match, grams: max(1, item.grams.rounded()),
                             kcalPer100: item.kcal_per_100g, proteinPer100: item.protein_per_100g,
                             carbsPer100: item.carbs_per_100g, fatPer100: item.fat_per_100g)
        }
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Packaged foods by barcode, from the free Open Food Facts database.
enum OpenFoodFacts {
    struct Product {
        let name: String
        let kcal: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let servingGrams: Double?
    }

    static func lookup(barcode: String) async throws -> Product? {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty,
              let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json?fields=product_name,product_name_he,nutriments,serving_quantity")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("HealthBridge/1.0 (personal iOS app)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? NSNumber)?.intValue == 1,
              let product = json["product"] as? [String: Any]
        else { return nil }
        let n = product["nutriments"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Double { GoogleHealthJSON.number(n[key]) ?? 0 }
        let name = (product["product_name_he"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (product["product_name"] as? String) ?? "מוצר \(digits)"
        var kcal = value("energy-kcal_100g")
        if kcal == 0 { kcal = value("energy_100g") / 4.184 }  // kJ → kcal
        return Product(name: name, kcal: kcal, protein: value("proteins_100g"),
                       carbs: value("carbohydrates_100g"), fat: value("fat_100g"),
                       servingGrams: GoogleHealthJSON.number(product["serving_quantity"]))
    }
}
