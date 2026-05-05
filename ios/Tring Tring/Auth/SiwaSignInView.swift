//
//  SiwaSignInView.swift
//  Tring Tring
//

import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

struct SiwaSignInView: View {
    @Environment(DeviceState.self) private var deviceState
    @Environment(\.colorScheme) private var colorScheme

    let showsRevokedNotice: Bool

    @State private var alertMessage: String?
    // Per-tap nonce. Lives on the view, NOT on DeviceState — writing to a
    // shared @Observable here causes spurious view rebuilds during the SIWA
    // sheet and the value can be lost before handleCompletion runs.
    @State private var pendingRawNonce: String?
    @State private var bellPhase: Bool = false

    init(showsRevokedNotice: Bool = false) {
        self.showsRevokedNotice = showsRevokedNotice
    }

    var body: some View {
        ZStack {
            BackdropGlow()

            VStack(spacing: 0) {
                Spacer(minLength: Theme.spacing.xxl)

                Emblem(phase: bellPhase)
                    .padding(.bottom, Theme.spacing.xxl + Theme.spacing.md)

                Wordmark()
                    .padding(.bottom, Theme.spacing.lg)
                    .padding(.horizontal, Theme.spacing.xl)

                if showsRevokedNotice {
                    revokedNotice
                        .padding(.horizontal, Theme.spacing.xl)
                        .padding(.top, Theme.spacing.md)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let alertMessage {
                    ErrorBanner(message: alertMessage) {
                        self.alertMessage = nil
                    }
                    .padding(.horizontal, Theme.spacing.xl)
                    .padding(.top, Theme.spacing.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer(minLength: Theme.spacing.xl)

                SignInWithAppleButton(
                    .signIn,
                    onRequest: configureRequest(_:),
                    onCompletion: handleCompletion(_:)
                )
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius.medium))
                .padding(.horizontal, Theme.spacing.xl)

                Text("Self-hosted, open source, free forever.")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .padding(.top, Theme.spacing.md)
                    .padding(.bottom, Theme.spacing.xl)
            }
        }
        .animation(.smooth(duration: 0.3), value: alertMessage)
        .animation(.smooth(duration: 0.3), value: showsRevokedNotice)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                bellPhase = true
            }
        }
    }

    private var revokedNotice: some View {
        HStack(spacing: Theme.spacing.sm) {
            Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed out from Apple")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                Text("Sign in again to receive notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacing.lg)
        .padding(.vertical, Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.tint(Color.orange.opacity(0.18)),
            in: .rect(cornerRadius: Theme.radius.medium)
        )
    }

    private func configureRequest(_ request: ASAuthorizationAppleIDRequest) {
        let rawNonce = UUID().uuidString
        pendingRawNonce = rawNonce
        request.nonce = sha256Hex(rawNonce)
        request.requestedScopes = [.fullName, .email]
    }

    private func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                alertMessage = "Sign in returned an unexpected credential type."
                pendingRawNonce = nil
                return
            }
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                alertMessage = "Sign in did not return an identity token."
                pendingRawNonce = nil
                return
            }
            guard let rawNonce = pendingRawNonce else {
                alertMessage = "Internal error: missing nonce. Please try again."
                return
            }

            let appleUserSub = credential.user
            let email = credential.email

            alertMessage = nil
            pendingRawNonce = nil

            HapticFeedback.success.fire()

            Task { @MainActor in
                await deviceState.handleAppleSignIn(
                    identityToken: identityToken,
                    rawNonce: rawNonce,
                    appleUserSub: appleUserSub,
                    email: email
                )
            }

        case .failure(let error):
            pendingRawNonce = nil
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                alertMessage = nil
                return
            }
            HapticFeedback.warning.fire()
            alertMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }
}

private struct BackdropGlow: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color.brass.opacity(0.22), .clear],
                center: UnitPoint(x: 0.5, y: 0.18),
                startRadius: 40,
                endRadius: 460
            )
            RadialGradient(
                colors: [Color.slateTeal.opacity(0.10), .clear],
                center: UnitPoint(x: 0.85, y: 0.95),
                startRadius: 40,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct Emblem: View {
    let phase: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.brass.opacity(0.22))
                .frame(width: 220, height: 220)
                .blur(radius: 40)
                .scaleEffect(phase ? 1.05 : 1.0)
                .opacity(phase ? 1.0 : 0.85)

            Image(systemName: "bell.fill")
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(Color.brass)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 132, height: 132)
                .glassEffect(
                    .regular.tint(Color.brass.opacity(0.30)),
                    in: .circle
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.brass.opacity(0.50), Color.brass.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .symbolEffect(.breathe)
        }
    }
}

private struct Wordmark: View {
    var body: some View {
        VStack(spacing: Theme.spacing.sm) {
            Text("Tring Tring")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .tracking(-0.5)
                .multilineTextAlignment(.center)
            Text("Your personal pager.")
                .font(.system(.title3, design: .rounded, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private func sha256Hex(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

#Preview("Light") {
    SiwaSignInView()
        .environment(DeviceState.shared)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SiwaSignInView()
        .environment(DeviceState.shared)
        .preferredColorScheme(.dark)
}

#Preview("Revoked") {
    SiwaSignInView(showsRevokedNotice: true)
        .environment(DeviceState.shared)
}
