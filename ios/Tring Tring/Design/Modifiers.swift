import SwiftUI

private struct CardStyleModifier: ViewModifier {
    var tint: Color
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                .regular.tint(tint.opacity(0.15)),
                in: .rect(cornerRadius: radius)
            )
    }
}

private struct PillStyleModifier: ViewModifier {
    var tint: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.spacing.md)
            .padding(.vertical, Theme.spacing.xs + 2)
            .glassEffect(
                .regular.tint(tint.opacity(0.25)),
                in: .capsule
            )
    }
}

private struct HapticOnAppearModifier: ViewModifier {
    var feedback: HapticFeedback

    func body(content: Content) -> some View {
        content.onAppear { feedback.fire() }
    }
}

extension View {
    func cardStyle(tint: Color = .brass, radius: CGFloat = Theme.radius.medium) -> some View {
        modifier(CardStyleModifier(tint: tint, radius: radius))
    }

    func pillStyle(tint: Color) -> some View {
        modifier(PillStyleModifier(tint: tint))
    }

    func haptic(_ feedback: HapticFeedback) -> some View {
        modifier(HapticOnAppearModifier(feedback: feedback))
    }
}

struct HapticButtonStyle: ButtonStyle {
    var feedback: HapticFeedback = .light

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { feedback.fire() }
            }
    }
}
