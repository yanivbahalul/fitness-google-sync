import Foundation

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastSyncSummary: String?
    @Published var lastError: String?

    private let auth: GoogleAuthManager
    private let healthClient: GoogleHealthClient
    private let healthKitWriter = HealthKitWriter()

    /// How many trailing days to pull on each manual sync. 14 gives enough
    /// overlap to backfill a day you forgot to open the app on.
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
        defer { isSyncing = false }

        do {
            try await healthKitWriter.requestAuthorization()

            let calendar = Calendar(identifier: .gregorian)
            let end = calendar.startOfDay(for: Date()).addingTimeInterval(86400) // through today
            guard let start = calendar.date(byAdding: .day, value: -syncWindowDays, to: end) else { return }

            let days = try await healthClient.dailySteps(from: start, to: end)
            try await healthKitWriter.write(days)

            lastSyncDate = Date()
            let total = days.reduce(0) { $0 + $1.stepCount }
            lastSyncSummary = "Synced \(days.count) day(s), \(total) total steps."
        } catch {
            lastError = error.localizedDescription
        }
    }
}
