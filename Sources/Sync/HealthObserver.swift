import HealthKit
import UIKit

/// A background trigger that needs no server: Apple Health wakes HealthBridge when the
/// iPhone records new steps (iOS allows this at most hourly for steps), and HealthBridge
/// then runs the daily sync from Google. Only steps written by other sources (the iPhone,
/// a watch) count, so HealthBridge's own writes never trigger another sync.
@MainActor
enum HealthObserver {
    private static let store = HKHealthStore()
    private static let anchorKey = "healthObserverAnchor"
    private static var query: HKObserverQuery?

    /// Call at every launch: iOS relaunches the app in the background for these updates and
    /// the observer has to be registered again each time. Also call when the setting changes.
    static func update() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let type = HKQuantityType(.stepCount)
        if AppSettings.backgroundSync {
            guard query == nil else { return }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    if await hasNewStepsFromOtherSources() {
                        _ = await AppState.sync.syncNow(trigger: .healthUpdate)
                    }
                    completion()
                }
            }
            query = observer
            store.execute(observer)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        } else if let observer = query {
            store.stop(observer)
            query = nil
            store.disableBackgroundDelivery(for: type) { _, _ in }
        }
    }

    /// True when steps from another source were added since the last check.
    private static func hasNewStepsFromOtherSources() async -> Bool {
        let anchor = UserDefaults.standard.data(forKey: anchorKey)
            .flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-2 * 86400), end: nil, options: []),
            NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default())),
        ])
        return await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: HKQuantityType(.stepCount), predicate: predicate,
                                              anchor: anchor, limit: HKObjectQueryNoLimit) { _, added, _, newAnchor, error in
                if let newAnchor,
                   let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: anchorKey)
                }
                continuation.resume(returning: error == nil && !(added ?? []).isEmpty)
            }
            store.execute(query)
        }
    }
}
