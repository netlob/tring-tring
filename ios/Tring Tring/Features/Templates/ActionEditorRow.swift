//
//  ActionEditorRow.swift
//  Tring Tring
//

import SwiftUI

struct ActionEditorRow: View {
    @Binding var action: ActionPayload
    var index: Int
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack {
                Text("Action \(index + 1)")
                    .font(Theme.typography.cardTitle())
                    .foregroundStyle(.primary)
                Spacer()
                if action.runOnServer == true {
                    Chip("Run on server", symbol: "server.rack", tint: .slateTeal)
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .accessibilityLabel("Delete action")
            }

            TextField("Action name", text: nameBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextField("URL", text: urlBinding)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Input prompt (optional)", text: inputBinding)

            Toggle("Keep notification", isOn: keepNotificationBinding)

            Toggle("Run on server", isOn: runOnServerBinding)
                .tint(action.runOnServer == true ? .slateTeal : .accentColor)
        }
        .padding(.vertical, Theme.spacing.xs)
    }

    private var nameError: String? {
        guard let name = action.name, !name.isEmpty else { return nil }
        return NameValidation.isValidActionName(name) ? nil : "Use 1–32 chars: letters, digits, dot, underscore, dash, space."
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { action.name ?? "" },
            set: { action.name = $0.isEmpty ? nil : $0 }
        )
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { action.url ?? "" },
            set: { action.url = $0.isEmpty ? nil : $0 }
        )
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { action.input ?? "" },
            set: { action.input = $0.isEmpty ? nil : $0 }
        )
    }

    private var keepNotificationBinding: Binding<Bool> {
        Binding(
            get: { action.keepNotification ?? false },
            set: { action.keepNotification = $0 ? true : nil }
        )
    }

    private var runOnServerBinding: Binding<Bool> {
        Binding(
            get: { action.runOnServer ?? false },
            set: { action.runOnServer = $0 ? true : nil }
        )
    }
}
