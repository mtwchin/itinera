import Foundation
import SwiftUI

enum ItineraAesthetic: String, CaseIterable {
    case atlas
    case wayfinder
    case signal

    static var selected: ItineraAesthetic {
        environmentOverride ?? .atlas
    }

    static var environmentOverride: ItineraAesthetic? {
        ProcessInfo.processInfo.environment["ITINERA_THEME"]
            .map { $0.lowercased() }
            .flatMap(ItineraAesthetic.init(rawValue:))
    }

    var theme: ItineraTheme {
        switch self {
        case .atlas: return .atlas
        case .wayfinder: return .wayfinder
        case .signal: return .signal
        }
    }

}

struct ItineraTheme {
    let name: String
    let canvas: Color
    let canvasAccent: Color
    let surface: Color
    let surfaceStrong: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let accentContrast: Color
    let route: Color
    let highlight: Color
    let highlightStrong: Color
    let border: Color
    let success: Color
    let warning: Color
    let danger: Color
    let shadow: Color
    let cornerRadius: CGFloat
    let preferredColorScheme: ColorScheme

    static func resolved(
        for colorScheme: ColorScheme,
        aestheticOverride: ItineraAesthetic?
    ) -> ItineraTheme {
        if let aestheticOverride {
            return aestheticOverride.theme
        }
        return colorScheme == .dark ? .signal : .atlas
    }

    static let atlas = ItineraTheme(
        name: "Atlas Field Notes",
        canvas: Color(itineraHex: 0xF4F0E6),
        canvasAccent: Color(itineraHex: 0xE6DED0),
        surface: Color(itineraHex: 0xFFFDF7),
        surfaceStrong: Color(itineraHex: 0xF8F4EA),
        primaryText: Color(itineraHex: 0x1D2923),
        secondaryText: Color(itineraHex: 0x566158),
        accent: Color(itineraHex: 0x416552),
        accentContrast: Color(itineraHex: 0xFFFDF7),
        route: Color(itineraHex: 0x2E6F6A),
        highlight: Color(itineraHex: 0xD9684A),
        highlightStrong: Color(itineraHex: 0xA9432F),
        border: Color(itineraHex: 0x938B7E),
        success: Color(itineraHex: 0x48755A),
        warning: Color(itineraHex: 0xA5652D),
        danger: Color(itineraHex: 0xA64232),
        shadow: Color.black.opacity(0.08),
        cornerRadius: 24,
        preferredColorScheme: .light
    )

    static let wayfinder = ItineraTheme(
        name: "Wayfinder System",
        canvas: Color(itineraHex: 0xF6F7F2),
        canvasAccent: Color(itineraHex: 0xE4E7E2),
        surface: Color.white,
        surfaceStrong: Color(itineraHex: 0xF0F2EE),
        primaryText: Color(itineraHex: 0x171B1D),
        secondaryText: Color(itineraHex: 0x5C656A),
        accent: Color(itineraHex: 0x2356A8),
        accentContrast: Color.white,
        route: Color(itineraHex: 0x2356A8),
        highlight: Color(itineraHex: 0xE45A2B),
        highlightStrong: Color(itineraHex: 0xA43618),
        border: Color(itineraHex: 0x8C9592),
        success: Color(itineraHex: 0x367650),
        warning: Color(itineraHex: 0xA86516),
        danger: Color(itineraHex: 0xB23B32),
        shadow: Color.black.opacity(0.06),
        cornerRadius: 14,
        preferredColorScheme: .light
    )

    static let signal = ItineraTheme(
        name: "Signal Atlas",
        canvas: Color(itineraHex: 0x0B1017),
        canvasAccent: Color(itineraHex: 0x142330),
        surface: Color(itineraHex: 0x17212B),
        surfaceStrong: Color(itineraHex: 0x202D39),
        primaryText: Color(itineraHex: 0xF2F6F8),
        secondaryText: Color(itineraHex: 0xAAB8C2),
        accent: Color(itineraHex: 0x2CE0C5),
        accentContrast: Color(itineraHex: 0x08110F),
        route: Color(itineraHex: 0x2CE0C5),
        highlight: Color(itineraHex: 0xFF6670),
        highlightStrong: Color(itineraHex: 0xB93340),
        border: Color(itineraHex: 0x304454),
        success: Color(itineraHex: 0x50D59E),
        warning: Color(itineraHex: 0xF2B85B),
        danger: Color(itineraHex: 0xFF6670),
        shadow: Color.black.opacity(0.35),
        cornerRadius: 22,
        preferredColorScheme: .dark
    )
}

private struct ItineraThemeKey: EnvironmentKey {
    static let defaultValue = ItineraTheme.atlas
}

extension EnvironmentValues {
    var itineraTheme: ItineraTheme {
        get { self[ItineraThemeKey.self] }
        set { self[ItineraThemeKey.self] = newValue }
    }
}

