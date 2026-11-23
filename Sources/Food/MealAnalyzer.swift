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
        case .http(500..<600, _), .http(-1, _): return "Claude עמוס כרגע ולא ענה גם אחרי כמה ניסיונות. נסה שוב בעוד דקה."
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
        let name_en: String
        let search_terms: [String]
        let grams: Double
        let kcal_per_100g: Double
        let protein_per_100g: Double
        let carbs_per_100g: Double
        let fat_per_100g: Double
        let portion_note: String
        let confidence: String
        let box: Box
    }

    struct Box: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    private struct Result: Decodable {
        let items: [Item]
    }

    private static let instructions = """
    אתה עוזר תזונה. זהה כל מאכל ומשקה בארוחה ששלחו לך (בתמונה או בתיאור), והערך כמה גרם נאכלו מכל אחד.
    - name_he: שם קצר בעברית כפי שמקובל בישראל (למשל "שניצל עוף", "אורז לבן מבושל", "סלט ירקות").
    - name_en: אותו מאכל באנגלית כפי שמופיע במאגר USDA (למשל "Coffee, brewed", "Rice, white, cooked").
    - search_terms: 1–3 מילות חיפוש בעברית למאגר מזון ישראלי, מהכללית לספציפית (למשל ["שניצל", "חזה עוף מטוגן"]).
    - grams: הכמות שנאכלה בגרמים (משקאות במ"ל ≈ גרם). אם בתיאור כתובה כמות ("2 פרוסות", "כוס"), המר לגרמים. אם לא כתובה כמות, הנח מנה ישראלית טיפוסית וכתוב זאת ב‑portion_note.
    - ערכים ל‑100 גרם (kcal, protein, carbs, fat): הערכה שלך למאכל במצב שבו הוא נאכל (מבושל/מטוגן/אפוי), לשימוש רק אם המאכל לא יימצא במאגר.
    - portion_note: איך הערכת את הכמות, במילים פשוטות (למשל "כ‑1 כוס", "2 פרוסות בינוניות", "חצי צלחת").
    - box: מיקום המאכל בתמונה כשברים בין 0 ל‑1 מגודל התמונה: x,y הפינה השמאלית העליונה, w,h רוחב וגובה. אם אין תמונה, 0,0,0,0.
    - confidence: "high" אם ברור מה זה וכמה, "medium" אם הכמות משוערת, "low" אם לא בטוח מה המאכל או שהוא מוסתר.
    כדי להעריך גודל השתמש בעצמים מוכרים בתמונה: צלחת רגילה כ‑26 ס"מ, מזלג כ‑19 ס"מ, כף כ‑15 מ"ל, כוס כ‑240 מ"ל, כף יד.
    העדף מנות ישראליות טיפוסיות כשאין רמז אחר. שמן, רטבים וממרחים שרואים בתמונה הם פריט נפרד.
    משקאות (קפה, תה, מיץ, שייק, משקה בכוס) הם חלק מהארוחה: זהה אותם, למשל "קפה הפוך" עם כמות במ"ל לפי גודל הכוס.
    תיאור בטקסט חופשי יכול להיות בשפת דיבור, עם סלנג, קיצורים ושגיאות כתיב, ולתאר כמה ארוחות ביום ("בבוקר…, בצהריים…"): הבן אותו כמו אדם והחזר כל מאכל ומשקה שנאכל, כל אחד פעם אחת.
    לכל פריט חובה name_he לא ריק ו‑grams גדול מ‑0. פריט שאינך יכול לזהות אל תכלול.
    פרק מנה מורכבת לרכיביה העיקריים (למשל פיתה + פלאפל + חומוס). אל תכלול כלים, מפות או אריזות. אם אין אוכל, החזר רשימה ריקה.
    בצלחת מעורבת (קערה, מוקפץ, צלחת עם תוספות) תן לכל רכיב שרואים פריט משלו עם כמות משלו, כולל מקורות שומן נראים (שמן, טחינה, רוטב, גבינה מגוררת). מנה אחידה כמו סלט ירקות קצוץ נשארת פריט אחד. אל תאחד שני מאכלים שונים לפריט אחד ואל תפצל מאכל אחד לכמה פריטים.
    עבור כל פריט, box צריך לתחום רק אותו, צמוד ככל האפשר.
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
                        "name_en": ["type": "string"],
                        "search_terms": ["type": "array", "items": ["type": "string"]],
                        "grams": ["type": "number"],
                        "kcal_per_100g": ["type": "number"],
                        "protein_per_100g": ["type": "number"],
                        "carbs_per_100g": ["type": "number"],
                        "fat_per_100g": ["type": "number"],
                        "portion_note": ["type": "string"],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                        "box": [
                            "type": "object",
                            "properties": [
                                "x": ["type": "number"], "y": ["type": "number"],
                                "w": ["type": "number"], "h": ["type": "number"],
                            ],
                            "required": ["x", "y", "w", "h"],
                            "additionalProperties": false,
                        ],
                    ],
                    "required": ["name_he", "name_en", "search_terms", "grams", "kcal_per_100g",
                                 "protein_per_100g", "carbs_per_100g", "fat_per_100g",
                                 "portion_note", "confidence", "box"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["items"],
        "additionalProperties": false,
    ]

    /// Analyzes a photo, a text description, or both. `live` is the quick look while aiming
    /// the camera: the fast model on a smaller frame, a single attempt.
    /// `seenText` is text read on the phone from the image (wrappers, labels); a brand name
    /// there (TWIX) identifies a packaged product better than its look does.
    /// `alreadyAdded` are foods the user already added while aiming; they aren't returned again.
    static func analyze(image: UIImage?, text: String?, live: Bool = false, seenText: [String] = [],
                        alreadyAdded: [String] = []) async throws -> [FoodDraft] {
        guard let key = AnthropicKeyStore.key else { throw MealAnalyzerError.noKey }
        let model = live ? MealModel.haiku : MealModel.current

        var content: [[String: Any]] = []
        if let image, let jpeg = resized(image, maxSide: live ? 512 : 1568).jpegData(compressionQuality: live ? 0.6 : 0.8) {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
            ])
        }
        var prompt = instructions
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += "\n\nתיאור הארוחה מהמשתמש: \(text)"
        }
        if live {
            prompt += "\n\nזו הצצה חיה מהמצלמה בזמן כיוון: החזר רק מזון ומשקאות שרואים בבירור, "
                + "בעיקר במרכז התמונה, שהמשתמש כנראה עומד לאכול. התעלם מחפצים שאינם מזון, ממכשירים "
                + "(מכונת קפה, קומקום), מאריזות סגורות ברקע ומפריטים קטנים או רחוקים שקשה לזהות. "
                + "אם אין מזון ברור, החזר רשימה ריקה. אל תנחש."
        }
        if !alreadyAdded.isEmpty {
            prompt += "\n\nהמשתמש כבר הוסיף מהסריקה: \(alreadyAdded.joined(separator: ", ")). "
                + "הם כבר נספרו: אל תחזיר אותם שוב (גם לא בשם אחר), אלא אם רואים בתמונה מנה נוספת שלהם. החזר רק את שאר מה שבתמונה."
        }
        if !seenText.isEmpty {
            prompt += "\n\nטקסט שזוהה בתמונה (על אריזות ותוויות): \(seenText.joined(separator: ", ")). "
                + "אם זה שם מותג או מוצר, זהה לפיו את המוצר המדויק (למשל TWIX ← טוויקס) ואת ערכיו לפי האריזה."
        }
        content.append(["type": "text", "text": prompt])

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": live ? 2000 : 16000,
            // Photos need a closer look (sizes, hidden items); a text description is quick.
            // Thinking stays on either way (it can't be disabled on these models).
            "output_config": [
                "effort": (live || image == nil) ? "low" : "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": content]],
        ]
        if model.supportsFallbacks { body["fallbacks"] = "default" }
        // The live look-up skips thinking for speed (the fast model allows that at low effort).
        if live { body["thinking"] = ["type": "disabled"] }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = live ? 20 : 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if model.supportsFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request, attempts: live ? 1 : 3)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MealAnalyzerError.badResponse("לא JSON")
        }
        if json["stop_reason"] as? String == "refusal" { throw MealAnalyzerError.refused }

        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let resultData = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(Result.self, from: resultData)
        else {
            #if DEBUG
            print("MealAnalyzer: unreadable response:", String(data: data, encoding: .utf8) ?? "")
            #endif
            if json["stop_reason"] as? String == "max_tokens" {
                throw MealAnalyzerError.badResponse("התשובה נקטעה. נסה צילום עם פחות מאכלים.")
            }
            throw MealAnalyzerError.badResponse(json["stop_reason"] as? String ?? "ללא טקסט")
        }

        // Drop empty items (no name, or no amount and no calories): they can't be logged and
        // only made the screen show "1 g · 0 kcal".
        // In the live look, also drop what the model itself isn't sure of: in a cluttered
        // kitchen that's background guesses (garlic, a carrot) that only crowd the screen.
        let items = result.items.filter {
            !$0.name_he.trimmingCharacters(in: .whitespaces).isEmpty && ($0.grams > 1 || $0.kcal_per_100g > 0)
                && !(live && $0.confidence == "low")
        }
        #if DEBUG
        if items.count != result.items.count { print("MealAnalyzer: dropped empty items:", text) }
        #endif
        return items.map { item in
            let candidates = candidates(for: item)
            return FoodDraft(label: item.name_he, food: bestMatch(in: candidates, estimate: item.kcal_per_100g),
                             grams: max(1, item.grams.rounded()),
                             kcalPer100: item.kcal_per_100g, proteinPer100: item.protein_per_100g,
                             carbsPer100: item.carbs_per_100g, fatPer100: item.fat_per_100g,
                             alternatives: candidates,
                             portionNote: item.portion_note.isEmpty ? nil : item.portion_note,
                             lowConfidence: item.confidence == "low",
                             box: item.box.w > 0.02 && item.box.h > 0.02
                                 ? CGRect(x: min(max(item.box.x, 0), 1), y: min(max(item.box.y, 0), 1),
                                          width: min(item.box.w, 1), height: min(item.box.h, 1))
                                 : nil)
        }
    }

    /// Database foods that could fit: the top results for each of the model's search terms
    /// (most specific first) and its name, without duplicates.
    private static func candidates(for item: Item) -> [FoodItem] {
        var seen = Set<Int>()
        var result: [FoodItem] = []
        // Israeli database first (Hebrew terms), then USDA by the English name.
        for term in item.search_terms.reversed() + [item.name_he, item.name_en] where !term.isEmpty {
            for food in FoodDatabase.shared.search(term, limit: 5) where seen.insert(food.code).inserted {
                result.append(food)
            }
        }
        return Array(result.prefix(12))
    }

    /// The first candidate whose calories are close to the model's own estimate for the
    /// food as eaten. A name match alone can be the wrong form (raw rice vs cooked, dry
    /// pasta vs boiled), which would be far off; then the estimate is used instead and the
    /// candidates stay available to pick by hand.
    private static func bestMatch(in candidates: [FoodItem], estimate: Double) -> FoodItem? {
        guard estimate > 0 else { return candidates.first }
        return candidates.first { food in
            abs(food.kcal - estimate) <= 40 || (0.65...1.5).contains(food.kcal / estimate)
        }
    }

    /// Sends the request, retrying temporary failures (rate limit, overloaded, server error,
    /// dropped connection) up to 3 times with growing waits, honoring `retry-after` and
    /// `x-should-retry`. Most "it didn't work" cases were a single 529/500 or a network blip.
    private static func send(_ request: URLRequest, attempts: Int = 3) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where attempt < attempts && error.code != .cancelled {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                continue
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            if (200...299).contains(code) { return data }

            let retryable = code == 408 || code == 409 || code == 429 || code >= 500
            let serverSaysNo = http?.value(forHTTPHeaderField: "x-should-retry") == "false"
            guard retryable, !serverSaysNo, attempt < attempts else {
                throw MealAnalyzerError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(attempt * 2)
            try await Task.sleep(nanoseconds: UInt64(min(wait, 20) * 1_000_000_000))
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
