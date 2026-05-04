import SwiftUI

enum Theme {
    enum spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum radius {
        static let small: CGFloat = 12
        static let medium: CGFloat = 20
        static let large: CGFloat = 28
        static let pill: CGFloat = 999
    }

    enum typography {
        static func screenTitle() -> Font {
            .system(.largeTitle, design: .rounded, weight: .bold)
        }

        static func sectionTitle() -> Font {
            .system(.title3, design: .rounded, weight: .bold)
        }

        static func cardTitle() -> Font {
            .system(.headline, design: .rounded, weight: .semibold)
        }

        static func body() -> Font {
            .system(.body)
        }

        static func bodySecondary() -> Font {
            .system(.footnote)
        }

        static func mono() -> Font {
            .system(.callout, design: .monospaced).monospacedDigit()
        }

        static func monoSmall() -> Font {
            .system(.caption, design: .monospaced).monospacedDigit()
        }

        static func pillLabel() -> Font {
            .system(.caption, design: .rounded, weight: .semibold)
        }
    }
}

enum NotificationStatus: String {
    case sent
    case failed
    case rateLimited = "rate_limited"
    case noDevices = "no_devices"
    case scheduled
    case cancelled

    var symbol: String {
        switch self {
        case .sent: return "bell.fill"
        case .failed: return "bell.slash.fill"
        case .scheduled: return "clock.fill"
        case .cancelled: return "xmark.circle.fill"
        case .noDevices: return "iphone.slash"
        case .rateLimited: return "clock.badge.exclamationmark.fill"
        }
    }

    var tint: Color {
        switch self {
        case .sent: return .brass
        case .failed: return .red
        case .scheduled: return .slateTeal
        case .cancelled: return .gray
        case .noDevices: return .gray
        case .rateLimited: return .orange
        }
    }

    var label: String {
        switch self {
        case .sent: return "Sent"
        case .failed: return "Failed"
        case .scheduled: return "Scheduled"
        case .cancelled: return "Cancelled"
        case .noDevices: return "No devices"
        case .rateLimited: return "Rate limited"
        }
    }
}

enum HapticFeedback {
    case success
    case warning
    case light
    case soft

    func fire() {
        switch self {
        case .success:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        case .warning:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        case .light:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        case .soft:
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.impactOccurred()
        }
    }
}
