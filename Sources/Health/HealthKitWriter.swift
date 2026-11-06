import Foundation
import HealthKit

/// Writes daily step counts into Apple Health, tagged with a metadata key so
/// re-running a sync for the same day updates rather than duplicates the entry.
final class HealthKitWriter {
    private let store = HKHealthStore()
    private let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let sourceTag = "StepsBridge.googleHealthDailyTotal"

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitWriterError.notAvailable
        }
        try await store.requestAuthorization(toShare: [stepType], read: [stepType])
    }

    /// Writes one cumulative step sample per day, replacing any sample this
    /// app previously wrote for that same day.
    func write(_ days: [DailySteps]) async throws {
        for day in days {
            try await replaceSample(for: day)
        }
    }

    private func replaceSample(for day: DailySteps) async throws {
        let calendar = Calendar(identifier: .gregorian)
        let startOfDay = calendar.startOfDay(for: day.day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }

        try await deleteExistingSample(start: startOfDay, end: endOfDay)

        let quantity = HKQuantity(unit: .count(), doubleValue: Double(day.stepCount))
        let sample = HKQuantitySample(
            type: stepType,
            quantity: quantity,
            start: startOfDay,
            end: endOfDay,
            metadata: [sourceTag: true]
        )
        try await store.save(sample)
    }

    private func deleteExistingSample(start: Date, end: Date) async throws {
        let dayPredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sourcePredicate = HKQuery.predicateForObjects(withMetadataKey: sourceTag)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [dayPredicate, sourcePredicate])

        let existing: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: stepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }

        guard !existing.isEmpty else { return }
        try await store.delete(existing)
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
