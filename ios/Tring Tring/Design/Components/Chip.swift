import SwiftUI

struct Chip: View {
    var label: String
    var symbol: String?
    var tint: Color

    init(_ label: String, symbol: String? = nil, tint: Color = .brass) {
        self.label = label
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: Theme.spacing.xs + 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(label)
                .font(Theme.typography.pillLabel())
                .foregroundStyle(.primary)
        }
        .pillStyle(tint: tint)
    }
}
