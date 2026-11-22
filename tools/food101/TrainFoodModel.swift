// Trains HealthBridge's on-phone food classifier with Create ML (transfer learning on
// Apple's Vision scene features, so the model itself is tiny and runs on the Neural Engine).
// Usage: swiftc -O TrainFoodModel.swift -o train && ./train <subset dir with train/ and test/> <output .mlmodel>
import CoreGraphics
import CreateML
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Unbuffered, so progress shows up in the CI log as it happens.
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Re-encodes every image as a plain sRGB JPEG of at most 360 px and deletes any image that
/// can't be decoded. Food-101 has a few such files, and one of them crashes Create ML after
/// an hour of feature extraction ("Failed to create CVPixelBufferPool. Width = 0").
/// The smaller images also make feature extraction faster.
func normalize(_ dir: URL) {
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects ?? [])
        .compactMap { $0 as? URL }
        .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 360,
    ] as CFDictionary
    var dropped = 0
    for (index, url) in files.enumerated() {
        let ok: Bool = autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
                  image.width >= 32, image.height >= 32,
                  let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let target = url.deletingPathExtension().appendingPathExtension("jpg")
            guard let rgb = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(destination, rgb, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return false }
            if target != url { try? FileManager.default.removeItem(at: url) }
            return true
        }
        if !ok {
            try? FileManager.default.removeItem(at: url)
            dropped += 1
            log("  dropped unreadable image: \(url.lastPathComponent)")
        }
        if (index + 1) % 2000 == 0 { log("  prepared \(index + 1)/\(files.count) images in \(dir.lastPathComponent)/") }
    }
    log("Prepared \(dir.lastPathComponent)/: \(files.count - dropped) images, \(dropped) dropped")
}

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let trainDir = root.appendingPathComponent("train")
let testDir = root.appendingPathComponent("test")
let started = Date()
func elapsed() -> String { String(format: "%.0f min", Date().timeIntervalSince(started) / 60) }

log("Preparing images…")
normalize(trainDir)
normalize(testDir)

let parameters = MLImageClassifier.ModelParameters(
    validation: .split(strategy: .automatic),
    maxIterations: 100,
    // No augmentation: it multiplies the images to extract features from, and GitHub's
    // virtual Macs have no Neural Engine, so a run with it didn't finish in 2.5 hours.
    augmentation: [],
    algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))

log("Extracting features and training (the long part, no progress output from Create ML)… [\(elapsed())]")
let classifier = try MLImageClassifier(trainingData: .labeledDirectories(at: trainDir), parameters: parameters)
log("Training accuracy: \(1 - classifier.trainingMetrics.classificationError) [\(elapsed())]")
log("Validation accuracy: \(1 - classifier.validationMetrics.classificationError)")

log("Evaluating on unseen test images…")
let test = classifier.evaluation(on: .labeledDirectories(at: testDir))
log("Test accuracy: \(1 - test.classificationError) [\(elapsed())]")

try classifier.write(to: output, metadata: MLModelMetadata(
    author: "HealthBridge (trained on a Food-101 subset, research dataset)",
    shortDescription: "Recognizes 101 dishes from a photo; first guess before Claude confirms.",
    version: "1"))
log("Saved \(output.path)")
