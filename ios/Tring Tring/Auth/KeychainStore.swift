//
//  KeychainStore.swift
//  Tring Tring
//

import Foundation
import OSLog
import Security

enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus, op: String)
    case decodingFailure

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status, let op):
            return "Keychain \(op) failed (OSStatus \(status))"
        case .decodingFailure:
            return "Keychain item could not be decoded as UTF-8"
        }
    }
}

final class KeychainStore {
    static let shared = KeychainStore()

    private let service = "dev.sjoerd.tringtring"
    private let userIdAccount = "userId"
    static let legacyUserDefaultsKey = "userId"

    private let log = Logger(subsystem: "dev.sjoerd.tringtring", category: "keychain")

    var userId: String? {
        if let existing = readUserId() {
            return existing
        }
        return migrateLegacyUserIdIfNeeded()
    }

    func setUserId(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.decodingFailure
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userIdAccount,
        ]

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addAttrs = query
            addAttrs[kSecValueData as String] = data
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                log.error("SecItemAdd failed: \(addStatus, privacy: .public)")
                throw KeychainError.unexpectedStatus(addStatus, op: "add")
            }
        default:
            log.error("SecItemUpdate failed: \(updateStatus, privacy: .public)")
            throw KeychainError.unexpectedStatus(updateStatus, op: "update")
        }
    }

    func deleteUserId() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userIdAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log.error("SecItemDelete failed: \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status, op: "delete")
        }
    }

    private func readUserId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userIdAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                log.error("Keychain read decoded as non-utf8")
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            log.error("SecItemCopyMatching failed: \(status, privacy: .public)")
            return nil
        }
    }

    private func migrateLegacyUserIdIfNeeded() -> String? {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Self.legacyUserDefaultsKey),
              !legacy.isEmpty else {
            return nil
        }

        do {
            try setUserId(legacy)
            defaults.removeObject(forKey: Self.legacyUserDefaultsKey)
            log.info("migrated legacy userId from UserDefaults to Keychain")
            return legacy
        } catch {
            log.error("legacy userId migration failed; leaving UserDefaults entry in place")
            return legacy
        }
    }
}
