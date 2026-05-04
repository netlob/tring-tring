//
//  SoundsPreviewSection.swift
//  Tring Tring
//

import OSLog
import SwiftUI

struct SoundsPreviewSection: View {
    var webhookUrl: String?
    var userId: String?

    @State private var inFlight: Set<String> = []
    @State private var recentlySent: Set<String> = []
    @State private var lastError: String?

    private let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "settings")

    var body: some View {
        Section {
            ForEach(SoundCatalog.all) { sound in
                SoundRow(
                    sound: sound,
                    state: rowState(for: sound.name),
                    enabled: webhookUrl != nil && userId != nil
                ) {
                    Task { await fire(sound) }
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
        } header: {
            Text("Sounds preview")
        } footer: {
            Text("Tap a sound to send yourself a test push. If a sound's audio file isn't bundled yet, iOS plays the default sound.")
        }
    }

    private func rowState(for name: String) -> SoundRowState {
        if inFlight.contains(name) { return .sending }
        if recentlySent.contains(name) { return .sent }
        return .idle
    }

    private func fire(_ sound: SoundCatalog.Sound) async {
        guard let webhookUrl, let userId else { return }
        guard let webhookBase = baseURL(from: webhookUrl) else {
            lastError = "Webhook URL is not a valid base URL."
            return
        }

        HapticFeedback.light.fire()
        lastError = nil
        inFlight.insert(sound.name)
        defer { inFlight.remove(sound.name) }

        let payload = OutgoingNotification(
            title: "Sound test: \(sound.displayLabel)",
            text: "Testing the \(sound.displayLabel.lowercased()) sound.",
            sound: sound.name
        )

        do {
            _ = try await BackendClient.shared.sendViaWebhook(
                webhookBase: webhookBase,
                userId: userId,
                name: "tt-sound-preview",
                payload: payload
            )
            recentlySent.insert(sound.name)
            HapticFeedback.success.fire()
            try? await Task.sleep(for: .seconds(2))
            recentlySent.remove(sound.name)
        } catch let error as APIError {
            lastError = error.errorDescription ?? "Send failed."
            log.error("sound preview failed: \(String(describing: error), privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("sound preview failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func baseURL(from webhookUrl: String) -> URL? {
        guard let components = URLComponents(string: webhookUrl),
              let scheme = components.scheme,
              let host = components.host else {
            return nil
        }
        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = components.port
        return base.url
    }
}

enum SoundRowState {
    case idle
    case sending
    case sent
}

private struct SoundRow: View {
    var sound: SoundCatalog.Sound
    var state: SoundRowState
    var enabled: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.spacing.md) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.brass)
                    .frame(width: 28)

                Text(sound.displayLabel)
                    .font(Theme.typography.body())
                    .foregroundStyle(.primary)

                Spacer()

                trailingAccessory
            }
            .padding(.vertical, Theme.spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || state == .sending)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        switch state {
        case .idle:
            Image(systemName: "paperplane.fill")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
        case .sending:
            ProgressView()
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(Theme.typography.pillLabel())
                .foregroundStyle(.brass)
        }
    }
}