extension Color {
    init(itineraHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

struct ItineraBackground: View {
    @Environment(\.itineraTheme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.canvas, theme.canvasAccent.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { context, size in
                let rows = 9
                for row in 0..<rows {
                    var path = Path()
                    let baseY = size.height * CGFloat(row + 1) / CGFloat(rows + 1)
                    path.move(to: CGPoint(x: -24, y: baseY))
                    var x: CGFloat = -24
                    while x <= size.width + 24 {
                        let wave = CGFloat(sin(Double(x / 48) + Double(row) * 0.78)) * 10
                        path.addLine(to: CGPoint(x: x, y: baseY + wave))
                        x += 18
                    }
                    context.stroke(
                        path,
                        with: .color(theme.route.opacity(0.07)),
                        lineWidth: 1
                    )
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ItineraLogoMark: View {
    @Environment(\.itineraTheme) private var theme

    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [theme.highlight, theme.highlightStrong],
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: 0,
                        endRadius: size * 0.58
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.20), lineWidth: max(1, size * 0.032))
                .padding(size * 0.10)
            ItineraCompassNS()
                .fill(Color.white)
                .frame(width: size * 0.66, height: size * 0.66)
            ItineraCompassEW()
                .fill(Color.white.opacity(0.68))
                .frame(width: size * 0.66, height: size * 0.66)
            Circle()
                .fill(theme.highlightStrong)
                .frame(width: size * 0.13, height: size * 0.13)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ItineraCompassNS: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: p(0.5, 0.5))
        path.addLine(to: p(0.405, 0.365))
        path.addLine(to: p(0.5, 0.03))
        path.addLine(to: p(0.595, 0.365))
        path.closeSubpath()
        path.move(to: p(0.5, 0.5))
        path.addLine(to: p(0.415, 0.635))
        path.addLine(to: p(0.5, 0.97))
        path.addLine(to: p(0.585, 0.635))
        path.closeSubpath()
        return path
    }
}

private struct ItineraCompassEW: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        // East arm
        path.move(to: p(0.5, 0.5))
        path.addLine(to: p(0.635, 0.415))
        path.addLine(to: p(0.97, 0.5))
        path.addLine(to: p(0.635, 0.585))
        path.closeSubpath()
        // West arm
        path.move(to: p(0.5, 0.5))
        path.addLine(to: p(0.365, 0.415))
        path.addLine(to: p(0.03, 0.5))
        path.addLine(to: p(0.365, 0.585))
        path.closeSubpath()
        return path
    }
}

struct ItineraSurface<Content: View>: View {
    @Environment(\.itineraTheme) private var theme

    private let content: Content
    private let padding: CGFloat

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .fill(theme.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .stroke(theme.border.opacity(0.75), lineWidth: 1)
            }
            .shadow(color: theme.shadow, radius: 18, y: 8)
    }
}

struct ItineraBrandHeader: View {
    @Environment(\.itineraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let eyebrow: String
    let title: String
    let message: String

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ItineraLogoMark(size: 40)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.72)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72).delay(0.06),
                        value: appeared
                    )
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(2.1)
                    .foregroundStyle(theme.secondaryText)
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.10), value: appeared)
            }

            Text(title)
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.14), value: appeared)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.32).delay(0.20), value: appeared)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !appeared else { return }
            appeared = true
        }
    }
}

struct ItineraSectionHeading: View {
    @Environment(\.itineraTheme) private var theme

    let number: String
    let title: String
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(number)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(theme.highlightStrong)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ItineraStatusBanner: View {
    enum Kind {
        case success, warning, error
    }

    @Environment(\.itineraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let message: String
    let kind: Kind

    @State private var appeared = false

    private var color: Color {
        switch kind {
        case .success: return theme.success
        case .warning: return theme.warning
        case .error: return theme.danger
        }
    }

    private var icon: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Label(message, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))
            .accessibilityLabel(message)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : -6)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.25),
                value: appeared
            )
            .onAppear {
                guard !appeared else { return }
                appeared = true
            }
    }
}

struct ItineraPill: View {
    @Environment(\.itineraTheme) private var theme

    let text: String
    var systemImage: String?
    var highlighted = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(highlighted ? theme.accentContrast : theme.secondaryText)
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        .background(
            highlighted ? theme.accent : theme.surfaceStrong,
            in: Capsule()
        )
        .overlay {
            if !highlighted {
                Capsule().stroke(theme.border, lineWidth: 1)
            }
        }
    }
}

struct ItineraPrimaryButtonStyle: ButtonStyle {
    @Environment(\.itineraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(theme.accentContrast)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(theme.accent.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .scaleEffect(
                reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

private struct ItineraFieldModifier: ViewModifier {
    @Environment(\.itineraTheme) private var theme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.surfaceStrong)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.border.opacity(0.8), lineWidth: 1)
            }
    }
}

extension View {
    func itineraField() -> some View {
        modifier(ItineraFieldModifier())
    }

    func revealOnAppear(delay: Double = 0) -> some View {
        modifier(RevealAnimation(delay: delay))
    }
}

struct ItineraSkeletonRow: View {
    @Environment(\.itineraTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ItineraSurface {
            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .fill(theme.surfaceStrong)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.surfaceStrong)
                        .frame(height: 14)
                        .frame(maxWidth: .infinity)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.surfaceStrong)
                        .frame(height: 11)
                        .frame(maxWidth: 130)
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.surfaceStrong)
                            .frame(width: 70, height: 20)
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.surfaceStrong)
                            .frame(width: 55, height: 20)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 72)
        }
        .opacity(isPulsing ? 0.4 : 0.85)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
            value: isPulsing
        )
        .onAppear { isPulsing = true }
        .accessibilityHidden(true)
    }
}

struct RevealAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    var delay: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 16)
            .onAppear {
                if reduceMotion {
                    hasAppeared = true
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82).delay(delay)) {
                        hasAppeared = true
                    }
                }
            }
    }
}
