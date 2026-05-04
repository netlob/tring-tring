import SwiftUI

struct StatusPill: View {
    var status: NotificationStatus

    init(status: NotificationStatus) {
        self.status = status
    }

    var body: some View {
        HStack(spacing: Theme.spacing.xs + 2) {
            Image(systemName: status.symbol)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(status.tint)
            Text(status.label)
                .font(Theme.typography.pillLabel())
                .foregroundStyle(.primary)
        }
        .pillStyle(tint: status.tint)
    }
}
