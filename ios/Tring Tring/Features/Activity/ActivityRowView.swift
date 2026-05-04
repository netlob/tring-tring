//
//  ActivityRowView.swift
//  Tring Tring
//

import SwiftUI

struct ActivityRowView: View {
    let row: NotificationLogRow

    init(row: NotificationLogRow) {
        self.row = row
    }

    var body: some View {
        HStack(spacing: Theme.spacing.md) {
            StatusPill(status: row.resolvedStatus)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name ?? "Notification")
                    .font(Theme.typography.body())
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let externalId = row.externalId, !externalId.isEmpty {
                    MonoText(externalId)
                        .font(Theme.typography.monoSmall())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Theme.spacing.sm)

            Text(relativeTimeText)
                .font(Theme.typography.bodySecondary())
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, Theme.spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var relativeTimeText: String {
        Self.formatter.localizedString(for: row.sentAtDate, relativeTo: .now)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
