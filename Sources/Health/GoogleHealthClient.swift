import Foundation

/// Reads daily step totals from the Google Health API.
///
/// Endpoint confirmed at developers.google.com/health/endpoints (fetched 2026-11-06):
///   POST https://health.googleapis.com/v4/users/me/dataTypes/steps/dataPoints:dailyRollUp
/// Request/response shapes are from that page's worked example.
final class GoogleHealthClient {
    private let auth: GoogleAuthManager
    private let baseURL = URL(string: "https://health.googleapis.com/v4/users/me/dataTypes/steps/dataPoints:dailyRollUp")!

    init(auth: GoogleAuthManager) {
        self.auth = auth
    }

    /// Returns one entry per civil day in [start, end) with that day's total step count.
    func dailySteps(from start: Date, to end: Date) async throws -> [DailySteps] {
        let token = try await auth.validAccessToken()

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DailyRollUpRequest(
                range: .init(start: .init(date: start), end: .init(date: end)),
                windowSizeDays: 1,
                dataSourceFamily: "users/me/dataSourceFamilies/google-sources"
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleHealthError.http(code, body)
        }

        let decoded = try JSONDecoder().decode(DailyRollUpResponse.self, from: data)
        return decoded.rollupDataPoints.compactMap { point -> DailySteps? in
            guard let day = point.civilStartTime.date.asDate(),
                  let countString = point.steps?.countSum,
                  let count = Int(countString)
            else { return nil }
            return DailySteps(day: day, stepCount: count)
        }
    }
}

struct DailySteps {
    let day: Date
    let stepCount: Int
}

enum GoogleHealthError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "Google Health API request failed (\(code)): \(body)"
        }
    }
}

// MARK: - Wire types matching the documented dailyRollUp request/response

private struct DailyRollUpRequest: Encodable {
    struct Range: Encodable {
        let start: CivilDateTime
        let end: CivilDateTime
    }
    let range: Range
    let windowSizeDays: Int
    let dataSourceFamily: String
}

private struct CivilDateTime: Encodable {
    struct DateComponentsWire: Encodable {
        let year: Int
        let month: Int
        let day: Int
    }
    struct TimeComponentsWire: Encodable {
        let hours: Int
        let minutes: Int
        let seconds: Int
        let nanos: Int
    }
    let date: DateComponentsWire
    let time: TimeComponentsWire

    init(date: Date) {
        let comps = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        self.date = .init(year: comps.year ?? 1970, month: comps.month ?? 1, day: comps.day ?? 1)
        self.time = .init(hours: 0, minutes: 0, seconds: 0, nanos: 0)
    }
}

private struct DailyRollUpResponse: Decodable {
    let rollupDataPoints: [RollupDataPoint]
}

private struct RollupDataPoint: Decodable {
    struct CivilDate: Decodable {
        struct DateComponentsWire: Decodable {
            let year: Int
            let month: Int
            let day: Int

            func asDate() -> Date? {
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                comps.day = day
                return Calendar(identifier: .gregorian).date(from: comps)
            }
        }
        let date: DateComponentsWire
    }
    struct Steps: Decodable {
        let countSum: String
    }
    let civilStartTime: CivilDate
    let steps: Steps?
}
