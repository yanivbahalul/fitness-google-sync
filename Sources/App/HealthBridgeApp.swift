import SwiftUI

@main
struct HealthBridgeApp: App {
    @StateObject private var auth = GoogleAuthManager()
    @StateObject private var sync: SyncCoordinator

    init() {
        let sharedAuth = GoogleAuthManager()
        _auth = StateObject(wrappedValue: sharedAuth)
        _sync = StateObject(wrappedValue: SyncCoordinator(auth: sharedAuth))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(sync)
        }
    }
}
