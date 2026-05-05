//
//  ActivityView.swift
//  Tring Tring
//

import SwiftUI

struct ActivityView: View {
    @Environment(DeviceState.self) private var deviceState
    @State private var viewModel = ActivityViewModel()
    @State private var selectedRow: NotificationLogRow?
    @State private var didInitialLoad = false

    init() {}

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Activity")
                .toolbarTitleDisplayMode(.large)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task {
            guard !didInitialLoad, let bearer = deviceState.bearerToken else { return }
            didInitialLoad = true
            await viewModel.refresh(bearer: bearer)
        }
        .sheet(item: $selectedRow) { row in
            NotificationDetailSheet(
                row: row,
                onCancel: cancelHandler(for: row)
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if deviceState.bearerToken == nil {
            EmptyState(
                symbol: "lock",
                title: "Sign in to see activity",
                message: "Your notification log appears here once you've registered this device."
            )
            .padding(Theme.spacing.lg)
            .frame(maxHeight: .infinity)
        } else {
            switch viewModel.state {
            case .idle, .loadingFirstPage:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                emptyView
            case .populated:
                listView
            case .error(let message):
                errorView(message: message)
            }
        }
    }

    private var emptyView: some View {
        ScrollView {
            VStack(spacing: Theme.spacing.xl) {
                EmptyState(
                    symbol: "bell",
                    title: "No notifications yet",
                    message: "Send your first notification by hitting your webhook URL.",
                    action: nil,
                    actionTitle: nil
                )

                if let webhookUrl = currentWebhookUrl {
                    BrandedCard(tint: .brass) {
                        WebhookURLBlock(url: webhookUrl)
                    }
                }
            }
            .padding(Theme.spacing.lg)
        }
        .refreshable { await refresh() }
    }

    private var listView: some View {
        List {
            if let message = viewModel.transientError {
                Section {
                    ErrorBanner(message: message) {
                        viewModel.dismissTransientError()
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Theme.spacing.sm, leading: Theme.spacing.lg, bottom: Theme.spacing.sm, trailing: Theme.spacing.lg))
                }
            }

            ForEach(groupedSections, id: \.day) { section in
                Section {
                    ForEach(section.rows) { row in
                        ActivityRowView(row: row)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                HapticFeedback.light.fire()
                                selectedRow = row
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if row.resolvedStatus == .scheduled, let externalId = row.externalId {
                                    Button(role: .destructive) {
                                        Task { await cancelFromSwipe(externalId: externalId) }
                                    } label: {
                                        Label("Cancel", systemImage: "xmark.circle.fill")
                                    }
                                }
                            }
                            .onAppear {
                                if row.id == viewModel.rows.last?.id {
                                    Task { await loadMore() }
                                }
                            }
                    }
                } header: {
                    SectionHeader(section.title)
                }
            }

            if viewModel.isLoadingMore {
                Section {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refresh() }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: Theme.spacing.lg) {
            ErrorBanner(message: message)
            Button("Try again") {
                Task { await refresh() }
            }
            .buttonStyle(.glassProminent)
            .tint(.brass)
        }
        .padding(Theme.spacing.lg)
        .frame(maxHeight: .infinity)
    }

    private var currentWebhookUrl: String? {
        if case .registered(_, let url) = deviceState.status {
            return url
        }
        return nil
    }

    private var groupedSections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.rows) { row in
            calendar.startOfDay(for: row.sentAtDate)
        }
        return grouped
            .map { DaySection(day: $0.key, rows: $0.value.sorted { $0.sentAt > $1.sentAt }) }
            .sorted { $0.day > $1.day }
    }

    private func refresh() async {
        guard let bearer = deviceState.bearerToken else { return }
        await viewModel.refresh(bearer: bearer)
    }

    private func loadMore() async {
        guard let bearer = deviceState.bearerToken else { return }
        await viewModel.loadMore(bearer: bearer)
    }

    private func cancelFromSwipe(externalId: String) async {
        guard let bearer = deviceState.bearerToken else { return }
        do {
            try await viewModel.cancel(bearer: bearer, externalId: externalId)
        } catch {
            // Already surfaced via transientError on subsequent refresh; the
            // cancel() helper itself doesn't mutate transientError on failure
            // so set it here so the user sees what happened.
            viewModel.transientError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func cancelHandler(for row: NotificationLogRow) -> ((String) async throws -> Void)? {
        guard row.resolvedStatus == .scheduled, row.externalId != nil else { return nil }
        guard let bearer = deviceState.bearerToken else { return nil }
        return { externalId in
            try await viewModel.cancel(bearer: bearer, externalId: externalId)
        }
    }
}

private struct DaySection {
    let day: Date
    let rows: [NotificationLogRow]

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }
}
