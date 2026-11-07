import Foundation

/// Thin client for the Google Health API (v4).
///
/// Endpoints and field names follow developers.google.com/health/endpoints and
/// developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints:
///   GET  /v4/users/me/dataTypes/{type}/dataPoints            (list, newest first)
///   GET  /v4/users/me/dataTypes/{type}/dataPoints:reconcile  (list with overlaps resolved)
///   POST /v4/users/me/dataTypes/{type}/dataPoints:dailyRollUp
///
/// Responses are parsed loosely (as JSON dictionaries) because the API is new and some
/// fields are string-encoded numbers; see GoogleHealthJSON for the helpers.
final class GoogleHealthClient {
    private let auth: GoogleAuthManager
    private let base = "https://health.googleapis.com/v4/users/me/dataTypes/"
    private let dataSourceFamily = "users/me/dataSourceFamilies/google-sources"

    init(auth: GoogleAuthManager) {
        self.auth = auth
    }

    enum ListMethod: String {
        case list = ""
        case reconcile = ":reconcile"
    }

    /// Lists raw data points of `dataType` newer than `since`, returning the inner value
    /// object stored under `pointKey` (e.g. "weight") of each data point.
    func listPoints(
        dataType: String,
        pointKey: String,
        since: Date,
        timeOf: @escaping ([String: Any]) -> Date?,
        method: ListMethod = .list,
        pageSize: Int = 10000,
        includeDataSourceFamily: Bool = true,
        maxPages: Int = 60
    ) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        try await forEachPoint(dataType: dataType, pointKey: pointKey, since: since, timeOf: timeOf,
                               method: method, pageSize: pageSize,
                               includeDataSourceFamily: includeDataSourceFamily, maxPages: maxPages) {
            results.append($0)
        }
        return results
    }

    /// Streams data points newer than `since` to `handle`, page by page, so large data sets
    /// (e.g. second-by-second heart rate) never have to sit in memory at once.
    ///
    /// No server-side filter is sent: results come back newest-first, so paging stops as
    /// soon as a page reaches data older than `since`.
    func forEachPoint(
        dataType: String,
        pointKey: String,
        since: Date,
        timeOf: @escaping ([String: Any]) -> Date?,
        method: ListMethod = .list,
        pageSize: Int = 10000,
        includeDataSourceFamily: Bool = true,
        maxPages: Int = 60,
        handle: ([String: Any]) -> Void
    ) async throws {
        var pageToken: String?

        for _ in 0..<maxPages {
            var components = URLComponents(string: base + dataType + "/dataPoints" + method.rawValue)!
            var query = [URLQueryItem(name: "pageSize", value: String(pageSize))]
            if includeDataSourceFamily {
                query.append(URLQueryItem(name: "dataSourceFamily", value: dataSourceFamily))
            }
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = query

            let json = try await send(URLRequest(url: components.url!))
            let points = (json["dataPoints"] as? [[String: Any]]) ?? []

            var reachedOlderData = false
            for point in points {
                guard let value = point[pointKey] as? [String: Any] else { continue }
                guard let time = timeOf(value) else { continue }
                if time < since {
                    reachedOlderData = true
                    continue
                }
                handle(value)
            }

            guard !reachedOlderData,
                  let next = json["nextPageToken"] as? String, !next.isEmpty
            else { break }
            pageToken = next
        }
    }

    /// Server-side aggregation over physical time (`dataPoints:rollUp`): one value per
    /// `windowSeconds` window. Requests at most 7 days at a time (the API caps some
    /// types, e.g. heart rate, at 14 days per request).
    func rollUp(dataType: String, valueKey: String, from start: Date, to end: Date,
                windowSeconds: Int) async throws -> [(start: Date, value: Double)] {
        var results: [(start: Date, value: Double)] = []
        var chunkStart = start
        while chunkStart < end {
            let chunkEnd = min(end, chunkStart.addingTimeInterval(7 * 86400))
            var pageToken: String?
            repeat {
                var request = URLRequest(url: URL(string: base + dataType + "/dataPoints:rollUp")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = [
                    "range": ["startTime": GoogleHealthJSON.rfc3339(chunkStart), "endTime": GoogleHealthJSON.rfc3339(chunkEnd)],
                    "windowSize": "\(windowSeconds)s",
                    "dataSourceFamily": dataSourceFamily,
                ]
                if let pageToken { body["pageToken"] = pageToken }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let json = try await send(request)
                for point in (json["rollupDataPoints"] as? [[String: Any]]) ?? [] {
                    guard let time = GoogleHealthJSON.timestamp(point["startTime"]),
                          let value = GoogleHealthJSON.averageNumber(in: point[valueKey])
                    else { continue }
                    results.append((time, value))
                }
                pageToken = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            } while pageToken != nil
            chunkStart = chunkEnd
        }
        return results
    }

    /// One total per civil day in [start, end) for `dataType`, read from the
    /// rollup value stored under `valueKey` (e.g. "floors").
    func dailyRollUp(dataType: String, valueKey: String, from start: Date, to end: Date) async throws -> [(day: Date, value: Double)] {
        var request = URLRequest(url: URL(string: base + dataType + "/dataPoints:dailyRollUp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "range": ["start": GoogleHealthJSON.civilDateTime(start), "end": GoogleHealthJSON.civilDateTime(end)],
            "windowSizeDays": 1,
            "dataSourceFamily": dataSourceFamily,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        let points = (json["rollupDataPoints"] as? [[String: Any]]) ?? []
        return points.compactMap { point in
            guard let day = GoogleHealthJSON.civilDate(point["civilStartTime"]),
                  let value = GoogleHealthJSON.firstNumber(in: point[valueKey])
            else { return nil }
            return (day, value)
        }
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        let token = try await auth.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(code) {
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            // Back off on rate limiting / gateway timeouts, as the API docs recommend.
            if (code == 429 || code == 503 || code == 504), attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                continue
            }
            throw GoogleHealthError.http(code, String(data: data, encoding: .utf8) ?? "<no body>")
        }
    }
}

enum GoogleHealthError: LocalizedError {
    case http(Int, String)

    var isPermissionDenied: Bool {
        if case .http(let code, _) = self { return code == 401 || code == 403 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "Google Health API request failed (\(code)): \(body.prefix(300))"
        }
    }
}

/// Helpers for the loosely-typed Google Health JSON.
enum GoogleHealthJSON {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// Numbers may arrive as JSON numbers or as strings (int64 fields).
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Value of a rollup/summary object: the first numeric field found (e.g. countSum).
    static func firstNumber(in any: Any?) -> Double? {
        if let n = number(any) { return n }
        guard let dict = any as? [String: Any] else { return nil }
        for key in dict.keys.sorted() {
            if let n = number(dict[key]) { return n }
        }
        return nil
    }

    /// Average from a rollup value object (prefers fields named avg/average/mean).
    static func averageNumber(in any: Any?) -> Double? {
        if let dict = any as? [String: Any] {
            for key in dict.keys.sorted() {
                let k = key.lowercased()
                if k.contains("avg") || k.contains("average") || k.contains("mean"), let n = number(dict[key]) {
                    return n
                }
            }
        }
        return firstNumber(in: any)
    }

    static func rfc3339(_ date: Date) -> String {
        iso.string(from: date)
    }

    static func timestamp(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    /// `{"year":..,"month":..,"day":..}`, `{"date":{...}}`, or "YYYY-MM-DD" → local midnight.
    static func civilDate(_ any: Any?) -> Date? {
        var comps = DateComponents()
        if let dict = any as? [String: Any] {
            if let inner = dict["date"] { return civilDate(inner) }
            guard let y = number(dict["year"]), let m = number(dict["month"]), let d = number(dict["day"]) else { return nil }
            comps.year = Int(y); comps.month = Int(m); comps.day = Int(d)
        } else if let s = any as? String {
            let parts = s.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        } else {
            return nil
        }
        return Calendar.current.date(from: comps)
    }

    static func civilDateTime(_ date: Date) -> [String: Any] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return [
            "date": ["year": c.year ?? 1970, "month": c.month ?? 1, "day": c.day ?? 1],
            "time": ["hours": 0, "minutes": 0, "seconds": 0, "nanos": 0],
        ]
    }

    /// Start/end of an `interval` object.
    static func interval(_ value: [String: Any]) -> (start: Date, end: Date)? {
        guard let interval = value["interval"] as? [String: Any],
              let start = timestamp(interval["startTime"]),
              let end = timestamp(interval["endTime"]),
              end >= start
        else { return nil }
        return (start, end)
    }

    /// Time of a `sampleTime` object (physicalTime).
    static func sampleTime(_ value: [String: Any]) -> Date? {
        if let sample = value["sampleTime"] as? [String: Any] {
            return timestamp(sample["physicalTime"]) ?? timestamp(sample["civilTime"])
        }
        return timestamp(value["sampleTime"])
    }

    /// Date of a daily data point (`date` field).
    static func dailyDate(_ value: [String: Any]) -> Date? {
        civilDate(value["date"])
    }

    /// Protobuf duration string such as "1830s" or "1830.5s".
    static func duration(_ any: Any?) -> TimeInterval? {
        guard let s = any as? String, s.hasSuffix("s") else { return number(any) }
        return Double(s.dropLast())
    }
}
