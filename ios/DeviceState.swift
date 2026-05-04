//
//  DeviceState.swift
//  Tring Tring
//

import AuthenticationServices
import Foundation
import UIKit
import UserNotifications

@Observable
@MainActor
final class DeviceState {
    @MainActor static let shared = DeviceState()

    private enum Keys {
        static let userId = "userId"
        static let webhookUrl = "webhookUrl"
        static let appleUserSub = "appleUserSub"
        static let appleEmail = "appleEmail"
        static let lastApnsToken = "lastApnsToken"
        static let lastRegisteredApiBase = "lastRegisteredApiBase"
        static let lastRegisteredApnsEnv = "lastRegisteredApnsEnv"

        // Legacy keys cleaned up on init from prior device-token-only build.
        static let legacyWebhookSecret = "webhookSecret"
    }

    enum AuthStatus: Equatable {
        case signedOut
        case signedInPendingDevice
        case registered(userId: String, webhookUrl: String)
        case appleRevoked
    }

    private(set) var status: AuthStatus = .signedOut
    var lastError: String?

    var pendingRawNonce: String?

    private var userId: String?
    private var webhookUrl: String?
    private var appleUserSub: String?
    private var appleEmail: String?
    private var lastApnsToken: String?
    private var lastRegisteredApiBase: String?
    private var lastRegisteredApnsEnv: String?

    private var pendingIdentityToken: String?
    private var pendingConsumedRawNonce: String?

    private var currentApnsEnv: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    init() {
        let defaults = UserDefaults.standard

        if defaults.string(forKey: Keys.legacyWebhookSecret) != nil {
            defaults.removeObject(forKey: Keys.legacyWebhookSecret)
        }

        self.userId = defaults.string(forKey: Keys.userId)
        self.webhookUrl = defaults.string(forKey: Keys.webhookUrl)
        self.appleUserSub = defaults.string(forKey: Keys.appleUserSub)
        self.appleEmail = defaults.string(forKey: Keys.appleEmail)
        self.lastApnsToken = defaults.string(forKey: Keys.lastApnsToken)
        self.lastRegisteredApiBase = defaults.string(forKey: Keys.lastRegisteredApiBase)
        self.lastRegisteredApnsEnv = defaults.string(forKey: Keys.lastRegisteredApnsEnv)

        self.status = computeInitialStatus()
    }

    private func computeInitialStatus() -> AuthStatus {
        guard appleUserSub != nil else { return .signedOut }
        if let userId, let webhookUrl {
            return .registered(userId: userId, webhookUrl: webhookUrl)
        }
        return .signedInPendingDevice
    }

    func handleAppleSignIn(
        identityToken: String,
        rawNonce: String,
        appleUserSub: String,
        email: String?
    ) async {
        let defaults = UserDefaults.standard
        defaults.set(appleUserSub, forKey: Keys.appleUserSub)
        self.appleUserSub = appleUserSub

        if let email, !email.isEmpty {
            defaults.set(email, forKey: Keys.appleEmail)
            self.appleEmail = email
        }

        self.pendingIdentityToken = identityToken
        self.pendingConsumedRawNonce = rawNonce
        self.pendingRawNonce = nil
        self.status = .signedInPendingDevice
        self.lastError = nil

        await requestNotificationPermissionAndRegister()

        if let token = lastApnsToken {
            await attemptRegister(apnsToken: token)
        }
    }

