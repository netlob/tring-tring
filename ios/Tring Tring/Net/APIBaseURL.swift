//
//  APIBaseURL.swift
//  Tring Tring
//

import Foundation

/// Resolves the backend base URL, allowing a Settings override stored in `UserDefaults`.
enum APIBaseURL {
    static let defaultBaseURL = "https://tring-tring.sjoerd.dev"
    static let baseURLKey = "apiBaseURL"

    static var currentBaseURL: String {
        let stored = UserDefaults.standard.string(forKey: baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            return stored
        }
        return defaultBaseURL
    }

    static func set(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: baseURLKey)
        } else {
            UserDefaults.standard.removeObject(forKey: baseURLKey)
        }
    }
}

@available(*, deprecated, renamed: "APIBaseURL", message: "Use APIBaseURL instead.")
typealias APIConfig = APIBaseURL
