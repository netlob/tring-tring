//
//  PushActionRouter.swift
//  Tring Tring
//

import OSLog
import UIKit
import UserNotifications

@MainActor
final class PushActionRouter {
    static let shared = PushActionRouter()

    private let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "push")

    func handle(response: UNNotificationResponse, deviceState: DeviceState) async {
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        log.debug("response actionIdentifier=\(actionId, privacy: .public)")

        guard let envelope = UserInfoEnvelope.from(userInfo) else {
            log.warning("userInfo did not decode")
            return
        }

        switch actionId {
        case UNNotificationDefaultActionIdentifier:
            if let raw = envelope.url, let url = URL(string: raw) {
                await openURL(url)
            }
        case UNNotificationDismissActionIdentifier:
            return
        default:
            guard let action = lookupAction(in: envelope, byIdentifier: actionId) else {
                log.warning("unknown action identifier \(actionId, privacy: .public)")
                return
            }
            if action.runOnServer == true,
               let pendingActionId = action.pendingActionId,
               let bearer = deviceState.bearerToken {
                await runOnServer(pendingActionId: pendingActionId, bearer: bearer)
            } else if let raw = action.url, let url = URL(string: raw) {
                await openURL(url)
            } else {
                log.warning("action \(actionId, privacy: .public) had no actionable target")
            }
        }
    }

    func handleForegroundPresentation(notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge, .list]
    }

    private func lookupAction(in envelope: UserInfoEnvelope, byIdentifier id: String) -> ActionEnvelope? {
        guard let actions = envelope.actions, !actions.isEmpty else { return nil }
        if let match = actions.first(where: { $0.identifier == id }) {
            return match
        }
        // Fall back to positional lookup when the wire identifier is missing.
        guard id.hasPrefix("act-"),
              let n = Int(id.dropFirst("act-".count)),
              n >= 0, n < actions.count else { return nil }
        return actions[n]
    }

    private func runOnServer(pendingActionId: String, bearer: String) async {
        let key = UUID().uuidString
        do {
            let response = try await BackendClient.shared.runPendingAction(
                bearer: bearer,
                pendingActionId: pendingActionId,
                idempotencyKey: key
            )
            log.info("runOnServer executed=\(response.executed, privacy: .public) status=\(response.status ?? -1, privacy: .public)")
        } catch {
            log.error("runOnServer failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func openURL(_ url: URL) async {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
