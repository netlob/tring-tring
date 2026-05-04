//
//  APIModels.swift
//  Tring Tring
//

import Foundation

// MARK: - AnyCodable

/// Type-erased JSON value for arbitrary objects (e.g. urlBackgroundOptions).
/// Encodes/decodes any JSON shape: null, bool, number, string, array, object.
enum AnyCodable: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }
}

// MARK: - Outgoing notification (request body for the public webhook)

struct OutgoingNotification: Codable, Equatable, Sendable {
    var id: String?
    var identifier: String?
    var title: String?
    var text: String?
    var sound: String?
    var threadId: String?
    var isTimeSensitive: Bool?
    var defaultAction: DefaultActionPayload?
    var input: String?
    var image: String?
    var imageData: String?
    var devices: [String]?
    var actions: [ActionPayload]?
    var delay: String?
    var scheduleTimestamp: Int64?

    init(
        id: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        text: String? = nil,
        sound: String? = nil,
        threadId: String? = nil,
        isTimeSensitive: Bool? = nil,
        defaultAction: DefaultActionPayload? = nil,
        input: String? = nil,
        image: String? = nil,
        imageData: String? = nil,
        devices: [String]? = nil,
        actions: [ActionPayload]? = nil,
        delay: String? = nil,
        scheduleTimestamp: Int64? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.text = text
        self.sound = sound
        self.threadId = threadId
        self.isTimeSensitive = isTimeSensitive
        self.defaultAction = defaultAction
        self.input = input
        self.image = image
        self.imageData = imageData
        self.devices = devices
        self.actions = actions
        self.delay = delay
        self.scheduleTimestamp = scheduleTimestamp
    }
}

struct DefaultActionPayload: Codable, Equatable, Sendable {
    var url: String?
    var urlBackgroundOptions: AnyCodable?

    init(url: String? = nil, urlBackgroundOptions: AnyCodable? = nil) {
        self.url = url
        self.urlBackgroundOptions = urlBackgroundOptions
    }
}

struct ActionPayload: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String?
    var url: String?
    var input: String?
    var keepNotification: Bool?
    var runOnServer: Bool?
    var urlBackgroundOptions: AnyCodable?

    init(
        id: UUID = UUID(),
        name: String? = nil,
        url: String? = nil,
        input: String? = nil,
        keepNotification: Bool? = nil,
        runOnServer: Bool? = nil,
        urlBackgroundOptions: AnyCodable? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.input = input
        self.keepNotification = keepNotification
        self.runOnServer = runOnServer
        self.urlBackgroundOptions = urlBackgroundOptions
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, input, keepNotification, runOnServer, urlBackgroundOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.input = try c.decodeIfPresent(String.self, forKey: .input)
        self.keepNotification = try c.decodeIfPresent(Bool.self, forKey: .keepNotification)
        self.runOnServer = try c.decodeIfPresent(Bool.self, forKey: .runOnServer)
        self.urlBackgroundOptions = try c.decodeIfPresent(AnyCodable.self, forKey: .urlBackgroundOptions)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(input, forKey: .input)
        try c.encodeIfPresent(keepNotification, forKey: .keepNotification)
        try c.encodeIfPresent(runOnServer, forKey: .runOnServer)
        try c.encodeIfPresent(urlBackgroundOptions, forKey: .urlBackgroundOptions)
    }
}

// MARK: - User details

struct UserDetailsResponse: Codable, Equatable, Sendable {
    let userId: String
    let appleUserSub: String
    let email: String?
    let isPrivateEmail: Bool
    let createdAt: Int64
    let lastSeenAt: Int64
    let devices: [DeviceSummary]
    let recentLog: [LogEntry]
}

struct DeviceSummary: Codable, Equatable, Identifiable, Sendable {
    let deviceId: String
    let deviceName: String?
    let apnsEnv: String
    let createdAt: Int64
    let lastSeenAt: Int64

    var id: String { deviceId }
}

struct LogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let deviceId: String?
    let name: String?
    let status: String
    let apnsStatus: Int64?
    let apnsReason: String?
    let sentAt: Int64
}

// MARK: - Notification log listing

struct ListNotificationsResponse: Codable, Equatable, Sendable {
    let notifications: [NotificationLogRow]
    let nextBefore: Int64?
}

struct NotificationLogRow: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String?
    let externalId: String?
    let status: String
    let apnsStatus: Int64?
    let apnsReason: String?
    let sentAt: Int64
}

// MARK: - Templates

struct Template: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let defaultPayload: OutgoingNotification
    let createdAt: Int64
    let updatedAt: Int64

    var id: String { name }
}

struct ListTemplatesResponse: Codable, Equatable, Sendable {
    let templates: [Template]
}

struct PutTemplateRequest: Codable, Equatable, Sendable {
    let defaultPayload: OutgoingNotification
}

// MARK: - Cancel scheduled

struct CancelResponse: Codable, Equatable, Sendable {
    let status: String
    let externalId: String
}

// MARK: - Run pending action

struct RunPendingActionRequest: Codable, Equatable, Sendable {
    let pendingActionId: String
    let idempotencyKey: String?
}

struct RunPendingActionResponse: Codable, Equatable, Sendable {
    let executed: Bool
    let status: Int?
    let elapsedMs: Int64?
    let reason: String?
}

// MARK: - Execute

struct ExecuteRequest: Codable, Equatable, Sendable {
    let url: String
    let urlBackgroundOptions: ExecuteUrlBackgroundOptions?
    let online: Bool?
    let name: String?
}

struct ExecuteUrlBackgroundOptions: Codable, Equatable, Sendable {
    let httpMethod: String?
    let httpContentType: String?
    let httpHeader: [ExecuteHttpHeader]?
    let httpBody: AnyCodable?
}

struct ExecuteHttpHeader: Codable, Equatable, Sendable {
    let key: String?
    let value: String?
}

// MARK: - Validation helpers

enum NameValidation {
    static let notificationNamePattern = #"^[A-Za-z0-9._-]{1,64}$"#
    static let identifierPattern = #"^[A-Za-z0-9._-]{1,64}$"#
    static let actionNamePattern = #"^[A-Za-z0-9._\- ]{1,32}$"#

    static func isValidNotificationName(_ s: String) -> Bool {
        matches(s, pattern: notificationNamePattern)
    }

    static func isValidIdentifier(_ s: String) -> Bool {
        matches(s, pattern: identifierPattern)
    }

    static func isValidActionName(_ s: String) -> Bool {
        matches(s, pattern: actionNamePattern)
    }

    private static func matches(_ s: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.firstMatch(in: s, range: range) != nil
    }
}

enum TemplateValidation {
    /// Templates forbid these keys in default_payload per ADR-0018.
    static let forbiddenKeys: Set<String> = ["delay", "scheduleTimestamp", "id", "identifier"]

    /// Returns the first forbidden key found (caller renders an error), or nil.
    static func validate(_ payload: OutgoingNotification) -> String? {
        if payload.delay != nil { return "delay" }
        if payload.scheduleTimestamp != nil { return "scheduleTimestamp" }
        if payload.id != nil { return "id" }
        if payload.identifier != nil { return "identifier" }
        return nil
    }
}
