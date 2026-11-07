import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        NavigationStack {
            Form {
                Section("Google Health account") {
                    if auth.isSignedIn {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Disconnect", role: .destructive) {
                            auth.signOut()
                        }
                    } else {
                        Button("Connect Google Health") {
                            Task { await auth.signIn() }
                        }
                    }
                    if let authError = auth.lastError {
                        Text(authError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Sync") {
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        if sync.isSyncing {
                            ProgressView()
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled(!auth.isSignedIn || sync.isSyncing)

                    if let summary = sync.lastSyncSummary, let date = sync.lastSyncDate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary)
                            Text(date, style: .relative)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let syncError = sync.lastError {
                        Text(syncError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("Pulls your last 14 days of step totals from Google Health and writes them into Apple Health. Re-authentication may be needed about once a week while the Google OAuth client is in Testing mode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("HealthBridge")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GoogleAuthManager())
        .environmentObject(SyncCoordinator(auth: GoogleAuthManager()))
}
