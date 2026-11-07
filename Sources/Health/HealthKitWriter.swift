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

    func requestAuthorization(toShare types: Set<HKSampleType>, read: Set<HKObjectType> = []) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitWriterError.notAvailable
        }
        try await store.requestAuthorization(toShare: types, read: read)
    }

    /// Daily step totals in Apple Health from `start` (local midnight) for `days` days.
    /// `onlyThisApp`: only what HealthBridge wrote; otherwise Apple Health's merged total
    /// (the number the Health app shows, after its source-priority de-duplication).
    func dailySteps(from start: Date, days: Int, onlyThisApp: Bool) async throws -> [Date: Double] {
        let type = HKQuantityType(.stepCount)
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: days, to: start)!
        var predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        if onlyThisApp {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate, HKQuery.predicateForObjects(from: HKSource.default()),
            ])
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var totals: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    totals[stats.startDate] = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                }
                continuation.resume(returning: totals)
            }
            store.execute(query)
        }
    }

    /// Today's total of a cumulative type across all sources (e.g. food logged in a
    /// calorie-tracking app), using Apple Health's source-priority de-duplication.
    func todayTotal(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double {
        let type = HKQuantityType(id)
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, error in
                if let error = error as? HKError, error.code == .errorNoData {
                    continuation.resume(returning: 0)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit) ?? 0)
                }
            }
            store.execute(query)
        }
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
