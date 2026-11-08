import Foundation

/// What started a sync.
enum SyncTrigger: String, Codable {
    case manual, appOpen, background, shortcut

    var title: String {
        switch self {
        case .manual: return "ידני"
        case .appOpen: return "בפתיחת האפליקציה"
        case .background: return "ברקע"
        case .shortcut: return "קיצור דרך"
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "hand.tap.fill"
        case .appOpen: return "iphone"
        case .background: return "moon.zzz.fill"
        case .shortcut: return "square.stack.3d.up.fill"
        }
    }
}

/// One line in the sync log.
struct SyncLogEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let trigger: SyncTrigger
    let rangeTitle: String
    let records: Int
    let syncedTypes: Int
    let failedTypes: [String]
    /// Why the sync stopped, when it did (older entries don't have it).
    var error: String? = nil
    /// Slow-changing types not fetched because they were fetched recently.
    var skippedTypes: Int? = nil
}

/// The last 50 syncs, persisted.
enum SyncHistory {
    private static let key = "syncHistory"

    static func load() -> [SyncLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([SyncLogEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func append(_ entry: SyncLogEntry) -> [SyncLogEntry] {
        let entries = Array(([entry] + load()).prefix(50))
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return entries
    }
}