    private func requestNotificationPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                lastError = "Push notifications permission denied. Enable it in Settings."
            }
        } catch {
            lastError = "Notification authorization error: \(error.localizedDescription)"
        }
    }

    func handleAPNsToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        defaults.set(token, forKey: Keys.lastApnsToken)
        self.lastApnsToken = token

        await attemptRegister(apnsToken: token)
    }

    private func attemptRegister(apnsToken: String) async {
        guard pendingIdentityToken != nil, pendingConsumedRawNonce != nil else {
            return
        }

        guard appleUserSub != nil else {
            return
        }

        await performRegister(apnsToken: apnsToken)
    }

    private func performRegister(apnsToken: String) async {
        guard let identityToken = pendingIdentityToken,
              let rawNonce = pendingConsumedRawNonce else {
            return
        }

        let base = APIConfig.currentBaseURL
        let env = currentApnsEnv
        let deviceName = UIDevice.current.name

        do {
            let response = try await BackendClient.shared.register(
                appleIdentityToken: identityToken,
                rawNonce: rawNonce,
                apnsToken: apnsToken,
                apnsEnv: env,
                deviceName: deviceName
            )
            persistRegistration(response: response, base: base, env: env)
            status = .registered(userId: response.userId, webhookUrl: response.webhookUrl)
            lastError = nil
        } catch {
            let described = describe(error)
            lastError = described
            print("registration failed: \(described)")
            // Stay in .signedInPendingDevice so the Retry button can re-attempt.
            status = .signedInPendingDevice
        }
    }

    func retryRegistration() async {
        guard let token = lastApnsToken else {
            await requestNotificationPermissionAndRegister()
            return
        }
        if pendingIdentityToken == nil {
            // Identity token was consumed and we're already registered server-side
            // for a different baseURL; re-do via reRegisterIfAPIChanged path is not
            // possible without a fresh SIWA. Force the user back to sign-in.
            lastError = "Please sign in with Apple again to register this device."
            return
        }
        await performRegister(apnsToken: token)
    }

    func reRegisterIfAPIChanged() async {
        let currentBase = APIConfig.currentBaseURL
        let env = currentApnsEnv
        if currentBase == lastRegisteredApiBase && env == lastRegisteredApnsEnv {
            return
        }
        guard let token = lastApnsToken else { return }

        if pendingIdentityToken != nil {
            await performRegister(apnsToken: token)
        } else {
            // We have no fresh identity token. The new backend won't accept us
            // until the user signs in again. Drop registration state but keep
            // the appleUserSub so the user can re-auth without re-typing.
            clearRegistration()
            status = .signedInPendingDevice
            lastError = "API changed. Sign in again to re-register this device."
        }
    }

    func checkAppleCredentialState() async {
        guard let sub = appleUserSub else { return }

        let provider = ASAuthorizationAppleIDProvider()
        let state: ASAuthorizationAppleIDProvider.CredentialState
        do {
            state = try await provider.credentialState(forUserID: sub)
        } catch {
            print("credentialState error: \(error.localizedDescription)")
            return
        }

        switch state {
        case .authorized:
            if let userId, let webhookUrl {
                status = .registered(userId: userId, webhookUrl: webhookUrl)
            } else {
                status = .signedInPendingDevice
            }
        case .revoked, .notFound:
            signOutLocally()
            status = .appleRevoked
        case .transferred:
            // Family Sharing edge case; treat as still authorized for now.
            break
        @unknown default:
            break
        }
    }

    func signOutLocally() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.userId)
        defaults.removeObject(forKey: Keys.webhookUrl)
        defaults.removeObject(forKey: Keys.appleUserSub)
        defaults.removeObject(forKey: Keys.appleEmail)
        defaults.removeObject(forKey: Keys.lastApnsToken)
        defaults.removeObject(forKey: Keys.lastRegisteredApiBase)
        defaults.removeObject(forKey: Keys.lastRegisteredApnsEnv)

        self.userId = nil
        self.webhookUrl = nil
        self.appleUserSub = nil
        self.appleEmail = nil
        self.lastApnsToken = nil
        self.lastRegisteredApiBase = nil
        self.lastRegisteredApnsEnv = nil
        self.pendingIdentityToken = nil
        self.pendingConsumedRawNonce = nil
        self.pendingRawNonce = nil
        self.lastError = nil
        self.status = .signedOut
    }

    private func persistRegistration(response: RegisterResponse, base: String, env: String) {
        let defaults = UserDefaults.standard
        defaults.set(response.userId, forKey: Keys.userId)
        defaults.set(response.webhookUrl, forKey: Keys.webhookUrl)
        defaults.set(base, forKey: Keys.lastRegisteredApiBase)
        defaults.set(env, forKey: Keys.lastRegisteredApnsEnv)

        self.userId = response.userId
        self.webhookUrl = response.webhookUrl
        self.lastRegisteredApiBase = base
        self.lastRegisteredApnsEnv = env
    }

    private func clearRegistration() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.userId)
        defaults.removeObject(forKey: Keys.webhookUrl)
        defaults.removeObject(forKey: Keys.lastRegisteredApiBase)
        defaults.removeObject(forKey: Keys.lastRegisteredApnsEnv)

        self.userId = nil
        self.webhookUrl = nil
        self.lastRegisteredApiBase = nil
        self.lastRegisteredApnsEnv = nil
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case BackendError.http(let status):
            if status == 401 {
                return "Server rejected sign-in (401). Try signing in again."
            }
            return "Server returned HTTP \(status)"
        case BackendError.invalidResponse:
            return "Invalid response from server"
        case BackendError.transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }
}
