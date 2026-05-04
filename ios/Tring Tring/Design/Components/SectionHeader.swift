import SwiftUI

struct SectionHeader: View {
    var title: String
    var accessory: AnyView?

    init(_ title: String, accessory: AnyView? = nil) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.typography.sectionTitle())
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.spacing.md)
            if let accessory {
                accessory
            }
        }
        .padding(.horizontal, Theme.spacing.xs)
    }
}
