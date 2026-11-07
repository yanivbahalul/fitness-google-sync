import Foundation

/// OAuth client configuration.
///
/// Built-in defaults are this project's iOS-type Google OAuth client. An iOS client ID is
/// public (it ships inside every app binary) and has no secret, so it is safe to commit.
/// To use a different client, put overrides in Sources/Config/Secrets.plist (gitignored).
enum AppConfig {
    private static let defaultClientID = "84175655883-g6tnujthm7282dthp53sbljc4udstrqm.apps.googleusercontent.com"
    /// Reversed client ID: the redirect scheme Google expects for iOS clients.
    /// Must match GOOGLE_OAUTH_REDIRECT_SCHEME in project.yml.
    private static let defaultRedirectURI = "com.googleusercontent.apps.84175655883-g6tnujthm7282dthp53sbljc4udstrqm:/oauth2redirect"

    static let googleClientID: String = optionalValue(for: "GoogleOAuthClientID") ?? defaultClientID
    /// Optional: Web-application OAuth clients issue a secret; iOS-type clients don't.
    static let googleClientSecret: String? = optionalValue(for: "GoogleOAuthClientSecret")
    static let googleRedirectURI: String = optionalValue(for: "GoogleOAuthRedirectURI") ?? defaultRedirectURI

    /// Scheme portion of googleRedirectURI, used to register the URL type and
    /// to recognize the OAuth callback in SceneDelegate/onOpenURL.
    static var googleRedirectScheme: String {
        guard let url = URL(string: googleRedirectURI), let scheme = url.scheme else {
            fatalError("GoogleOAuthRedirectURI in Secrets.plist is not a valid URL")
        }
        return scheme
    }

    private static let secrets: [String: String] = {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return plist
    }()

    private static func optionalValue(for key: String) -> String? {
        guard let value = secrets[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("YOUR_")
        else { return nil }
        return value
    }
}
