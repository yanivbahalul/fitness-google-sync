import Foundation
import HealthKit

/// One Google Health data type → one Apple Health type.
struct SyncItem {
    let name: String
    let hkType: HKSampleType
    /// Fetches from Google Health and converts to HealthKit samples starting at/after `since`.
    let fetch: (_ client: GoogleHealthClient, _ since: Date, _ now: Date) async throws -> [HKSample]
}

/// Everything StepsBridge syncs. Field names follow the Google Health API v4 reference
/// (users.dataTypes.dataPoints). Each item syncs independently, so one failing type
/// (e.g. a scope you didn't grant) doesn't stop the rest.
enum SyncCatalog {
    static let meta: [String: Any] = [HealthKitWriter.metadataKey: true]

    static var all: [SyncItem] {
        [
            // MARK: activity_and_fitness
            intervalSum(name: "Steps", dataType: "steps", key: "steps", field: "count",
                        hk: .stepCount, unit: .count()),
            intervalSum(name: "Distance", dataType: "distance", key: "distance", field: "millimeters",
                        hk: .distanceWalkingRunning, unit: .meter(), scale: 0.001),
            intervalSum(name: "Active energy", dataType: "active-energy-burned", key: "activeEnergyBurned", field: "kcal",
                        hk: .activeEnergyBurned, unit: .kilocalorie()),
            dailyRollUp(name: "Floors", dataType: "floors", valueKey: "floors",
                        hk: .flightsClimbed, unit: .count()),
            samples(name: "VO2 max", dataType: "vo2-max", key: "vo2Max", field: "vo2Max",
                    hk: .vo2Max, unit: HKUnit(from: "ml/kg*min")),
            workouts,

            // MARK: health_metrics_and_measurements
            heartRate,
            daily(name: "Resting heart rate", dataType: "daily-resting-heart-rate", key: "dailyRestingHeartRate",
                  field: "beatsPerMinute", hk: .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute())),
            // Apple Health stores HRV as SDNN; only write it when Google provides the SDNN value.
            samples(name: "HRV (SDNN)", dataType: "heart-rate-variability", key: "heartRateVariability",
                    field: "standardDeviationMilliseconds", hk: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli)),
            samples(name: "Blood oxygen", dataType: "oxygen-saturation", key: "oxygenSaturation", field: "percentage",
                    hk: .oxygenSaturation, unit: .percent(), scale: 0.01),
            daily(name: "Respiratory rate", dataType: "daily-respiratory-rate", key: "dailyRespiratoryRate",
                  field: "breathsPerMinute", hk: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute())),
            samples(name: "Weight", dataType: "weight", key: "weight", field: "weightGrams",
                    hk: .bodyMass, unit: .gram()),
            samples(name: "Body fat", dataType: "body-fat", key: "bodyFat", field: "percentage",
                    hk: .bodyFatPercentage, unit: .percent(), scale: 0.01),
            samples(name: "Height", dataType: "height", key: "height", field: "heightMillimeters",
                    hk: .height, unit: .meter(), scale: 0.001),

            // MARK: sleep
            sleep,

            // MARK: nutrition
            intervalSum(name: "Water", dataType: "hydration-log", key: "hydrationLog", field: "amountConsumed.milliliters",
                        hk: .dietaryWater, unit: .literUnit(with: .milli), hourly: false),
            intervalSum(name: "Dietary energy", dataType: "nutrition-log", key: "nutritionLog", field: "energy.kcal",
                        hk: .dietaryEnergyConsumed, unit: .kilocalorie(), hourly: false),
        ]
    }

    static var shareTypes: Set<HKSampleType> { Set(all.map(\.hkType)) }

    // MARK: - Builders

    /// Reads a possibly nested field such as "amountConsumed.milliliters".
    private static func value(_ dict: [String: Any], _ path: String) -> Double? {
        var current: Any? = dict
        for part in path.split(separator: ".") {
            current = (current as? [String: Any])?[String(part)]
        }
        return GoogleHealthJSON.number(current)
    }

    /// Interval data (e.g. per-minute steps). By default summed into hourly samples so
    /// Apple Health gets a useful graph without tens of thousands of tiny samples.
    private static func intervalSum(name: String, dataType: String, key: String, field: String,
                                    hk id: HKQuantityTypeIdentifier, unit: HKUnit,
                                    scale: Double = 1, hourly: Bool = true) -> SyncItem {
        let type = HKQuantityType(id)
        return SyncItem(name: name, hkType: type) { client, since, now in
            let points = try await client.listPoints(
                dataType: dataType, pointKey: key, since: since,
                timeOf: { GoogleHealthJSON.interval($0)?.start },
                pageSize: hourly ? 10000 : 1000)

            var entries: [(start: Date, end: Date, value: Double)] = []
            for point in points {
                guard let iv = GoogleHealthJSON.interval(point), let v = value(point, field), v > 0 else { continue }
                entries.append((iv.start, iv.end, v * scale))
            }

            if hourly {
                var buckets: [Date: Double] = [:]
                let calendar = Calendar.current
                for e in entries {
                    let hour = calendar.dateInterval(of: .hour, for: e.start)!.start
                    buckets[hour, default: 0] += e.value
                }
                return buckets.map { hour, total in
                    let end = min(hour.addingTimeInterval(3600), max(now, hour.addingTimeInterval(1)))
                    return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: total),
                                            start: hour, end: end, metadata: meta)
                }
            }
            return entries.map {
                HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: $0.value),
                                 start: $0.start, end: max($0.end, $0.start), metadata: meta)
            }
        }
    }

    /// Point-in-time samples (weight, SpO2, VO2 max, ...).
    private static func samples(name: String, dataType: String, key: String, field: String,
                                hk id: HKQuantityTypeIdentifier, unit: HKUnit, scale: Double = 1) -> SyncItem {
        let type = HKQuantityType(id)
        return SyncItem(name: name, hkType: type) { client, since, _ in
            let points = try await client.listPoints(
                dataType: dataType, pointKey: key, since: since,
                timeOf: GoogleHealthJSON.sampleTime)
            return points.compactMap { point in
                guard let time = GoogleHealthJSON.sampleTime(point), let v = value(point, field), v > 0 else { return nil }
                return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: v * scale),
                                        start: time, end: time, metadata: meta)
            }
        }
    }

    /// One value per day (resting heart rate, respiratory rate).
    private static func daily(name: String, dataType: String, key: String, field: String,
                              hk id: HKQuantityTypeIdentifier, unit: HKUnit) -> SyncItem {
        let type = HKQuantityType(id)
        return SyncItem(name: name, hkType: type) { client, since, _ in
            let points = try await client.listPoints(
                dataType: dataType, pointKey: key, since: since,
                timeOf: GoogleHealthJSON.dailyDate, pageSize: 100)
            return points.compactMap { point in
                guard let day = GoogleHealthJSON.dailyDate(point), let v = value(point, field), v > 0 else { return nil }
                return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: v),
                                        start: day, end: day, metadata: meta)
            }
        }
    }

    /// Types only available as rollups (floors): one sample per day.
    private static func dailyRollUp(name: String, dataType: String, valueKey: String,
                                    hk id: HKQuantityTypeIdentifier, unit: HKUnit) -> SyncItem {
        let type = HKQuantityType(id)
        return SyncItem(name: name, hkType: type) { client, since, now in
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
            let days = try await client.dailyRollUp(dataType: dataType, valueKey: valueKey, from: since, to: end)
            return days.compactMap { day, v in
                guard v > 0, let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return nil }
                return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: v),
                                        start: day, end: min(dayEnd, max(now, day)), metadata: meta)
            }
        }
    }

    /// Heart rate samples averaged into 5-minute buckets (raw data can be every few seconds).
    private static var heartRate: SyncItem {
        let type = HKQuantityType(.heartRate)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return SyncItem(name: "Heart rate", hkType: type) { client, since, _ in
            let points = try await client.listPoints(
                dataType: "heart-rate", pointKey: "heartRate", since: since,
                timeOf: GoogleHealthJSON.sampleTime, maxPages: 200)
            var buckets: [Date: (sum: Double, count: Double)] = [:]
            for point in points {
                guard let time = GoogleHealthJSON.sampleTime(point),
                      let v = GoogleHealthJSON.number(point["beatsPerMinute"]), v > 0 else { continue }
                let bucket = Date(timeIntervalSince1970: (time.timeIntervalSince1970 / 300).rounded(.down) * 300)
                let current = buckets[bucket] ?? (0, 0)
                buckets[bucket] = (current.sum + v, current.count + 1)
            }
            return buckets.map { time, agg in
                HKQuantitySample(type: type, quantity: HKQuantity(unit: bpm, doubleValue: (agg.sum / agg.count).rounded()),
                                 start: time, end: time, metadata: meta)
            }
        }
    }

    /// Sleep sessions with stages → Apple Health sleep analysis.
    private static var sleep: SyncItem {
        let type = HKCategoryType(.sleepAnalysis)
        return SyncItem(name: "Sleep", hkType: type) { client, since, _ in
            // Sleep doesn't support dataSourceFamily; reconcile resolves overlapping sessions.
            let sessions = try await client.listPoints(
                dataType: "sleep", pointKey: "sleep", since: since,
                timeOf: { GoogleHealthJSON.interval($0)?.start },
                method: .reconcile, pageSize: 25, includeDataSourceFamily: false)

            var result: [HKSample] = []
            for session in sessions {
                guard let iv = GoogleHealthJSON.interval(session) else { continue }
                result.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                               start: iv.start, end: iv.end, metadata: meta))
                let stages = (session["stages"] as? [[String: Any]]) ?? []
                if stages.isEmpty {
                    result.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                                   start: iv.start, end: iv.end, metadata: meta))
                }
                for stage in stages {
                    guard let start = GoogleHealthJSON.timestamp(stage["startTime"]),
                          let end = GoogleHealthJSON.timestamp(stage["endTime"]), end > start else { continue }
                    let value: HKCategoryValueSleepAnalysis
                    switch stage["type"] as? String {
                    case "AWAKE": value = .awake
                    case "LIGHT": value = .asleepCore
                    case "DEEP": value = .asleepDeep
                    case "REM": value = .asleepREM
                    default: value = .asleepUnspecified // ASLEEP, RESTLESS
                    }
                    result.append(HKCategorySample(type: type, value: value.rawValue, start: start, end: end, metadata: meta))
                }
            }
            return result
        }
    }

    /// Exercise sessions → Apple Health workouts.
    private static var workouts: SyncItem {
        SyncItem(name: "Workouts", hkType: HKObjectType.workoutType()) { client, since, _ in
            let sessions = try await client.listPoints(
                dataType: "exercise", pointKey: "exercise", since: since,
                timeOf: { GoogleHealthJSON.interval($0)?.start },
                pageSize: 25)
            return sessions.compactMap { session -> HKSample? in
                guard let iv = GoogleHealthJSON.interval(session), iv.end > iv.start else { return nil }
                let summary = session["metricsSummary"] as? [String: Any] ?? [:]
                let kcal = GoogleHealthJSON.number(summary["caloriesKcal"])
                let mm = GoogleHealthJSON.number(summary["distanceMillimeters"])
                let duration = GoogleHealthJSON.duration(session["activeDuration"]) ?? iv.end.timeIntervalSince(iv.start)
                var metadata = meta
                if let title = session["displayName"] as? String, !title.isEmpty {
                    metadata[HKMetadataKeyWorkoutBrandName] = title
                }
                return HKWorkout(
                    activityType: activityType(session["exerciseType"] as? String),
                    start: iv.start, end: iv.end, duration: duration,
                    totalEnergyBurned: kcal.map { HKQuantity(unit: .kilocalorie(), doubleValue: $0) },
                    totalDistance: mm.map { HKQuantity(unit: .meter(), doubleValue: $0 / 1000) },
                    metadata: metadata)
            }
        }
    }

    private static func activityType(_ raw: String?) -> HKWorkoutActivityType {
        let t = (raw ?? "").uppercased()
        if t.contains("RUN") || t.contains("TREADMILL") { return .running }
        if t.contains("WALK") { return .walking }
        if t.contains("HIK") { return .hiking }
        if t.contains("BIK") || t.contains("CYCL") || t.contains("SPINNING") { return .cycling }
        if t.contains("SWIM") { return .swimming }
        if t.contains("YOGA") { return .yoga }
        if t.contains("PILATES") { return .pilates }
        if t.contains("ELLIPTICAL") { return .elliptical }
        if t.contains("ROW") { return .rowing }
        if t.contains("WEIGHT") || t.contains("STRENGTH") { return .traditionalStrengthTraining }
        if t.contains("HIIT") || t.contains("INTERVAL") { return .highIntensityIntervalTraining }
        if t.contains("DANC") { return .socialDance }
        if t.contains("TENNIS") { return .tennis }
        if t.contains("SOCCER") || t.contains("FOOTBALL") { return .soccer }
        if t.contains("BASKETBALL") { return .basketball }
        if t.contains("STAIR") { return .stairClimbing }
        return .other
    }
}
