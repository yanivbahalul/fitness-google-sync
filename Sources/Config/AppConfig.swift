import Foundation

/// Loads OAuth client configuration from Sources/Config/Secrets.plist (gitignored).
/// Copy Secrets.example.plist to Secrets.plist and fill in real values before building.
enum AppConfig {
    static let googleClientID: String = value(for: "GoogleOAuthClientID")
    /// Optional: Web-application OAuth clients issue a secret; iOS-type clients don't.
    static let googleClientSecret: String? = optionalValue(for: "GoogleOAuthClientSecret")
    static let googleRedirectURI: String = value(for: "GoogleOAuthRedirectURI")

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

    private static func value(for key: String) -> String {
        guard let value = optionalValue(for: key) else {
            fatalError("""
                Missing or unfilled \(key) in Secrets.plist.
                Copy Sources/Config/Secrets.example.plist to Sources/Config/Secrets.plist \
                and fill in your Google Cloud OAuth client values.
                """)
        }
        return value
    }
}
