//
//  UserInfoEnvelope.swift
//  Tring Tring
//

import Foundation

struct UserInfoEnvelope: Codable, Equatable, Sendable {
    let url: String?
    let input: String?
    let imageURL: String?
    let imageData: String?
    let actions: [ActionEnvelope]?
    let identifier: String?
    let defaultActionOptions: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case url
        case input
        case actions
        case identifier
        case defaultActionOptions
        case imageURL = "image-url"
        case imageData = "image-data"
    }
}

struct ActionEnvelope: Codable, Equatable, Sendable, Identifiable {
    let identifier: String
    let title: String
    let url: String?
    let input: String?
    let keepNotification: Bool?
    let runOnServer: Bool?
    let pendingActionId: String?

    var id: String { identifier }
}

extension UserInfoEnvelope {
    static func from(_ userInfo: [AnyHashable: Any]) -> UserInfoEnvelope? {
        // Strip non-string keys to keep JSONSerialization happy on cross-typed dicts from APNs.
        let stringKeyed = userInfo.reduce(into: [String: Any]()) { acc, pair in
            if let key = pair.key as? String {
                acc[key] = pair.value
            }
        }
        guard JSONSerialization.isValidJSONObject(stringKeyed),
              let data = try? JSONSerialization.data(withJSONObject: stringKeyed, options: []) else {
            return nil
        }
        return try? JSONDecoder().decode(UserInfoEnvelope.self, from: data)
    }
}
