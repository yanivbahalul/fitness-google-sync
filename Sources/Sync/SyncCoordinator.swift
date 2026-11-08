import Foundation
import HealthKit

/// How far back a sync reaches.
enum SyncRange: String, CaseIterable, Identifiable {
    case automatic, days3, days7, days14, days30, days90
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "אוטומטי"
        case .days3: return "3 ימים"
        case .days7: return "שבוע"
        case .days14: return "14 יום"
        case .days30: return "30 יום"
        case .days90: return "90 יום"
        }
    }

    var days: Int? {
        switch self {
        case .automatic: return nil
        case .days3: return 3
        case .days7: return 7
        case .days14: return 14
        case .days30: return 30
        case .days90: return 90
        }
    }
}

/// Result of the last sync for one data type.
enum ItemStatus: Equatable {
    case synced(count: Int)
    case failed(message: String)
}

/// Summary of one sync run (used for the Shortcuts reply and notifications).
struct SyncOutcome {
    var syncedTypes = 0
    var failedTypes: [String] = []
    var records = 0
    /// Types not fetched this time because they were fetched recently (see refreshInterval).
    var skippedTypes = 0
    var error: String?
    /// Set when the sync didn't run because one just finished.
    var note: String?

    var summary: String {
        if let error { return error }
        if let note { return note }
        if failedTypes.isEmpty { return "הסנכרון הושלם: \(syncedTypes) סוגי נתונים, \(records) רשומות." }
        return "סונכרנו \(syncedTypes) סוגי נתונים. לא סונכרנו: \(failedTypes.joined(separator: ", "))."
    }
}

/// Today's highlights, computed from the data written in the last sync.
struct TodaySummary: Codable, Equatable {
    var steps: Int?
    var sleepMinutes: Int?
    var restingHeartRate: Int?
    var activeKcal: Int?
    /// Time of the latest band data Google had at the last sync (how fresh the numbers are).
    var dataThrough: Date?
}

@MainActor
final class SyncCoordinator: ObservableObject {
    let items = SyncCatalog.all

    @Published var isSyncing = false
    /// Fraction done (0...1) while syncing.
    @Published var progress: Double = 0
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var needsReconnect = false
    @Published private(set) var status: [String: ItemStatus] = [:]
    @Published private(set) var history: [SyncLogEntry] = SyncHistory.load()
    @Published private(set) var today: TodaySummary?

