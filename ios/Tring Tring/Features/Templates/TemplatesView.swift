//
//  TemplatesView.swift
//  Tring Tring
//

import SwiftUI

struct TemplatesView: View {
    @Environment(DeviceState.self) private var deviceState
    @State private var viewModel = TemplatesViewModel()
    @State private var editorTarget: EditorTarget?
    @State private var pendingDelete: Template?

    init() {}

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Templates")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            openCreate()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.brass)
                        }
                        .accessibilityLabel("New template")
                        .disabled(!isRegistered)
                    }
                }
                .refreshable {
                    await refresh()
                }
                .task(id: bearerKey) {
                    await refresh()
                }
                .sheet(item: $editorTarget) { target in
                    if let bearer = deviceState.bearerToken,
                       case let .registered(userId, _) = deviceState.status,
                       let webhookBase = resolvedWebhookBase {
                        TemplateEditorSheet(
                            existing: target.template,
                            bearer: bearer,
                            userId: userId,
                            webhookBase: webhookBase,
                            viewModel: viewModel,
                            onSaved: { _ in }
                        )
                    }
                }
                .confirmationDialog(
                    pendingDelete.map { "Delete \"\($0.name)\"?" } ?? "Delete this template?",
                    isPresented: deleteConfirmBinding,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let target = pendingDelete {
                            Task { await performDelete(target) }
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDelete = nil
                    }
                } message: {
                    Text("This permanently removes the template from the server.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            if viewModel.templates.isEmpty {
                loadingView
            } else {
                listView
            }
        case .empty:
            emptyView
        case .populated:
            listView
        case .error(let message):
            errorView(message)
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        ScrollView {
            VStack(spacing: Theme.spacing.lg) {
                EmptyState(
                    symbol: "tray",
                    title: "No templates yet",
                    message: "Save common notification configurations to send them with one tap.",
                    action: openCreate,
                    actionTitle: "Add Template"
                )
                .padding(.horizontal, Theme.spacing.lg)
                .padding(.top, Theme.spacing.xl)
            }
        }
        .scrollDisabled(true)
    }

    private func errorView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: Theme.spacing.md) {
                ErrorBanner(message: message) {
                    Task { await refresh() }
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.brass)
            }
            .padding(.horizontal, Theme.spacing.lg)
            .padding(.top, Theme.spacing.xl)
        }
    }

    private var listView: some View {
        List {
            if let transient = viewModel.transientError {
                Section {
                    ErrorBanner(message: transient) {
                        viewModel.dismissTransientError()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            ForEach(viewModel.templates) { template in
                TemplateRow(template: template)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editorTarget = EditorTarget(template: template)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = template
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var bearerKey: String {
        deviceState.bearerToken ?? "no-bearer"
    }

    private var isRegistered: Bool {
        if case .registered = deviceState.status { return true }
        return false
    }

    private var resolvedWebhookBase: URL? {
        URL(string: APIBaseURL.currentBaseURL)
    }

    private func openCreate() {
        guard isRegistered else { return }
        editorTarget = EditorTarget(template: nil)
    }

    private func refresh() async {
        guard let bearer = deviceState.bearerToken else { return }
        await viewModel.load(bearer: bearer)
    }

    private func performDelete(_ template: Template) async {
        defer { pendingDelete = nil }
        guard let bearer = deviceState.bearerToken else { return }
        do {
            try await viewModel.delete(bearer: bearer, name: template.name)
            HapticFeedback.warning.fire()
        } catch {
            viewModel.transientError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct EditorTarget: Identifiable {
    let template: Template?
    var id: String { template?.name ?? "__new__" }
}

private struct TemplateRow: View {
    let template: Template

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        HStack(spacing: Theme.spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                if NameValidation.isValidNotificationName(template.name) {
                    MonoText(template.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(template.name)
                        .font(Theme.typography.body())
                        .lineLimit(1)
                }
                HStack(spacing: Theme.spacing.sm) {
                    Text(actionsLabel)
                        .font(Theme.typography.bodySecondary())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(updatedLabel)
                        .font(Theme.typography.bodySecondary())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var actionsLabel: String {
        let count = template.defaultPayload.actions?.count ?? 0
        return "\(count) action\(count == 1 ? "" : "s")"
    }

    private var updatedLabel: String {
        let date = Date(timeIntervalSince1970: TimeInterval(template.updatedAt))
        return "Updated " + Self.formatter.localizedString(for: date, relativeTo: .now)
    }
}
