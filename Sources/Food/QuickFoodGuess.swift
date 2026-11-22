import CoreML
import UIKit
import Vision

/// Instant first guess of a dish on the phone (Core ML, a few milliseconds on the Neural
/// Engine), shown while Claude is still looking. The model is trained with Create ML on a
/// Food-101 subset (101 common dishes) by .github/workflows/train-food-model.yml and
/// bundled as Sources/Food/FoodClassifier.mlmodel; without it, there is simply no guess.
enum QuickFoodGuess {
    struct Guess {
        let key: String
        let name: String
        let confidence: Float
    }

    private static let model: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "FoodClassifier", withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url) else { return nil }
        return try? VNCoreMLModel(for: ml)
    }()

    /// Food-101 class → [Hebrew name, English (USDA) search term, typical grams].
    private static let names: [String: [Any]] = {
        guard let url = Bundle.main.url(forResource: "food101", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [Any]] else { return [:] }
        return json
    }()

    static var isAvailable: Bool { model != nil }

    /// The most likely dish in `region` (fractions of the image, top-left origin), when the
    /// model is fairly sure.
    static func guess(_ image: UIImage, region: CGRect) -> Guess? {
        guard let model, let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h).integral
        guard let crop = cg.cropping(to: rect) else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        guard let top = (request.results as? [VNClassificationObservation])?.first, top.confidence >= 0.5,
              let name = names[top.identifier]?.first as? String else { return nil }
        return Guess(key: top.identifier, name: name, confidence: top.confidence)
    }

    /// A draft for a guessed dish: values from Tzameret (Hebrew name) or USDA (English
    /// term), a typical portion.
    @MainActor
    static func draft(for guess: Guess) -> FoodDraft {
        let entry = names[guess.key] ?? []
        let english = entry.count > 1 ? entry[1] as? String ?? "" : ""
        let grams = entry.count > 2 ? (entry[2] as? NSNumber)?.doubleValue ?? 150 : 150
        let db = FoodDatabase.shared
        let food = db.search(guess.name, limit: 1).first ?? db.search(english, limit: 1).first
        return FoodDraft(label: guess.name, food: food, grams: grams,
                         kcalPer100: food?.kcal ?? 0, proteinPer100: food?.protein ?? 0,
                         carbsPer100: food?.carbs ?? 0, fatPer100: food?.fat ?? 0,
                         portionNote: "הערכה מהירה, מנה טיפוסית", lowConfidence: guess.confidence < 0.7)
    }
}
