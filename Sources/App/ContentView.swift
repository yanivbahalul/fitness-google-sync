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
                            HStack {
                                ProgressView()
                                Text(sync.progress ?? "Syncing…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled(!auth.isSignedIn || sync.isSyncing)

                    if let date = sync.lastSyncDate {
                        Text("Last sync \(date, style: .relative) ago")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if sync.needsReconnect {
                        Text("Some data types need permission. Tap Disconnect, then Connect Google Health again and allow all requested access.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let syncError = sync.lastError {
                        Text(syncError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !sync.results.isEmpty {
                    Section("Last sync details") {
                        ForEach(sync.results) { result in
                            HStack(alignment: .firstTextBaseline) {
                                Text(result.name)
                                Spacer()
                                if let error = result.error {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .multilineTextAlignment(.trailing)
                                        .lineLimit(3)
                                } else {
                                    Text("\(result.count ?? 0)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Pulls the last 14 days from Google Health (activity, heart, sleep, body measurements, workouts, nutrition) and writes them into Apple Health. Re-syncing replaces what StepsBridge wrote before, so nothing is duplicated. Re-authentication may be needed about once a week while the Google OAuth client is in Testing mode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("StepsBridge")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GoogleAuthManager())
        .environmentObject(SyncCoordinator(auth: GoogleAuthManager()))
}
