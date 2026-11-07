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
    @Published var results: [ItemResult] = []
    @Published var lastError: String?
    @Published var needsReconnect = false

    private let auth: GoogleAuthManager
    private let healthClient: GoogleHealthClient
    private let healthKitWriter = HealthKitWriter()

    /// How many trailing days to pull on each manual sync. 14 gives enough
    /// overlap to backfill days you forgot to open the app.
    private let syncWindowDays = 14

    init(auth: GoogleAuthManager) {
        self.auth = auth
        self.healthClient = GoogleHealthClient(auth: auth)
    }

    func syncNow() async {
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
        let since = Calendar.current.date(byAdding: .day, value: -syncWindowDays, to: Calendar.current.startOfDay(for: now))!

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
        lastSyncDate = Date()
    }
}
