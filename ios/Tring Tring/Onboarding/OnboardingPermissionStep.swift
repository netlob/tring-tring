//
//  OnboardingPermissionStep.swift
//  Tring Tring
//

import OSLog
import SwiftUI
import UIKit
import UserNotifications

struct OnboardingPermissionStep: View {
    let onContinue: () -> Void

    @State private var requesting = false

    private let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "onboarding")

    var body: some View {
        VStack(spacing: Theme.spacing.xl) {
            Spacer()

            Image(systemName: "bell.fill")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(Color.brass)
                .padding(Theme.spacing.xl)
                .glassEffect(
                    .regular.tint(Color.brass.opacity(0.20)),
                    in: .circle
                )

            VStack(spacing: Theme.spacing.md) {
                Text("Allow notifications")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("We need permission to deliver your pushes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.spacing.xl)

            BrandedCard {
                row(symbol: "text.bubble.fill", text: "Show alerts on the lock screen and Home Screen.")
                row(symbol: "speaker.wave.2.fill", text: "Play a sound — default or one you choose.")
                row(symbol: "app.badge.fill", text: "Update the app badge with unread counts.")
                row(symbol: "clock.badge.fill", text: "Deliver time-sensitive pushes when needed.")
            }
            .padding(.horizontal, Theme.spacing.xl)

            Spacer()

            VStack(spacing: Theme.spacing.md) {
                Button {
                    requestAuthorization()
                } label: {
                    HStack {
                        if requesting {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text("Allow notifications")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacing.xs)
                }
                .buttonStyle(.glassProminent)
                .tint(.brass)
                .disabled(requesting)

                Button {
                    onContinue()
                } label: {
                    Text("Skip for now")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacing.xs)
                }
                .buttonStyle(.glass)
                .disabled(requesting)
            }
            .padding(.horizontal, Theme.spacing.xl)
            .padding(.bottom, Theme.spacing.xxl + Theme.spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing.md) {
            Image(systemName: symbol)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.brass)
                .frame(width: 22)
            Text(text)
                .font(Theme.typography.body())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func requestAuthorization() {
        requesting = true
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    await MainActor.run {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
                log.info("notification authorization granted=\(granted, privacy: .public)")
            } catch {
                log.error("notification authorization error: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                requesting = false
                onContinue()
            }
        }
    }
}

#Preview {
    OnboardingPermissionStep(onContinue: {})
}
