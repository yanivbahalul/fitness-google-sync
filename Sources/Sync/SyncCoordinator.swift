import Foundation
import HealthKit

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var isSyncing = false
    /// When the last sync finished (shown as "sync completed at ...").
    @Published var lastSyncDate: Date?
    /// Names of data types that failed in the last sync (empty when everything worked).
    @Published var failedTypes: [String] = []
    @Published var lastError: String?
    @Published var needsReconnect = false

    private let auth: GoogleAuthManager
    private let healthClient: GoogleHealthClient
    private let healthKitWriter = HealthKitWriter()

    /// The first sync (or one after a long break) backfills at most this many days.
    private let maxWindowDays = 14
    private static let lastSyncKey = "lastSuccessfulSync"

    init(auth: GoogleAuthManager) {
        self.auth = auth
        self.healthClient = GoogleHealthClient(auth: auth)
        self.lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Start of the window to sync: the start of the day *before* the last sync, which
    /// covers last night's sleep (it starts before midnight) and daily values Google
    /// finalizes late. Synced daily, that's yesterday + today. Never more than 14 days.
    private func windowStart(now: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -maxWindowDays, to: today)!
        guard let last = lastSyncDate else { return earliest }
        let fromLast = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: last))!
        return max(earliest, min(fromLast, today))
    }

    func syncNow() async {
        guard auth.isSignedIn else {
            lastError = "יש להתחבר קודם ל‑Google."
            return
        }
        isSyncing = true
        lastError = nil
        needsReconnect = false
        defer { isSyncing = false }

        let items = SyncCatalog.all
        do {
            try await healthKitWriter.requestAuthorization(toShare: SyncCatalog.shareTypes)
            // Refresh the access token once up front so the parallel requests share it.
            _ = try await auth.validAccessToken()
        } catch {
            lastError = error.localizedDescription
            return
        }

        let now = Date()
        let since = windowStart(now: now)
        let client = healthClient

        // Fetch every data type from Google in parallel.
        var fetched: [Int: Result<[HKSample], Error>] = [:]
        await withTaskGroup(of: (Int, Result<[HKSample], Error>).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await item.fetch(client, since, now)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, result) in group {
                fetched[index] = result
            }
        }

        // Write to Apple Health.
        var failed: [String] = []
        for (index, item) in items.enumerated() {
            do {
                let samples = try fetched[index]!.get()
                try await healthKitWriter.replace(item.hkType, since: since, with: samples)
            } catch {
                if let error = error as? GoogleHealthError, error.isPermissionDenied {
                    needsReconnect = true
                }
                failed.append(item.name)
            }
        }
        failedTypes = failed

        if failed.count < items.count {
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
        } else {
            lastError = "הסנכרון נכשל. בדוק חיבור לאינטרנט, או התנתק והתחבר מחדש ל‑Google."
        }
    }
}
