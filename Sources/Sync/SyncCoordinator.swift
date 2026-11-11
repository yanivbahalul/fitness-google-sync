import Foundation
import HealthKit
import UIKit

/// How far back "Restore history" reaches. The sync button itself always does the daily sync.
enum RestoreRange: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "שבוע"
        case .month: return "חודש"
        case .quarter: return "3 חודשים"
        case .year: return "שנה"
        case .all: return "הכל, מהיום הראשון"
        case .custom: return "מתאריך…"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        case .all, .custom: return nil
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
    /// What a history restore is doing right now ("3/17: steps"), nil otherwise.
    @Published private(set) var restoreStatus: String?

    private let auth: GoogleAuthManager
    private let healthClient: GoogleHealthClient
    private let healthKitWriter = HealthKitWriter()

    private let maxAutomaticDays = 14
    /// Shortcut / background syncs within this time of the last sync are skipped.
    private static let repeatGap: TimeInterval = 5 * 60
    /// Set while a sync runs; still set on the next launch = the sync was cut off
    /// (the app was closed or killed by iOS before it finished).
    private static let inProgressKey = "syncInProgress"
    private var startedAt: Date?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    private static let lastSyncKey = "lastSuccessfulSync"
    private static let perItemKey = "lastSyncPerItem"
    private static let enabledKey = "enabledItems"
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
        if let started = defaults.object(forKey: Self.inProgressKey) as? Date {
            defaults.removeObject(forKey: Self.inProgressKey)
            let triggerRaw = defaults.string(forKey: Self.inProgressKey + ".trigger") ?? ""
            history = SyncHistory.append(SyncLogEntry(
                date: started, trigger: SyncTrigger(rawValue: triggerRaw) ?? .manual, rangeTitle: "",
                records: 0, syncedTypes: 0, failedTypes: [],
                error: "הסנכרון נקטע לפני שהסתיים: האפליקציה נסגרה או ש‑iOS עצר אותה. סנכרן שוב."))
        }
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
    private func windowStart(for item: SyncItem, now: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -maxAutomaticDays, to: today)!
        guard let last = lastSyncPerItem[item.id] ?? lastSyncDate else { return earliest }
        let fromLast = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: last))!
        return max(earliest, min(fromLast, today))
    }

    /// Runs the daily sync, or, with `restoreFrom`, re-syncs everything from that date
    /// (history restore: every type, one at a time to keep memory low).
    @discardableResult
    func syncNow(trigger: SyncTrigger = .manual, restoreFrom: Date? = nil) async -> SyncOutcome {
        var outcome = SyncOutcome()
        let title = restoreFrom.map { "שחזור מ‑\($0.formatted(.dateTime.day().month().year().locale(.he)))" } ?? "יומי"
        guard !isSyncing else {
            outcome.error = "סנכרון כבר מתבצע."
            logSkipped(trigger: trigger, note: "דולג: סנכרון אחר כבר רץ באותו רגע")
            return outcome
        }
        // Apple Health can't be written while the phone is locked. A background wake-up then
        // just waits for the next one (not logged, it would fill the log every hour); a
        // Shortcut run from the lock screen is logged so it's clear why nothing happened.
        if trigger != .manual, trigger != .appOpen, !UIApplication.shared.isProtectedDataAvailable {
            if trigger == .shortcut { logSkipped(trigger: trigger, note: "דולג: הטלפון נעול, Apple Health לא זמין") }
            outcome.note = "הטלפון נעול. פתח אותו ונסה שוב."
            return outcome
        }
        // Shortcuts and background runs right after another sync would fetch the same data.
        if trigger == .shortcut || trigger == .background || trigger == .healthUpdate, let last = lastSyncDate,
           Date().timeIntervalSince(last) < Self.repeatGap {
            let minutes = max(1, Int(Date().timeIntervalSince(last) / 60))
            outcome.note = "סונכרן לפני \(minutes) דק׳, אין צורך לסנכרן שוב."
            logSkipped(trigger: trigger, note: "דולג: סונכרן לפני \(minutes) דק׳")
            return outcome
        }
        guard auth.isSignedIn else {
            outcome.error = "יש להתחבר קודם ל‑Google."
            finish(outcome, trigger: trigger, rangeTitle: "")
            return outcome
        }
        var selected = items.filter(isEnabled)
        guard !selected.isEmpty else {
            outcome.error = "לא נבחר אף סוג נתונים לסנכרון."
            finish(outcome, trigger: trigger, rangeTitle: "")
            return outcome
        }

        isSyncing = true
        progress = 0
        lastError = nil
        needsReconnect = false
        startedAt = Date()
        UserDefaults.standard.set(startedAt, forKey: Self.inProgressKey)
        UserDefaults.standard.set(trigger.rawValue, forKey: Self.inProgressKey + ".trigger")
        // Ask iOS for time to finish if the user leaves the app mid-sync; without this the
        // app is suspended within seconds and the sync never completes or gets logged.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HealthBridge sync") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        defer {
            isSyncing = false
            startedAt = nil
            endBackgroundTask()
        }

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
                finish(outcome, trigger: trigger, rangeTitle: title)
                return outcome
            }
        }

        // Slow-changing types are fetched only when due (a manual sync waits at most an hour).
        // A history restore fetches everything.
        if restoreFrom == nil {
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
            finish(outcome, trigger: trigger, rangeTitle: title)
            return outcome
        }

        let now = Date()
        let windows = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, restoreFrom ?? windowStart(for: $0, now: now)) })
        let client = healthClient
        let total = Double(selected.count * 2) // fetch + write per item

        var fetched: [String: Result<[HKSample], Error>] = [:]
        // Keep today's values from types skipped this time.
        var todaySummary = lastSyncDate.map { Calendar.current.isDate($0, inSameDayAs: now) } == true
            ? (today ?? TodaySummary()) : TodaySummary()

        func fetch(_ item: SyncItem) async {
            let since = windows[item.id]!
            do {
                fetched[item.id] = .success(try await item.fetch(client, since, now))
            } catch {
                fetched[item.id] = .failure(error)
            }
        }

        // Write one type to Apple Health.
        func write(_ item: SyncItem) async {
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
            fetched[item.id] = nil
            progress += 1 / total
        }

        if restoreFrom != nil {
            // History restore: one type at a time, so years of data never sit in memory at once.
            for (index, item) in selected.enumerated() {
                restoreStatus = "\(index + 1) מתוך \(selected.count): \(item.name)"
                await fetch(item)
                progress += 1 / total
                await write(item)
            }
            restoreStatus = nil
        } else {
            // Daily sync: fetch everything from Google in parallel, then write.
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
            for item in selected { await write(item) }
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
        finish(outcome, trigger: trigger, rangeTitle: title)
        return outcome
    }

    /// Restores history from `start`, then runs a daily sync so the last two days are
    /// written minute by minute again (long ranges are written hourly).
    @discardableResult
    func restoreHistory(from start: Date) async -> SyncOutcome {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let outcome = await syncNow(trigger: .manual, restoreFrom: Calendar.current.startOfDay(for: start))
        if outcome.syncedTypes > 0 { await syncNow(trigger: .manual) }
        return outcome
    }

    /// The first day the band recorded steps: looks back a quarter at a time until a whole
    /// year has none (or 2008, before Fitbit-era data). nil if nothing was found.
    func earliestDataDate() async -> Date? {
        let calendar = Calendar.current
        var end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let floor = calendar.date(from: DateComponents(year: 2008, month: 1, day: 1))!
        var earliest: Date?
        var emptyDays = 0
        restoreStatus = "מחפש את היום הראשון עם נתונים…"
        defer { restoreStatus = nil }
        while end > floor, emptyDays < 365 {
            let start = max(floor, calendar.date(byAdding: .day, value: -90, to: end)!)
            guard let days = try? await healthClient.dailyRollUp(dataType: "steps", valueKey: "steps",
                                                                 from: start, to: end, chunkDays: 90) else { break }
            if let first = days.filter({ $0.value > 0 }).map(\.day).min() {
                earliest = first
                emptyDays = 0
            } else {
                emptyDays += 90
            }
            end = start
        }
        return earliest
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
        UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
        history = SyncHistory.append(SyncLogEntry(
            date: startedAt ?? Date(), trigger: trigger, rangeTitle: rangeTitle,
            records: outcome.records, syncedTypes: outcome.syncedTypes, failedTypes: outcome.failedTypes,
            error: outcome.error, skippedTypes: outcome.skippedTypes,
            duration: startedAt.map { Date().timeIntervalSince($0) }))

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

    /// Records a sync request that didn't run, so every tap shows up in the log.
    private func logSkipped(trigger: SyncTrigger, note: String) {
        history = SyncHistory.append(SyncLogEntry(
            date: Date(), trigger: trigger, rangeTitle: "", records: 0, syncedTypes: 0,
            failedTypes: [], note: note))
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
