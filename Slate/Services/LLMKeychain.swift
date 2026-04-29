//
//  LLMKeychain.swift
//  Slate
//
//  Reads/writes the Anthropic API key from the macOS Keychain. The key
//  never lives in source, never lives in a config file we ship — only in
//  Keychain, scoped to this app's bundle identifier.
//

import Foundation
import Security

enum LLMKeychain {
    /// Service identifier — must match the app's bundle prefix so the
    /// key is sandboxed to Slate.
    private static let service = "com.eenmachines.slate.anthropic"
    private static let account = "default"

    enum KeychainError: Error, CustomStringConvertible {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)

        var description: String {
            switch self {
            case .saveFailed(let s):
                return "Keychain save failed (OSStatus \(s)). \(Self.message(for: s))"
            case .loadFailed(let s):
                return "Keychain load failed (OSStatus \(s)). \(Self.message(for: s))"
            }
        }

        private static func message(for status: OSStatus) -> String {
            if let cf = SecCopyErrorMessageString(status, nil) {
                return cf as String
            }
            return ""
        }
    }

    /// Save (or replace) the API key.
    static func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)

        let baseQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]

        // Wipe any existing entry first so we don't have to handle the
        // "already exists" branch separately.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String]      = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Returns the stored API key, or `nil` if the user hasn't set one yet.
    static func loadAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.loadFailed(status)
        }
        return key
    }

    /// Delete the stored API key.
    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
