//
//  NotificationDetailSheet.swift
//  Tring Tring
//

import SwiftUI

struct NotificationDetailSheet: View {
    let row: NotificationLogRow
    let onCancel: ((String) async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isCancelling = false

    init(
        row: NotificationLogRow,
        onCancel: ((String) async throws -> Void)? = nil
    ) {
        self.row = row
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        ErrorBanner(message: errorMessage) {
                            self.errorMessage = nil
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        StatusPill(status: row.resolvedStatus)
                            .scaleEffect(1.15)
                            .padding(.vertical, Theme.spacing.sm)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    if let name = row.name, !name.isEmpty {
                        MonoText(name)
                    } else {
                        Text("Unnamed")
                            .foregroundStyle(.secondary)
                    }
                }

                if let externalId = row.externalId, !externalId.isEmpty {
                    Section("Identifier") {
                        MonoText(externalId)
                    }
                }

                Section("Sent at") {
                    Text(row.sentAtDate.formatted(date: .complete, time: .standard))
                        .monospacedDigit()
                }

                if row.apnsStatus != nil || row.apnsReason != nil {
                    Section("APNs result") {
                        if let status = row.apnsStatus {
                            LabeledContent("Status") {
                                MonoText(String(status))
                            }
                        }
                        if let reason = row.apnsReason, !reason.isEmpty {
                            LabeledContent("Reason") {
                                MonoText(reason)
                            }
                        }
                    }
                }

                if row.resolvedStatus == .scheduled, let externalId = row.externalId, onCancel != nil {
                    Section {
                        Button(role: .destructive) {
                            Task { await performCancel(externalId: externalId) }
                        } label: {
                            HStack {
                                if isCancelling {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                Text(isCancelling ? "Cancelling..." : "Cancel scheduled notification")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isCancelling)
                    }
                }
            }
            .navigationTitle("Notification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
    }

    private func performCancel(externalId: String) async {
        guard let onCancel else { return }
        isCancelling = true
        defer { isCancelling = false }
        do {
            try await onCancel(externalId)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
