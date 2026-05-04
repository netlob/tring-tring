//
//  BackendClient.swift
//  Tring Tring
//

import Foundation
import OSLog

/// Legacy error type preserved for `register(...)` callers (DeviceState).
/// New code should catch `APIError` from the v1 endpoints.
enum BackendError: Error {
    case http(status: Int)
    case invalidResponse
    case transport(Error)
}

struct RegisterRequest: Encodable {
    let appleIdentityToken: String
    let rawNonce: String
    let apnsToken: String
    let apnsEnv: String
    let deviceName: String?
}

struct RegisterResponse: Codable {
    let userId: String
    let webhookUrl: String
}

final class BackendClient {
    static let shared = BackendClient()

    private let session: URLSession
    private let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "net")

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Existing SIWA registration (preserved verbatim)

    @discardableResult
    func register(
        appleIdentityToken: String,
        rawNonce: String,
        apnsToken: String,
        apnsEnv: String,
        deviceName: String?
    ) async throws -> RegisterResponse {
        let base = APIBaseURL.currentBaseURL
        // `appendingPathComponent("v1/devices")` percent-encodes the slash to
        // %2F (it treats the whole string as one component), which the server
        // sees as `/v1%2Fdevices` and returns 404. `appending(path:)` (iOS 16+)
        // is the modern API that handles embedded separators correctly.
        guard let url = URL(string: base)?.appending(path: "v1/devices") else {
            throw BackendError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = RegisterRequest(
            appleIdentityToken: appleIdentityToken,
            rawNonce: rawNonce,
            apnsToken: apnsToken,
            apnsEnv: apnsEnv,
            deviceName: deviceName
        )
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

    // MARK: - User details

    func userDetails(bearer: String) async throws -> UserDetailsResponse {
        let request = try buildRequest(
            method: "GET",
            path: "v1/users/\(percentEncode(bearer))",
            bearer: bearer
        )
        return try await send(request, decoding: UserDetailsResponse.self)
    }

    // MARK: - Notification log

    func listNotifications(
        bearer: String,
        limit: Int? = nil,
        before: Int64? = nil
    ) async throws -> ListNotificationsResponse {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }

        let request = try buildRequest(
            method: "GET",
            path: "v1/users/\(percentEncode(bearer))/notifications",
            query: query.isEmpty ? nil : query,
            bearer: bearer
        )
        return try await send(request, decoding: ListNotificationsResponse.self)
    }

    // MARK: - Cancel scheduled

    func cancelScheduled(bearer: String, externalId: String) async throws -> CancelResponse {
        let request = try buildRequest(
            method: "DELETE",
            path: "v1/users/\(percentEncode(bearer))/submittedNotifications/\(percentEncode(externalId))",
            bearer: bearer
        )
        return try await send(request, decoding: CancelResponse.self)
    }

    // MARK: - Templates

    func listTemplates(bearer: String) async throws -> ListTemplatesResponse {
        let request = try buildRequest(
            method: "GET",
            path: "v1/users/\(percentEncode(bearer))/templates",
            bearer: bearer
        )
        return try await send(request, decoding: ListTemplatesResponse.self)
    }

    func putTemplate(
        bearer: String,
        name: String,
        payload: OutgoingNotification
    ) async throws -> Template {
        var request = try buildRequest(
            method: "PUT",
            path: "v1/users/\(percentEncode(bearer))/templates/\(percentEncode(name))",
            bearer: bearer
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(PutTemplateRequest(defaultPayload: payload))
        return try await send(request, decoding: Template.self)
    }

    func deleteTemplate(bearer: String, name: String) async throws {
        let request = try buildRequest(
            method: "DELETE",
            path: "v1/users/\(percentEncode(bearer))/templates/\(percentEncode(name))",
            bearer: bearer
        )
        try await sendNoContent(request)
    }

    // MARK: - Run pending action

    func runPendingAction(
        bearer: String,
        pendingActionId: String,
        idempotencyKey: String?
    ) async throws -> RunPendingActionResponse {
        var request = try buildRequest(
            method: "POST",
            path: "v1/users/\(percentEncode(bearer))/actions/run",
            bearer: bearer
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(
            RunPendingActionRequest(pendingActionId: pendingActionId, idempotencyKey: idempotencyKey)
        )
        return try await send(request, decoding: RunPendingActionResponse.self)
    }

    // MARK: - Execute

    func execute(bearer: String, request executeRequest: ExecuteRequest) async throws -> RunPendingActionResponse {
        var request = try buildRequest(
            method: "POST",
            path: "v1/execute",
            bearer: bearer
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(executeRequest)
        return try await send(request, decoding: RunPendingActionResponse.self)
    }

    // MARK: - Public webhook (no bearer)

    /// Sends to the per-user public webhook. `webhookBase` is the API origin
    /// (e.g. `https://tring-tring.sjoerd.dev`). Returns the raw response body
    /// — empty `{}` for immediate sends, `{identifier, status, sendAt}` for
    /// scheduled/delayed ones.
    func sendViaWebhook(
        webhookBase: URL,
        userId: String,
        name: String,
        payload: OutgoingNotification
    ) async throws -> Data {
        let path = "\(percentEncode(userId))/notifications/\(percentEncode(name))"
        guard let url = webhookBase.appending(path: path) as URL? else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encoder.encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw APIError.transport(urlError)
        } catch {
            throw APIError.invalidResponse
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        log.debug("webhook \(name, privacy: .public) -> \(http.statusCode, privacy: .public)")

        guard (200..<300).contains(http.statusCode) else {
            throw APIErrorMapper.map(status: http.statusCode, data: data)
        }

        return data
    }

    // MARK: - Internals

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private func buildRequest(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        bearer: String?
    ) throws -> URLRequest {
        let base = APIBaseURL.currentBaseURL
        guard var components = URLComponents(string: base) else {
            throw APIError.invalidResponse
        }
        let trimmedBasePath = (components.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combinedPath: String
        if trimmedBasePath.isEmpty {
            combinedPath = "/" + path
        } else {
            combinedPath = "/" + trimmedBasePath + "/" + path
        }
        components.path = combinedPath
        if let query, !query.isEmpty {
            components.queryItems = query
        }

        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decoding: T.Type) async throws -> T {
        let (data, response) = try await perform(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch let decodingError as DecodingError {
            log.error("decode failure for \(String(describing: T.self), privacy: .public)")
            throw APIError.decoding(decodingError)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func sendNoContent(_ request: URLRequest) async throws {
        _ = try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? "?"
        let method = request.httpMethod ?? "?"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            log.error("\(method, privacy: .public) \(path, privacy: .public) transport: \(urlError.code.rawValue, privacy: .public)")
            throw APIError.transport(urlError)
        } catch {
            throw APIError.invalidResponse
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        log.debug("\(method, privacy: .public) \(path, privacy: .public) -> \(http.statusCode, privacy: .public)")

        guard (200..<300).contains(http.statusCode) else {
            throw APIErrorMapper.map(status: http.statusCode, data: data)
        }

        return (data, http)
    }

    private func percentEncode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }
}
