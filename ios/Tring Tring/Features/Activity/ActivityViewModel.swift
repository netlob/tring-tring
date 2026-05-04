//
//  ActivityViewModel.swift
//  Tring Tring
//

import Foundation
import OSLog

@Observable
@MainActor
final class ActivityViewModel {
    enum LoadState: Equatable {
        case idle
        case loadingFirstPage
        case populated
        case empty
        case error(String)
    }

    private static let pageLimit = 50
    private static let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "activity")

    var state: LoadState = .idle
    var rows: [NotificationLogRow] = []
    var transientError: String?
    var isLoadingMore: Bool = false
    var hasMore: Bool = true

    private var nextBefore: Int64?
    private var inFlight: Task<Void, Never>?
    private let client: BackendClient

    init(client: BackendClient? = nil) {
        self.client = client ?? .shared
    }

    func refresh(bearer: String) async {
        inFlight?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(bearer: bearer)
        }
        inFlight = task
        await task.value
    }

    func loadMore(bearer: String) async {
        guard hasMore, !isLoadingMore, state == .populated else { return }
        guard let cursor = nextBefore else { return }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performLoadMore(bearer: bearer, before: cursor)
        }
        await task.value
    }

    func cancel(bearer: String, externalId: String) async throws {
        let response: CancelResponse
        do {
            response = try await client.cancelScheduled(bearer: bearer, externalId: externalId)
        } catch {
            HapticFeedback.warning.fire()
            throw error
        }

        if response.status == "cancelled" || response.status == "already_delivered" {
            applyCancellationLocally(externalId: externalId)
            HapticFeedback.warning.fire()
            Task { [weak self] in
                guard let self else { return }
                await self.silentRefresh(bearer: bearer)
            }
        }
    }

    private func performRefresh(bearer: String) async {
        if rows.isEmpty {
            state = .loadingFirstPage
        }
        do {
            let response = try await client.listNotifications(
                bearer: bearer,
                limit: Self.pageLimit,
                before: nil
            )
            if Task.isCancelled { return }
            rows = response.notifications
            nextBefore = response.nextBefore
            hasMore = response.nextBefore != nil
            transientError = nil
            state = response.notifications.isEmpty ? .empty : .populated
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.error("refresh failed: \(message, privacy: .public)")
            if rows.isEmpty {
                state = .error(message)
            } else {
                transientError = message
            }
        }
    }

    private func performLoadMore(bearer: String, before: Int64) async {
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await client.listNotifications(
                bearer: bearer,
                limit: Self.pageLimit,
                before: before
            )
            if Task.isCancelled { return }
            let existingIds = Set(rows.map(\.id))
            let appended = response.notifications.filter { !existingIds.contains($0.id) }
            rows.append(contentsOf: appended)
            nextBefore = response.nextBefore
            hasMore = response.nextBefore != nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.error("loadMore failed: \(message, privacy: .public)")
            transientError = message
        }
    }

    private func silentRefresh(bearer: String) async {
        do {
            let response = try await client.listNotifications(
                bearer: bearer,
                limit: Self.pageLimit,
                before: nil
            )
            if Task.isCancelled { return }
            rows = response.notifications
            nextBefore = response.nextBefore
            hasMore = response.nextBefore != nil
            state = response.notifications.isEmpty ? .empty : .populated
        } catch {
            Self.log.debug("silent refresh suppressed")
        }
    }

    private func applyCancellationLocally(externalId: String) {
        guard let index = rows.firstIndex(where: { $0.externalId == externalId }) else { return }
        let existing = rows[index]
        rows[index] = NotificationLogRow(
            id: existing.id,
            name: existing.name,
            externalId: existing.externalId,
            status: "cancelled",
            apnsStatus: existing.apnsStatus,
            apnsReason: existing.apnsReason,
            sentAt: existing.sentAt
        )
    }

    func dismissTransientError() {
        transientError = nil
    }
}

extension NotificationLogRow {
    var sentAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(sentAt))
    }

    var resolvedStatus: NotificationStatus {
        if let known = NotificationStatus(rawValue: status) {
            return known
        }
        Logger(subsystem: "dev.sjoerd.tringtring", category: "activity")
            .error("unknown status \(status, privacy: .public) for row \(id, privacy: .public)")
        return .failed
    }
}
