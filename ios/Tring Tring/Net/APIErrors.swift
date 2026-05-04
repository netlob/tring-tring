//
//  APIErrors.swift
//  Tring Tring
//

import Foundation

enum APIError: Error, LocalizedError {
    case transport(URLError)
    case decoding(DecodingError)
    case http(status: Int, message: String?)
    case unauthorized
    case notFound
    case rateLimited(reason: String?)
    case quotaExceeded
    case payloadTooLarge
    case conflict(String?)
    case gone
    case server(status: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .transport(let urlError):
            return "Network error: \(urlError.localizedDescription)"
        case .decoding:
            return "The server returned an unexpected response."
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return "HTTP \(status): \(message)"
            }
            return "HTTP \(status)"
        case .unauthorized:
            return "You're not signed in. Sign in again to continue."
        case .notFound:
            return "Not found."
        case .rateLimited(let reason):
            if let reason, !reason.isEmpty {
                return "Rate limited: \(reason)"
            }
            return "Rate limited. Try again in a moment."
        case .quotaExceeded:
            return "Monthly quota exceeded."
        case .payloadTooLarge:
            return "The notification payload is too large."
        case .conflict(let message):
            if let message, !message.isEmpty {
                return "Conflict: \(message)"
            }
            return "Conflict."
        case .gone:
            return "This device is no longer registered for push."
        case .server(let status, let message):
            if let message, !message.isEmpty {
                return "Server error \(status): \(message)"
            }
            return "Server error \(status)"
        case .invalidResponse:
            return "Invalid response from server."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .transport, .server, .invalidResponse:
            return true
        case .rateLimited:
            return true
        case .http(let status, _):
            return (500...599).contains(status)
        case .decoding, .unauthorized, .notFound, .quotaExceeded,
             .payloadTooLarge, .conflict, .gone:
            return false
        }
    }
}

struct APIErrorBody: Decodable {
    let error: String?
    let message: String?
}

enum APIErrorMapper {
    static func map(status: Int, data: Data) -> APIError {
        let body = decodeBody(data)
        let message = body?.error ?? body?.message

        switch status {
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 409:
            return .conflict(message)
        case 410:
            return .gone
        case 413:
            return .payloadTooLarge
        case 429:
            if let m = message?.lowercased(), m.contains("quota") {
                return .quotaExceeded
            }
            return .rateLimited(reason: message)
        case 500...599:
            return .server(status: status, message: message)
        default:
            return .http(status: status, message: message)
        }
    }

    private static func decodeBody(_ data: Data) -> APIErrorBody? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(APIErrorBody.self, from: data)
    }
}
