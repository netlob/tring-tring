import SwiftUI

struct BrandedCard<Content: View>: View {
    var tint: Color
    var radius: CGFloat
    @ViewBuilder var content: () -> Content

    init(
        tint: Color = .brass,
        radius: CGFloat = Theme.radius.medium,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.tint = tint
        self.radius = radius
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.md) {
            content()
        }
        .cardStyle(tint: tint, radius: radius)
    }
}
