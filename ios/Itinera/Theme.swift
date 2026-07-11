import SwiftUI
import UIKit

enum Theme {
    static let brandStart = Color(red: 0.05, green: 0.55, blue: 0.79)
    static let brandEnd = Color(red: 0.33, green: 0.27, blue: 0.90)

    static let gradient = LinearGradient(
        colors: [brandStart, brandEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Accent per activity type, used for timeline dots and icons.
    static func color(forActivityType type: String?) -> Color {
        switch type?.lowercased() {
        case "food": return .orange
        case "culture": return .purple
        case "nature": return .green
        case "shopping": return .pink
        default: return brandStart
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

extension View {
    func cardBackground() -> some View {
        modifier(CardBackground())
    }
}

enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

enum Format {
    /// 2_340_000 -> "2.3M", 12_400 -> "12K"
    static func compactCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
                .replacingOccurrences(of: ".0M", with: "M")
        case 1_000...:
            return "\(value / 1_000)K"
        default:
            return "\(value)"
        }
    }

    static func dateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: end)
    }

    /// "In 12 days", "Ongoing", or nil for past trips.
    static func countdown(to start: Date, end: Date) -> String? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        if today > endDay { return nil }
        if today >= startDay { return "Ongoing" }
        let days = calendar.dateComponents([.day], from: today, to: startDay).day ?? 0
        return days == 1 ? "Tomorrow" : "In \(days) days"
    }
}
