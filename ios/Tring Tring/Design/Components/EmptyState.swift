import SwiftUI

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var action: (() -> Void)?
    var actionTitle: String?

    init(
        symbol: String,
        title: String,
        message: String,
        action: (() -> Void)? = nil,
        actionTitle: String? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
        self.actionTitle = actionTitle
    }

    var body: some View {
        VStack(spacing: Theme.spacing.lg) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.brass)
                .padding(Theme.spacing.lg)
                .glassEffect(
                    .regular.tint(Color.brass.opacity(0.18)),
                    in: .circle
                )
            VStack(spacing: Theme.spacing.sm) {
                Text(title)
                    .font(Theme.typography.sectionTitle())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Theme.typography.bodySecondary())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .tint(.brass)
            }
        }
        .padding(Theme.spacing.xl)
        .frame(maxWidth: .infinity)
        .cardStyle(tint: .brass, radius: Theme.radius.large)
    }
}
