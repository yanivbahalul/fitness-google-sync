import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: GoogleAuthManager
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HeaderCard()
                    if auth.isSignedIn {
                        SyncCard()
                        ForEach(SyncCategory.allCases) { category in
                            CategoryCard(category: category)
                        }
                        AccountCard()
                    } else {
                        ConnectCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Theme

extension SyncCategory {
    var color: Color {
        switch self {
        case .activity: return .orange
        case .heart: return .red
        case .sleep: return .indigo
        case .body: return .purple
        case .nutrition: return .teal
        }
    }
}

private enum Theme {
    /// Same blue → pink as the app icon (Google Health half → Apple Health half).
    static let gradient = LinearGradient(
        colors: [Color(red: 0.20, green: 0.52, blue: 1.0), Color(red: 1.0, green: 0.30, blue: 0.42)],
        startPoint: .leading, endPoint: .trailing)
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// SF Symbol on a tinted rounded square, like the Health app.
private struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Header

private struct HeaderCard: View {
    @EnvironmentObject private var auth: GoogleAuthManager

    var body: some View {
        HStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("StepsBridge")
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Text("Google Health")
                    Image(systemName: "arrow.left")
                        .accessibilityHidden(true)
                    Text("Apple Health")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("מעביר נתונים מ‑Google Health אל Apple Health")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .topTrailing) {
            StatusPill(connected: auth.isSignedIn)
        }
    }
}

private struct StatusPill: View {
    let connected: Bool

    var body: some View {
        Label(connected ? "מחובר" : "לא מחובר", systemImage: connected ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(connected ? .green : .secondary)
            .background((connected ? Color.green : Color.gray).opacity(0.15), in: Capsule())
    }
}

// MARK: - Connect

private struct ConnectCard: View {
    @EnvironmentObject private var auth: GoogleAuthManager

    var body: some View {
        Card {
            Text("כדי להתחיל, התחבר לחשבון Google שאליו הצמיד מסונכרן.")
                .font(.body)
            Button {
                Task { await auth.signIn() }
            } label: {
                Label("התחבר ל‑Google Health", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            if let error = auth.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Sync

private struct SyncCard: View {
    @EnvironmentObject private var sync: SyncCoordinator

    var body: some View {
        Card {
            Button {
                Task { await sync.syncNow() }
            } label: {
                VStack(spacing: 6) {
                    if sync.isSyncing {
                        ProgressView(value: sync.progress)
                            .tint(.white)
                            .padding(.horizontal, 24)
                        Text("מסנכרן… \(Int(sync.progress * 100))%")
                            .font(.headline)
                    } else {
                        Label("סנכרן עכשיו", systemImage: "arrow.triangle.2.circlepath")
                            .font(.title3.bold())
                        Text("\(sync.enabledCount) סוגי נתונים נבחרו")
                            .font(.subheadline)
                            .opacity(0.9)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 88)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .opacity(sync.enabledCount == 0 ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(sync.isSyncing || sync.enabledCount == 0)
            .accessibilityLabel(sync.isSyncing ? "מסנכרן, \(Int(sync.progress * 100)) אחוז" : "סנכרן עכשיו, \(sync.enabledCount) סוגי נתונים")

            if let date = sync.lastSyncDate {
                Label {
                    Text("הסנכרון הושלם: \(date.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("טווח סנכרון")
                    .font(.subheadline.weight(.semibold))
                Picker("טווח סנכרון", selection: $sync.range) {
                    ForEach(SyncRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                Text(sync.range == .automatic
                     ? "משלים אוטומטית מאז הסנכרון האחרון של כל סוג נתונים (עד 14 יום)."
                     : "מסנכרן מחדש את הימים האחרונים, בלי כפילויות.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(sync.isSyncing)

            if sync.needsReconnect {
                Notice(symbol: "key.fill", color: .orange,
                       text: "חסרה הרשאה לחלק מהנתונים. התנתק בתחתית המסך, התחבר מחדש ואשר את כל ההרשאות.")
            }
            if let error = sync.lastError {
                Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: error)
            }
        }
    }
}

private struct Notice: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Categories

private struct CategoryCard: View {
    @EnvironmentObject private var sync: SyncCoordinator
    let category: SyncCategory

    var body: some View {
        let items = sync.items(in: category)
        let onCount = items.filter(sync.isEnabled).count

        Card {
            Toggle(isOn: Binding(
                get: { sync.allEnabled(in: category) },
                set: { sync.setAll(in: category, $0) }
            )) {
                HStack(spacing: 12) {
                    IconBadge(symbol: category.symbol, color: category.color, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.headline)
                        Text("\(onCount) מתוך \(items.count) פעילים")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(category.color)
            .accessibilityLabel("\(category.title), הכול")
            .accessibilityValue("\(onCount) מתוך \(items.count) פעילים")

            if items.count > 1 || items.first?.name != category.title {
                Divider()
                ForEach(items) { item in
                    ItemRow(item: item, color: category.color)
                }
            }
        }
        .disabled(sync.isSyncing)
    }
}

private struct ItemRow: View {
    @EnvironmentObject private var sync: SyncCoordinator
    let item: SyncItem
    let color: Color

    var body: some View {
        Toggle(isOn: Binding(
            get: { sync.isEnabled(item) },
            set: { sync.setEnabled(item, $0) }
        )) {
            HStack(spacing: 12) {
                IconBadge(symbol: item.symbol, color: color.opacity(0.85), size: 30)
                Text(item.name)
                    .font(.body)
                Spacer(minLength: 4)
                StatusIcon(status: sync.status(for: item))
            }
        }
        .tint(color)
        .frame(minHeight: 44)
    }
}

private struct StatusIcon: View {
    let status: ItemStatus?

    var body: some View {
        switch status {
        case .synced(let count):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("סונכרן, \(count) רשומות")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .accessibilityLabel("לא סונכרן: \(message)")
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Account

private struct AccountCard: View {
    @EnvironmentObject private var auth: GoogleAuthManager

    var body: some View {
        Card {
            Label("חשבון ותחזוקה", systemImage: "gearshape.fill")
                .font(.headline)
            Text("כל סנכרון מחליף רק את מה ש‑StepsBridge כתב בעבר, כך שאין כפילויות. פעם בשבוע חבר את האייפון ל‑Mac ולחץ ▶️ ב‑Xcode כדי לחדש את האפליקציה.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                auth.signOut()
            } label: {
                Label("התנתק מ‑Google", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
        }
    }
}

#Preview {
    let auth = GoogleAuthManager()
    return ContentView()
        .environmentObject(auth)
        .environmentObject(SyncCoordinator(auth: auth))
}
