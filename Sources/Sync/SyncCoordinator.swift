import Foundation
import HealthKit

/// How far back a sync reaches.
enum SyncRange: String, CaseIterable, Identifiable {
    case automatic, days3, days7, days14
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "אוטומטי"
        case .days3: return "3 ימים"
        case .days7: return "שבוע"
        case .days14: return "14 יום"
        }
    }

    var days: Int? {
        switch self {
        case .automatic: return nil
        case .days3: return 3
        case .days7: return 7
        case .days14: return 14
        }
    }
}

/// Result of the last sync for one data type.
enum ItemStatus: Equatable {
    case synced(count: Int)
    case failed(message: String)
}

@MainActor
final class SyncCoordinator: ObservableObject {
    let items = SyncCatalog.all

    @Published var isSyncing = false
    /// Fraction done (0...1) while syncing.
    @Published var progress: Double = 0
    /// When the last sync finished.
    @Published var lastSyncDate: Date?
    @Published var lastError: String?
    @Published var needsReconnect = false
    @Published private(set) var status: [String: ItemStatus] = [:]

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

    private let maxWindowDays = 14
    private static let lastSyncKey = "lastSuccessfulSync"
    private static let perItemKey = "lastSyncPerItem"
    private static let enabledKey = "enabledItems"
    private static let rangeKey = "syncRange"

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
            self.enabled = Set(SyncCatalog.all.map(\.id))
        }
        self.range = SyncRange(rawValue: defaults.string(forKey: Self.rangeKey) ?? "") ?? .automatic
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
    /// so switching a type back on catches up the days it missed. Never more than 14 days.
    private func windowStart(for item: SyncItem, now: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if let days = range.days {
            return calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        }
        let earliest = calendar.date(byAdding: .day, value: -maxWindowDays, to: today)!
        guard let last = lastSyncPerItem[item.id] ?? lastSyncDate else { return earliest }
        let fromLast = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: last))!
        return max(earliest, min(fromLast, today))
    }

    func syncNow() async {
        guard auth.isSignedIn else {
            lastError = "יש להתחבר קודם ל‑Google."
            return
        }
        let selected = items.filter(isEnabled)
        guard !selected.isEmpty else {
            lastError = "לא נבחר אף סוג נתונים לסנכרון."
            return
        }

        isSyncing = true
        progress = 0
        lastError = nil
        needsReconnect = false
        defer { isSyncing = false }

        do {
            try await healthKitWriter.requestAuthorization(toShare: Set(selected.map(\.hkType)))
            // Refresh the access token once up front so the parallel requests share it.
            _ = try await auth.validAccessToken()
        } catch {
            lastError = error.localizedDescription
            return
        }

        let now = Date()
        let windows = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, windowStart(for: $0, now: now)) })
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
        var succeeded = 0
        for item in selected {
            do {
                let samples = try fetched[item.id]!.get()
                let written = try await healthKitWriter.replace(item.hkType, since: windows[item.id]!, with: samples)
                status[item.id] = .synced(count: written)
                lastSyncPerItem[item.id] = now
                succeeded += 1
            } catch {
                if let error = error as? GoogleHealthError, error.isPermissionDenied {
                    needsReconnect = true
                    status[item.id] = .failed(message: "אין הרשאה")
                } else {
                    status[item.id] = .failed(message: "נכשל")
                }
            }
            progress += 1 / total
        }

        if succeeded > 0 {
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
        } else {
            lastError = "הסנכרון נכשל. בדוק חיבור לאינטרנט, או התנתק והתחבר מחדש ל‑Google."
        }
    }
}
