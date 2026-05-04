//
//  DeviceState.swift
//  Tring Tring
//

import Foundation
import UIKit

@Observable
final class DeviceState {
    @MainActor static let shared = DeviceState()

    private enum Keys {
        static let webhookSecret = "webhookSecret"
        static let webhookUrl = "webhookUrl"
        static let lastRegisteredApiBase = "lastRegisteredApiBase"
        static let lastRegisteredEnv = "lastRegisteredApnsEnv"
        static let lastApnsToken = "lastApnsToken"
    }

    enum Status: Equatable {
        case idle
        case requestingPermission
        case awaitingToken
        case registering
        case registered
        case failed(String)
    }

    var webhookSecret: String?
    var webhookUrl: String?
    var lastRegisteredApiBase: String?
    var status: Status = .idle

    private var lastApnsToken: String?
    private var lastRegisteredEnv: String?

    private var currentApnsEnv: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    @MainActor
    init() {
        let defaults = UserDefaults.standard
        self.webhookSecret = defaults.string(forKey: Keys.webhookSecret)
        self.webhookUrl = defaults.string(forKey: Keys.webhookUrl)
        self.lastRegisteredApiBase = defaults.string(forKey: Keys.lastRegisteredApiBase)
        self.lastRegisteredEnv = defaults.string(forKey: Keys.lastRegisteredEnv)
        self.lastApnsToken = defaults.string(forKey: Keys.lastApnsToken)
        if webhookUrl != nil {
            self.status = .registered
        } else {
            self.status = .awaitingToken
        }
    }

    @MainActor
    func handleAPNsToken(_ token: String) async {
        let defaults = UserDefaults.standard
        defaults.set(token, forKey: Keys.lastApnsToken)
        lastApnsToken = token
        await registerIfNeeded(force: false)
    }

    @MainActor
    func reRegisterIfAPIChanged() async {
        let currentBase = APIConfig.currentBaseURL
        if currentBase != lastRegisteredApiBase {
            await registerIfNeeded(force: true)
        }
    }

    @MainActor
    func registerIfNeeded(force: Bool) async {
        guard let token = lastApnsToken else {
            status = .awaitingToken
            return
        }

        let base = APIConfig.currentBaseURL
        let env = currentApnsEnv
        let alreadyRegistered = base == lastRegisteredApiBase
            && env == lastRegisteredEnv
            && webhookUrl != nil
        if !force && alreadyRegistered {
            status = .registered
            return
        }

        status = .registering
        do {
            let deviceName = await UIDevice.current.name
            let response = try await BackendClient.shared.register(
                apnsToken: token,
                apnsEnv: env,
                deviceName: deviceName
            )
            persist(response: response, base: base, env: env)
            status = .registered
        } catch {
            status = .failed(describe(error))
        }
    }

    @MainActor
    private func persist(response: RegisterResponse, base: String, env: String) {
        let defaults = UserDefaults.standard
        defaults.set(response.webhookSecret, forKey: Keys.webhookSecret)
        defaults.set(response.webhookUrl, forKey: Keys.webhookUrl)
        defaults.set(base, forKey: Keys.lastRegisteredApiBase)
        defaults.set(env, forKey: Keys.lastRegisteredEnv)
        webhookSecret = response.webhookSecret
        webhookUrl = response.webhookUrl
        lastRegisteredApiBase = base
        lastRegisteredEnv = env
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case BackendError.http(let status):
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
