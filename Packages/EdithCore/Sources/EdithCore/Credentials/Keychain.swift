// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(message)"
    }
}

/// Server secrets in the login keychain, one generic password per server.
///
/// Same model as the Linux app's keyring: service `edith-sftp`, account =
/// server id. The secret is the password for password auth, or the key
/// passphrase for key+passphrase auth.
public struct Keychain: Sendable {
    public static let defaultService = "edith-sftp"
    public let service: String

    public init(service: String = Keychain.defaultService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(for serverID: String) throws -> String? {
        var q = query(serverID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &result) {
        case errSecSuccess:
            return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            return nil
        case let status:
            throw KeychainError(status: status)
        }
    }

    public func setSecret(_ secret: String, for serverID: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(serverID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(serverID)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Edith: \(serverID)"
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func deleteSecret(for serverID: String) throws {
        let status = SecItemDelete(query(serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
