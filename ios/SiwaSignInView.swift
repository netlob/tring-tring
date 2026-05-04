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

    init(showsRevokedNotice: Bool = false) {
        self.showsRevokedNotice = showsRevokedNotice
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Text("Tring Tring")
                    .font(.largeTitle.bold())
                Text("Sign in to get your webhook URL")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            if showsRevokedNotice {
                Text("You signed out from Settings → Apple ID. Sign in again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            SignInWithAppleButton(
                .signIn,
                onRequest: configureRequest(_:),
                onCompletion: handleCompletion(_:)
            )
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .padding(.horizontal, 24)

            if let alertMessage {
                Text(alertMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer().frame(height: 24)
        }
    }

    private func configureRequest(_ request: ASAuthorizationAppleIDRequest) {
        let rawNonce = UUID().uuidString
        deviceState.pendingRawNonce = rawNonce
        request.nonce = sha256Hex(rawNonce)
        request.requestedScopes = [.fullName, .email]
    }

    private func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                alertMessage = "Sign in returned an unexpected credential type."
                deviceState.pendingRawNonce = nil
                return
            }
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                alertMessage = "Sign in did not return an identity token."
                deviceState.pendingRawNonce = nil
                return
            }
            guard let rawNonce = deviceState.pendingRawNonce else {
                alertMessage = "Internal error: missing nonce. Please try again."
                return
            }

            let appleUserSub = credential.user
            let email = credential.email

            alertMessage = nil
            deviceState.pendingRawNonce = nil

            Task { @MainActor in
                await deviceState.handleAppleSignIn(
                    identityToken: identityToken,
                    rawNonce: rawNonce,
                    appleUserSub: appleUserSub,
                    email: email
                )
            }

        case .failure(let error):
            deviceState.pendingRawNonce = nil
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                alertMessage = nil
                return
            }
            alertMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }
}

private func sha256Hex(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

#Preview {
    SiwaSignInView()
        .environment(DeviceState.shared)
}
