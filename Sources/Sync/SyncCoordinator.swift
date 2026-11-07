import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    struct ItemResult: Identifiable {
        let id = UUID()
        let name: String
        let count: Int?
        let error: String?
    }

    @Published var isSyncing = false
    @Published var progress: String?
    @Published var lastSyncDate: Date?
    @Published var syncedFrom: Date?
    @Published var results: [ItemResult] = []
    @Published var lastError: String?
    @Published var needsReconnect = false

    private let auth: GoogleAuthManager
    private let healthClient: GoogleHealthClient
    private let healthKitWriter = HealthKitWriter()

    /// The first sync (and "Full resync") backfills this many days.
    private let fullWindowDays = 14
    private static let lastSyncKey = "lastSuccessfulSync"

    init(auth: GoogleAuthManager) {
        self.auth = auth
        self.healthClient = GoogleHealthClient(auth: auth)
        self.lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    /// Start of the window to (re)sync.
    ///
    /// Normally from the start of the day *before* the last successful sync: that covers
    /// last night's sleep (which starts before midnight) and daily values Google finalizes
    /// late, such as resting heart rate. Never more than `fullWindowDays` back.
    private func windowStart(now: Date, full: Bool) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -fullWindowDays, to: today)!
        guard !full, let last = lastSyncDate else { return earliest }
        let fromLast = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: last))!
        return max(earliest, min(fromLast, today))
    }

    func syncNow(full: Bool = false) async {
        guard auth.isSignedIn else {
            lastError = "Connect your Google account first."
            return
        }
        isSyncing = true
        lastError = nil
        needsReconnect = false
        results = []
        defer { isSyncing = false; progress = nil }

        let items = SyncCatalog.all
        do {
            try await healthKitWriter.requestAuthorization(toShare: SyncCatalog.shareTypes)
        } catch {
            lastError = error.localizedDescription
            return
        }

        let now = Date()
        let since = windowStart(now: now, full: full)
        syncedFrom = since

        for item in items {
            progress = "Syncing \(item.name)…"
            do {
                let samples = try await item.fetch(healthClient, since, now)
                let written = try await healthKitWriter.replace(item.hkType, since: since, with: samples)
                results.append(ItemResult(name: item.name, count: written, error: nil))
            } catch let error as GoogleHealthError where error.isPermissionDenied {
                needsReconnect = true
                results.append(ItemResult(name: item.name, count: nil, error: "No permission"))
            } catch {
                results.append(ItemResult(name: item.name, count: nil, error: error.localizedDescription))
            }
        }
        // Advance the window when the sync worked. (A type that keeps failing, e.g. one Google
        // doesn't provide for your band, shouldn't force a 14-day pull on every tap;
        // "Full resync" is there to backfill after fixing a problem.)
        if results.contains(where: { $0.error == nil }) {
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
        }
    }
}
