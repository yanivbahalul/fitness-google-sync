import Foundation

/// What started a sync.
enum SyncTrigger: String, Codable {
    case manual, appOpen, background, shortcut, healthUpdate

    var title: String {
        switch self {
        case .manual: return "ידני"
        case .appOpen: return "בפתיחת האפליקציה"
        case .background: return "ברקע"
        case .shortcut: return "קיצור דרך"
        case .healthUpdate: return "צעדים חדשים ב‑Apple Health"
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "hand.tap.fill"
        case .appOpen: return "iphone"
        case .background: return "moon.zzz.fill"
        case .shortcut: return "square.stack.3d.up.fill"
        case .healthUpdate: return "heart.text.square.fill"
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
    /// Why nothing was fetched although a sync was requested (e.g. one had just finished).
    var note: String? = nil
    /// How long the sync took, in seconds.
    var duration: Double? = nil
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
