//
//  OnboardingWelcomeStep.swift
//  Tring Tring
//

import SwiftUI

struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Theme.spacing.xl) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(Color.brass)
                .padding(Theme.spacing.xl)
                .glassEffect(
                    .regular.tint(Color.brass.opacity(0.20)),
                    in: .circle
                )

            VStack(spacing: Theme.spacing.md) {
                Text("Your personal pager.")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Hit a webhook, get a push. That's it.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.spacing.xl)

            BrandedCard {
                bullet(symbol: "globe", text: "Get notifications anywhere your scripts run.")
                bullet(symbol: "clock.arrow.circlepath", text: "Schedule, delay, cancel — full control.")
                bullet(symbol: "hand.tap.fill", text: "Buttons that act on the server, hands-free.")
            }
            .padding(.horizontal, Theme.spacing.xl)

            Spacer()

            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacing.xs)
            }
            .buttonStyle(.glassProminent)
            .tint(.brass)
            .padding(.horizontal, Theme.spacing.xl)
            .padding(.bottom, Theme.spacing.xxl + Theme.spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func bullet(symbol: String, text: String) -> some View {
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
}

#Preview {
    OnboardingWelcomeStep(onContinue: {})
}
