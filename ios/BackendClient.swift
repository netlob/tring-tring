//
//  BackendClient.swift
//  Tring Tring
//

import Foundation

enum BackendError: Error {
    case http(status: Int)
    case invalidResponse
    case transport(Error)
}

struct RegisterResponse: Decodable {
    let webhookSecret: String
    let webhookUrl: String
}

struct RegisterRequest: Encodable {
    let apnsToken: String
    let apnsEnv: String
    let deviceName: String?
}

enum APIConfig {
    static let defaultBaseURL = "https://tring-tring.sjoerd.dev"
    static let baseURLKey = "apiBaseURL"

    static var currentBaseURL: String {
        let stored = UserDefaults.standard.string(forKey: baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            return stored
        }
        return defaultBaseURL
    }
}

final class BackendClient {
    static let shared = BackendClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func register(apnsToken: String, apnsEnv: String, deviceName: String?) async throws -> RegisterResponse {
        let base = APIConfig.currentBaseURL
        guard let url = URL(string: base)?.appendingPathComponent("v1/devices") else {
            throw BackendError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = RegisterRequest(apnsToken: apnsToken, apnsEnv: apnsEnv, deviceName: deviceName)
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(RegisterResponse.self, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }
}
