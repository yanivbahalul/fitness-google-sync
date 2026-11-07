import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        NavigationStack {
            Form {
                Section("חשבון Google Health") {
                    if auth.isSignedIn {
                        Label("מחובר", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("התנתק", role: .destructive) {
                            auth.signOut()
                        }
                    } else {
                        Button("התחבר ל‑Google Health") {
                            Task { await auth.signIn() }
                        }
                    }
                    if let authError = auth.lastError {
                        Text(authError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("סנכרון") {
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        if sync.isSyncing {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("מסנכרן…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("סנכרן עכשיו")
                        }
                    }
                    .disabled(!auth.isSignedIn || sync.isSyncing)

                    if let date = sync.lastSyncDate {
                        Label {
                            Text("הסנכרון הושלם: \(date.formatted(date: .abbreviated, time: .shortened))")
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    if !sync.failedTypes.isEmpty {
                        Text("לא סונכרנו: \(sync.failedTypes.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if sync.needsReconnect {
                        Text("חסרה הרשאה לחלק מהנתונים: התנתק, התחבר מחדש ואשר את כל ההרשאות.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let syncError = sync.lastError {
                        Text(syncError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("מעביר מ‑Google Health ל‑Apple Health צעדים, דופק, שינה, אימונים, מדדי גוף ותזונה. כל סנכרון משלים את הימים מאז הסנכרון הקודם, בלי כפילויות. בערך פעם בשבוע ייתכן שתתבקש להתחבר מחדש ל‑Google.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("StepsBridge")
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

#Preview {
    ContentView()
        .environmentObject(GoogleAuthManager())
        .environmentObject(SyncCoordinator(auth: GoogleAuthManager()))
}
