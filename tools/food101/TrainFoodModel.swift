// Trains HealthBridge's on-phone food classifier with Create ML (transfer learning on
// Apple's Vision scene features, so the model itself is tiny and runs on the Neural Engine).
// Usage: swift TrainFoodModel.swift <subset dir with train/ and test/> <output .mlmodel>
import CreateML
import Foundation

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

let parameters = MLImageClassifier.ModelParameters(
    validation: .split(strategy: .automatic),
    maxIterations: 100,
    augmentation: [.flip, .crop],
    algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))

let classifier = try MLImageClassifier(
    trainingData: .labeledDirectories(at: root.appendingPathComponent("train")), parameters: parameters)
print("Training accuracy:", 1 - classifier.trainingMetrics.classificationError)
print("Validation accuracy:", 1 - classifier.validationMetrics.classificationError)
let test = classifier.evaluation(on: .labeledDirectories(at: root.appendingPathComponent("test")))
print("Test accuracy:", 1 - test.classificationError)

try classifier.write(to: output, metadata: MLModelMetadata(
    author: "HealthBridge (trained on a Food-101 subset, research dataset)",
    shortDescription: "Recognizes 101 dishes from a photo; first guess before Claude confirms.",
    version: "1"))
print("Saved", output.path)
