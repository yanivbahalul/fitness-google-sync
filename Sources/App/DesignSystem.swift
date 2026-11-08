import Charts
import SwiftUI

// HealthBridge design system: one place for colors, spacing and the shared components,
// so every screen looks and behaves the same.
//
// Rules (from Apple's Human Interface Guidelines and the chart guidelines used here):
// - One accent color (blue) for interactive elements and the main data series. Other
//   colors only carry meaning: green = done, orange = warning, red = error, and always
//   with an icon or text, never color alone.
// - System text styles only (Dynamic Type); icon sizes scale with @ScaledMetric.
// - Semantic system colors for surfaces and text, so light/dark mode and Increase
//   Contrast work automatically.
// - Tap targets at least 44 pt.

enum Theme {
    /// The one accent color.
    static let blue = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255, alpha: 1)
        : UIColor(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255, alpha: 1) })
    static var accent: Color { blue }
}

/// Chart colors: the validated categorical pair (blue / orange), stepped for light and dark.
enum ChartColors {
    static let blue = Theme.blue
    static let orange = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255, alpha: 1)
        : UIColor(red: 0xEB / 255, green: 0x68 / 255, blue: 0x34 / 255, alpha: 1) })
    /// Goal / reference lines: neutral, so they never compete with the data.
    static let reference = Color.secondary
}

/// Spacing and shape tokens.
enum DS {
    static let pagePadding: CGFloat = 16
    static let cardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let innerSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 20
    static let tileRadius: CGFloat = 12
    static let minTap: CGFloat = 44
}

/// The page background and card surface used everywhere.
extension View {
    func pageBackground() -> some View {
        background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    /// Right-to-left Hebrew layout, Hebrew dates and the accent tint, for screens and sheets.
    func appChrome() -> some View {
        environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, .he)
            .tint(Theme.accent)
    }
}

/// A rounded surface that groups related content.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.innerSpacing) { content }
            .padding(DS.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
    }
}

/// The one icon style: accent symbol on a faint accent tile.
struct SoftIcon: View {
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat

    init(symbol: String, size: CGFloat = 32) {
        self.symbol = symbol
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Card title: icon + name, the same on every card.
struct CardHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            SoftIcon(symbol: symbol, size: 28)
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, symbol: String) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}

/// The plain-language sentence at the top of a chart card.
struct Headline: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One number with its label. The only tile style in the app.
struct StatTile: View {
    let title: String
    let value: String
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A short message with a meaning (info / warning / error), icon + text.
struct Notice: View {
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
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
    }
}

/// Legend entry written in words.
struct LegendItem: View {
    let color: Color
    let text: String
    var dashed = false

    var body: some View {
        HStack(spacing: 6) {
            if dashed {
                Capsule().stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(width: 16, height: 2)
            } else {
                Circle().fill(color).frame(width: 10, height: 10)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Value shown above a tapped chart point.
struct ValueBubble: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Tap or drag on a chart to pick the nearest date.
struct SelectionOverlay: View {
    let proxy: ChartProxy
    let onSelect: (Date) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = geo[proxy.plotAreaFrame].origin
                        if let date: Date = proxy.value(atX: value.location.x - origin.x) { onSelect(date) }
                    }
                    .onEnded { _ in onEnd() })
        }
    }
}

/// Primary full-width button (one per screen at most).
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                if let symbol { Image(systemName: symbol) }
                Text(title).bold()
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}
