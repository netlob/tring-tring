import SwiftUI

struct ErrorBanner: View {
    var message: String
    var onDismiss: (() -> Void)?

    init(message: String, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(Theme.typography.bodySecondary())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Theme.spacing.md)
        .glassEffect(
            .regular.tint(Color.red.opacity(0.20)),
            in: .rect(cornerRadius: Theme.radius.small)
        )
    }
}
