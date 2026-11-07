import Foundation
import HealthKit

/// Writes synced data into Apple Health.
///
/// Every sync replaces what this app previously wrote for the sync window: for each
/// type it deletes this app's own samples (HealthKit only lets an app delete what it
/// wrote) starting at the window start, then saves the fresh samples. Re-syncing
/// therefore never duplicates data.
final class HealthKitWriter {
    let store = HKHealthStore()
    static let metadataKey = "StepsBridge.googleHealth"

    func requestAuthorization(toShare types: Set<HKSampleType>) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitWriterError.notAvailable
        }
        try await store.requestAuthorization(toShare: types, read: [])
    }

    /// Replaces this app's samples of `type` that start on/after `since` with `samples`.
    /// Returns how many samples were written.
    @discardableResult
    func replace(_ type: HKSampleType, since: Date, with samples: [HKSample]) async throws -> Int {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate),
        ])
        try await deleteObjects(of: type, matching: predicate)

        // Save in chunks to keep individual HealthKit transactions small.
        let chunkSize = 2000
        var index = 0
        while index < samples.count {
            let chunk = Array(samples[index..<min(index + chunkSize, samples.count)])
            try await store.save(chunk)
            index += chunkSize
        }
        return samples.count
    }

    private func deleteObjects(of type: HKObjectType, matching predicate: NSPredicate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                // "No data" is reported as an error by some iOS versions; ignore it.
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

enum HealthKitWriterError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Health data is not available on this device."
        }
    }
}
