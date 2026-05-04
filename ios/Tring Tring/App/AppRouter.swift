//
//  AppRouter.swift
//  Tring Tring
//

import SwiftUI

struct AppRouter: View {
    @Environment(DeviceState.self) private var deviceState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("didOnboard") private var didOnboard: Bool = false

    var body: some View {
        Group {
            switch deviceState.status {
            case .signedOut:
                SiwaSignInView()
            case .appleRevoked:
                SiwaSignInView(showsRevokedNotice: true)
            case .signedInPendingDevice:
                RegistrationProgressView()
            case .registered:
                if didOnboard {
                    HomeView()
                } else {
                    OnboardingFlow(onComplete: { didOnboard = true })
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await deviceState.checkAppleCredentialState()
                    await deviceState.reRegisterIfAPIChanged()
                }
            }
        }
    }
}

private struct RegistrationProgressView: View {
    @Environment(DeviceState.self) private var deviceState

    var body: some View {
        VStack(spacing: Theme.spacing.xl) {
            Spacer()
            BrandedCard {
                HStack(spacing: Theme.spacing.lg) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.brass)
                    VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                        Text("Registering this device")
                            .font(Theme.typography.cardTitle())
                        Text("Hooking up to Apple Push and your webhook URL.")
                            .font(Theme.typography.bodySecondary())
                            .foregroundStyle(.secondary)
                        if let error = deviceState.lastError {
                            Text(error)
                                .font(Theme.typography.bodySecondary())
                                .foregroundStyle(.red)
                                .padding(.top, Theme.spacing.xs)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.spacing.xl)
            Spacer()
            HStack(spacing: Theme.spacing.md) {
                Button("Retry") {
                    Task { await deviceState.retryRegistration() }
                }
                .buttonStyle(.glassProminent)
                .tint(.brass)
                Button("Sign out") {
                    deviceState.signOutLocally()
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, Theme.spacing.xl)
            .padding(.bottom, Theme.spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.brass.opacity(0.12), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}

#Preview {
    AppRouter()
        .environment(DeviceState.shared)
}
