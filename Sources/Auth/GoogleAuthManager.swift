import AuthenticationServices
import CryptoKit
import Foundation

/// Drives the Google OAuth 2.0 authorization-code flow (with PKCE) for the
/// Google Health API, and keeps the resulting access/refresh tokens.
///
/// Flow and endpoints are as documented at developers.google.com/health/setup
/// and developers.google.com/health/endpoints (fetched 2026-11-06):
///   - authorize: https://accounts.google.com/o/oauth2/v2/auth
///   - token:     https://oauth2.googleapis.com/token
///   - scopes:    googlehealth.{activity_and_fitness,health_metrics_and_measurements,sleep,nutrition}.readonly
@MainActor
final class GoogleAuthManager: NSObject, ObservableObject {
    @Published private(set) var isSignedIn: Bool = false
    @Published var lastError: String?

    private var accessToken: String?
    private var accessTokenExpiresAt: Date?

    static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.nutrition.readonly",
    ]
    private let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private var webAuthSession: ASWebAuthenticationSession?
    private var pendingVerifier: String?

    override init() {
        super.init()
        isSignedIn = KeychainStore.loadRefreshToken() != nil
    }

    // MARK: - Sign in

    func signIn() async {
        lastError = nil
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)
        pendingVerifier = verifier

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: AppConfig.googleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else {
            lastError = "Could not build authorization URL."
            return
        }

        do {
            let callbackURL = try await startWebAuthSession(url: authURL, scheme: AppConfig.googleRedirectScheme)
            guard
                let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                lastError = "Google did not return an authorization code."
                return
            }
            try await exchangeCodeForTokens(code: code, verifier: verifier)
            isSignedIn = true
        } catch is CancellationError {
            // User cancelled the sign-in sheet; not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        KeychainStore.clearRefreshToken()
        accessToken = nil
        accessTokenExpiresAt = nil
        isSignedIn = false
    }

    // MARK: - Access token

    /// Returns a valid access token, refreshing it first if needed.
    func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = accessTokenExpiresAt, expiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refreshToken = KeychainStore.loadRefreshToken() else {
            throw AuthError.notSignedIn
        }
        return try await refreshAccessToken(refreshToken: refreshToken)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(withClientCredentials([
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]))

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertSuccess(response, data: data)

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = decoded.accessToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        if let newRefreshToken = decoded.refreshToken {
            KeychainStore.saveRefreshToken(newRefreshToken)
        }
        return decoded.accessToken
    }

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(withClientCredentials([
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": AppConfig.googleRedirectURI,
        ]))

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertSuccess(response, data: data)

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = decoded.accessToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        guard let refreshToken = decoded.refreshToken else {
            throw AuthError.missingRefreshToken
        }
        KeychainStore.saveRefreshToken(refreshToken)
    }

    // MARK: - ASWebAuthenticationSession

    private func startWebAuthSession(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? AuthError.unknown)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }
    }

    /// Adds client_id, plus client_secret only when one is configured (Web-type clients).
    private func withClientCredentials(_ params: [String: String]) -> [String: String] {
        var params = params
        params["client_id"] = AppConfig.googleClientID
        if let secret = AppConfig.googleClientSecret {
            params["client_secret"] = secret
        }
        return params
    }

    private func formBody(_ params: [String: String]) -> Data {
        params
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
                return "\(key)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    private static func assertSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw AuthError.http((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension GoogleAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

enum AuthError: LocalizedError {
    case notSignedIn
    case missingRefreshToken
    case http(Int, String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Google."
        case .missingRefreshToken:
            return "Google did not return a refresh token. Make sure prompt=consent and access_type=offline are set."
        case .http(let code, let body):
            return "Google OAuth request failed (\(code)): \(body)"
        case .unknown:
            return "Unknown authentication error."
        }
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=")
        return set
    }()
}
