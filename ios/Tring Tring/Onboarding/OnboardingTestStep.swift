//
//  OnboardingTestStep.swift
//  Tring Tring
//

import OSLog
import SwiftUI

struct OnboardingTestStep: View {
    let onContinue: () -> Void

    @Environment(DeviceState.self) private var deviceState

    @State private var sending = false
    @State private var sentSuccess = false
    @State private var errorMessage: String?

    private let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "onboarding")

    private var registered: (userId: String, webhookUrl: String)? {
        if case .registered(let userId, let webhookUrl) = deviceState.status {
            return (userId, webhookUrl)
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing.xl) {
                Spacer(minLength: Theme.spacing.xxl)

                Image(systemName: bellSymbolName)
                    .font(.system(size: 96, weight: .semibold))
                    .foregroundStyle(Color.brass)
                    .padding(Theme.spacing.xl)
                    .glassEffect(
                        .regular.tint(Color.brass.opacity(0.20)),
                        in: .circle
                    )
                    .symbolEffect(.bounce, value: sentSuccess)

                VStack(spacing: Theme.spacing.md) {
                    Text("Try it out")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text("Send yourself a test push.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Theme.spacing.xl)

                if let webhookUrl = registered?.webhookUrl {
                    BrandedCard {
                        WebhookURLBlock(url: webhookUrl)
                    }
                    .padding(.horizontal, Theme.spacing.xl)
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                        .padding(.horizontal, Theme.spacing.xl)
                }

                VStack(spacing: Theme.spacing.md) {
                    Button {
                        sendTest()
                    } label: {
                        HStack {
                            if sending {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(testButtonLabel)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacing.xs)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.brass)
                    .disabled(sending || registered == nil)

                    Button {
                        onContinue()
                    } label: {
                        Text("Get started")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacing.xs)
                    }
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, Theme.spacing.xl)
                .padding(.bottom, Theme.spacing.xxl + Theme.spacing.lg)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var bellSymbolName: String {
        UIImage(systemName: "bell.badge.waveform.fill") != nil
            ? "bell.badge.waveform.fill"
            : "bell.badge.fill"
    }

    private var testButtonLabel: String {
        if sending { return "Sending…" }
        if sentSuccess { return "Sent — check your lock screen" }
        return "Send a test"
    }

    private func sendTest() {
        guard let registered, let webhookBase = URL(string: APIBaseURL.currentBaseURL) else {
            errorMessage = "Webhook URL not yet available."
            return
        }
        sending = true
        errorMessage = nil
        Task {
            do {
                try await TestSender.sendSelfTest(
                    webhookBase: webhookBase,
                    userId: registered.userId,
                    name: "welcome",
                    title: "Welcome to tring-tring",
                    text: "If you see this, your pager works.",
                    sound: "default"
                )
                await MainActor.run {
                    sending = false
                    sentSuccess = true
                    HapticFeedback.success.fire()
                }
            } catch {
                log.error("self-test failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    sending = false
                    if let api = error as? APIError {
                        errorMessage = api.errorDescription ?? "Send failed."
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    HapticFeedback.warning.fire()
                }
            }
        }
    }
}

#Preview {
    OnboardingTestStep(onContinue: {})
        .environment(DeviceState.shared)
}