    /// Which data types are switched on (persisted).
    @Published var enabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabled), forKey: Self.enabledKey) }
    }
    @Published var range: SyncRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: Self.rangeKey) }
    }

    private let auth: GoogleAuthManager
    private let healthClient: GoogleHealthClient
    private let healthKitWriter = HealthKitWriter()

    private let maxAutomaticDays = 14
    /// Shortcut / background syncs within this time of the last sync are skipped.
    private static let repeatGap: TimeInterval = 5 * 60
    private static let lastSyncKey = "lastSuccessfulSync"
    private static let perItemKey = "lastSyncPerItem"
    private static let enabledKey = "enabledItems"
    private static let rangeKey = "syncRange"
    private static let todayKey = "todaySummary"

    /// Last successful sync per data type (HealthKit identifier → date).
    private var lastSyncPerItem: [String: Date] {
        didSet { UserDefaults.standard.set(lastSyncPerItem, forKey: Self.perItemKey) }
    }

    init(auth: GoogleAuthManager) {
        self.auth = auth
        self.healthClient = GoogleHealthClient(auth: auth)
        let defaults = UserDefaults.standard
        self.lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date
        self.lastSyncPerItem = defaults.dictionary(forKey: Self.perItemKey) as? [String: Date] ?? [:]
        if let saved = defaults.array(forKey: Self.enabledKey) as? [String] {
            self.enabled = Set(saved)
        } else {
            self.enabled = Set(SyncCatalog.all.map(\.id)).subtracting(SyncCatalog.offByDefault)
        }
        self.range = SyncRange(rawValue: defaults.string(forKey: Self.rangeKey) ?? "") ?? .automatic
        if let data = defaults.data(forKey: Self.todayKey),
           let saved = try? JSONDecoder().decode(TodaySummary.self, from: data),
           let last = lastSyncDate, Calendar.current.isDateInToday(last) {
            self.today = saved
        }
    }

    // MARK: - Selection helpers

    func items(in category: SyncCategory) -> [SyncItem] {
        items.filter { $0.category == category }
    }

    func isEnabled(_ item: SyncItem) -> Bool { enabled.contains(item.id) }

    func setEnabled(_ item: SyncItem, _ on: Bool) {
        if on { enabled.insert(item.id) } else { enabled.remove(item.id) }
    }

    func allEnabled(in category: SyncCategory) -> Bool {
        items(in: category).allSatisfy(isEnabled)
    }

    func setAll(in category: SyncCategory, _ on: Bool) {
        for item in items(in: category) { setEnabled(item, on) }
    }

    func status(for item: SyncItem) -> ItemStatus? { status[item.id] }

    var enabledCount: Int { items.filter(isEnabled).count }

    // MARK: - Sync

    /// Start of the window for one item.
    ///
    /// Automatic: from the start of the day before that item's last sync (covers last
    /// night's sleep and late-finalized daily values; synced daily = yesterday + today),
    /// so switching a type back on catches up the days it missed. At most 14 days.
    private func windowStart(for item: SyncItem, now: Date, range: SyncRange) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if let days = range.days {
            return calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        }
        let earliest = calendar.date(byAdding: .day, value: -maxAutomaticDays, to: today)!
        guard let last = lastSyncPerItem[item.id] ?? lastSyncDate else { return earliest }
        let fromLast = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: last))!
        return max(earliest, min(fromLast, today))
    }

    /// Runs a sync. Automatic triggers (app open, background, Shortcuts) always use the
    /// automatic range; the range picker applies to manual syncs.
    @discardableResult
    func syncNow(trigger: SyncTrigger = .manual) async -> SyncOutcome {
        var outcome = SyncOutcome()
        guard !isSyncing else {
            outcome.error = "סנכרון כבר מתבצע."
            return outcome
        }
        // Shortcuts and background runs right after another sync would fetch the same data.
        if trigger == .shortcut || trigger == .background, let last = lastSyncDate,
           Date().timeIntervalSince(last) < Self.repeatGap {
            let minutes = max(1, Int(Date().timeIntervalSince(last) / 60))
            outcome.note = "סונכרן לפני \(minutes) דק׳, אין צורך לסנכרן שוב."
            return outcome
        }
        guard auth.isSignedIn else {
            outcome.error = "יש להתחבר קודם ל‑Google."
            if trigger == .manual { lastError = outcome.error }
            return outcome
        }
        var selected = items.filter(isEnabled)
        guard !selected.isEmpty else {
            outcome.error = "לא נבחר אף סוג נתונים לסנכרון."
            if trigger == .manual { lastError = outcome.error }
            return outcome
        }

        isSyncing = true
        progress = 0
        lastError = nil
        needsReconnect = false
        defer { isSyncing = false }

        let effectiveRange = trigger == .manual ? range : .automatic

        // Asking for Apple Health permission shows a sheet, which iOS doesn't allow while the
        // app runs in the background (Shortcuts, background refresh). Only ask in the
        // foreground; otherwise sync the types that are already allowed.
        if trigger == .manual || trigger == .appOpen {
            await HealthAuthorization.request()
        } else {
            let allowed = selected.filter { healthKitWriter.store.authorizationStatus(for: $0.hkType) == .sharingAuthorized }
            for item in selected where !allowed.contains(where: { $0.id == item.id }) {
                status[item.id] = .failed(message: "אין הרשאה ב‑Apple Health")
                outcome.failedTypes.append(item.name)
            }
            selected = allowed
            guard !selected.isEmpty else {
                outcome.error = "אין הרשאת כתיבה ל‑Apple Health. פתח את האפליקציה ואשר הרשאות."
                finish(outcome, trigger: trigger, rangeTitle: effectiveRange.title)
                return outcome
            }
        }

        // Slow-changing types are fetched only when due. A manual sync with a chosen range
        // always fetches everything; a manual sync on the automatic range waits at most an hour.
        if effectiveRange == .automatic {
            let now = Date()
            let due = selected.filter { item in
                guard item.refreshInterval > 0, let last = lastSyncPerItem[item.id] else { return true }
                let interval = trigger == .manual ? min(item.refreshInterval, 3600) : item.refreshInterval
                return now.timeIntervalSince(last) >= interval
            }
            if !due.isEmpty {
                outcome.skippedTypes = selected.count - due.count
                selected = due
            }
        }

        do {
            // Refresh the access token once up front so the parallel requests share it.
            _ = try await auth.validAccessToken()
        } catch {
            if let authError = error as? AuthError, case .http = authError { needsReconnect = true }
            outcome.error = "לא ניתן להתחבר ל‑Google: \(error.localizedDescription)"
            finish(outcome, trigger: trigger, rangeTitle: effectiveRange.title)
            return outcome
        }

        let now = Date()
        let windows = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, windowStart(for: $0, now: now, range: effectiveRange)) })
        let client = healthClient
        let total = Double(selected.count * 2) // fetch + write per item

        // Fetch from Google in parallel.
        var fetched: [String: Result<[HKSample], Error>] = [:]
        await withTaskGroup(of: (String, Result<[HKSample], Error>).self) { group in
            for item in selected {
                let since = windows[item.id]!
                group.addTask {
                    do {
                        return (item.id, .success(try await item.fetch(client, since, now)))
                    } catch {
                        return (item.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                fetched[id] = result
                progress += 1 / total
            }
        }

        // Write to Apple Health.
        // Keep today's values from types skipped this time.
        var todaySummary = lastSyncDate.map { Calendar.current.isDate($0, inSameDayAs: now) } == true
            ? (today ?? TodaySummary()) : TodaySummary()
        for item in selected {
            do {
                let samples = try fetched[item.id]!.get()
                let written = try await healthKitWriter.replace(item.hkType, since: windows[item.id]!, with: samples)
                status[item.id] = .synced(count: written)
                lastSyncPerItem[item.id] = now
                outcome.syncedTypes += 1
                outcome.records += written
                Self.addToToday(&todaySummary, item: item, samples: samples, now: now)
            } catch {
                if let error = error as? GoogleHealthError, error.isPermissionDenied {
                    needsReconnect = true
                    status[item.id] = .failed(message: "אין הרשאה")
                } else {
                    status[item.id] = .failed(message: "נכשל")
                }
                outcome.failedTypes.append(item.name)
            }
            progress += 1 / total
        }

        if outcome.syncedTypes > 0 {
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            today = todaySummary
            if let data = try? JSONEncoder().encode(todaySummary) {
                UserDefaults.standard.set(data, forKey: Self.todayKey)
            }
        } else {
            outcome.error = "הסנכרון נכשל. בדוק חיבור לאינטרנט, או התנתק והתחבר מחדש ל‑Google."
        }
        finish(outcome, trigger: trigger, rangeTitle: effectiveRange.title)
        return outcome
    }

    /// Calories burned on one day (Google total calories: resting + active, as the band
    /// shows). Today's value is "so far".
    func burned(on day: Date) async -> Int? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: Date())
        let days = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        guard days >= 1 else { return nil }
        return await dailyBurned(days: days)[start].map { Int(safe: $0.rounded()) }
    }

    /// Total calories burned per day (resting + active) from Google Health, cached on the
    /// device; recent days are always refreshed because today's value keeps growing.
    func dailyBurned(days: Int) async -> [Date: Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        var cache: [Date: Double] = [:]
        if let saved = UserDefaults.standard.dictionary(forKey: "burnedCache") as? [String: Double] {
            for (k, v) in saved { if let t = Double(k) { cache[Date(timeIntervalSince1970: t)] = v } }
        }
        let refreshFrom = calendar.date(byAdding: .day, value: -2, to: today)!
        let missing = (0..<days).map { calendar.date(byAdding: .day, value: $0, to: start)! }
            .filter { $0 >= refreshFrom || cache[$0] == nil }
        if let first = missing.min(), auth.isSignedIn {
            let end = calendar.date(byAdding: .day, value: 1, to: today)!
            if let fetched = try? await healthClient.dailyRollUp(dataType: "total-calories", valueKey: "totalCalories",
                                                                 from: first, to: end, chunkDays: 14) {
                // Ignore impossible values (e.g. an unexpected unit) rather than show nonsense.
                for (day, value) in fetched where value > 0 && value < 20000 { cache[day] = value }
                var out: [String: Double] = [:]
                for (k, v) in cache { out[String(k.timeIntervalSince1970)] = v }
                UserDefaults.standard.set(out, forKey: "burnedCache")
            }
        }
        return cache.filter { $0.key >= start }
    }

    private func finish(_ outcome: SyncOutcome, trigger: SyncTrigger, rangeTitle: String) {
        if trigger == .manual || trigger == .appOpen {
            lastError = outcome.error
        }
        history = SyncHistory.append(SyncLogEntry(
            date: Date(), trigger: trigger, rangeTitle: rangeTitle,
            records: outcome.records, syncedTypes: outcome.syncedTypes, failedTypes: outcome.failedTypes,
            error: outcome.error, skippedTypes: outcome.skippedTypes))

        // Tell the user about problems in syncs they didn't start by hand.
        guard trigger != .manual, AppSettings.notifyProblems else { return }
        if needsReconnect {
            Notifier.notify(title: "HealthBridge צריך חיבור מחדש",
                            body: "פתח את האפליקציה, התנתק והתחבר מחדש ל‑Google כדי שהסנכרון ימשיך.",
                            id: "reconnect")
        } else if let error = outcome.error {
            Notifier.notify(title: "הסנכרון של HealthBridge נכשל", body: error, id: "sync-failed")
        }
    }

    private static func addToToday(_ summary: inout TodaySummary, item: SyncItem, samples: [HKSample], now: Date) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let todays = samples.compactMap { $0 as? HKQuantitySample }.filter { $0.startDate >= startOfToday }

        // Freshness: the latest heart-rate reading (every few minutes while worn) or step hour.
        if item.hkType.identifier == HKQuantityTypeIdentifier.heartRate.rawValue
            || item.hkType.identifier == HKQuantityTypeIdentifier.stepCount.rawValue,
           let latest = todays.map(\.startDate).max() {
            summary.dataThrough = max(summary.dataThrough ?? latest, latest)
        }

        switch item.hkType.identifier {
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            summary.steps = Int(safe: todays.reduce(0) { $0 + $1.quantity.doubleValue(for: .count()) })
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            summary.activeKcal = Int(safe: todays.reduce(0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) })
        case HKQuantityTypeIdentifier.restingHeartRate.rawValue:
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let all = samples.compactMap { $0 as? HKQuantitySample }.sorted { $0.startDate > $1.startDate }
            if let latest = all.first { summary.restingHeartRate = Int(safe: latest.quantity.doubleValue(for: bpm)) }
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            // Last night: asleep stages that ended after yesterday 18:00.
            let cutoff = calendar.date(byAdding: .hour, value: -6, to: startOfToday)!
            let asleep: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            ]
            let seconds = samples.compactMap { $0 as? HKCategorySample }
                .filter { asleep.contains($0.value) && $0.endDate > cutoff }
                .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            if seconds > 0 { summary.sleepMinutes = Int(safe: seconds / 60) }
        default:
            break
        }
    }

    // MARK: - Steps check

    struct StepsDay: Identifiable {
        let day: Date
        let google: Int
        let stepsBridge: Int
        let appleHealth: Int
        var id: Date { day }
        var matches: Bool { google == stepsBridge }
    }

    /// Compares, per day, Google Health's daily total with what HealthBridge wrote and with
    /// Apple Health's displayed total.
    func stepsComparison(days: Int = 7) async throws -> [StepsDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!

        await HealthAuthorization.request()
        let google = try await healthClient.dailyRollUp(dataType: "steps", valueKey: "steps", from: start, to: end)
        let googleByDay = Dictionary(google.map { ($0.day, $0.value) }, uniquingKeysWith: +)
        let mine = try await healthKitWriter.dailySteps(from: start, days: days, onlyThisApp: true)
        let merged = try await healthKitWriter.dailySteps(from: start, days: days, onlyThisApp: false)

        return (0..<days).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return StepsDay(day: day,
                            google: Int(safe: (googleByDay[day] ?? 0).rounded()),
                            stepsBridge: Int(safe: (mine[day] ?? 0).rounded()),
                            appleHealth: Int(safe: (merged[day] ?? 0).rounded()))
        }
    }
}
