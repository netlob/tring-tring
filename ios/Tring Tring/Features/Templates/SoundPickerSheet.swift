//
//  SoundPickerSheet.swift
//  Tring Tring
//

import SwiftUI

struct SoundPickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(SoundCatalog.all) { sound in
                    Button {
                        selection = sound.name
                        HapticFeedback.light.fire()
                        dismiss()
                    } label: {
                        HStack {
                            Text(sound.displayLabel)
                                .foregroundStyle(.primary)
                            Spacer()
                            if sound.name == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.brass)
                                    .font(.system(.body, weight: .semibold))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.thinMaterial)
    }
}
