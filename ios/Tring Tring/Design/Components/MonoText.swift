import SwiftUI

struct MonoText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.typography.mono())
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }
}
