//
//  TestSender.swift
//  Tring Tring
//

import Foundation
import OSLog

enum TestSender {
    private static let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "test-sender")

    static func sendSelfTest(
        webhookBase: URL,
        userId: String,
        name: String = "self-test",
        title: String,
        text: String,
        sound: String? = "default"
    ) async throws {
        let payload = OutgoingNotification(
            identifier: "tt-self-test-\(UUID().uuidString)",
            title: title,
            text: text,
            sound: sound
        )
        let prefix = String(userId.prefix(8))
        log.info("self-test send name=\(name, privacy: .public) user=\(prefix, privacy: .public)")
        _ = try await BackendClient.shared.sendViaWebhook(
            webhookBase: webhookBase,
            userId: userId,
            name: name,
            payload: payload
        )
    }
}
