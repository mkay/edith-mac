// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import CLibssh2
import CommonCrypto
import CryptoKit
import Foundation

public enum SecretsError: Error, LocalizedError, Equatable {
    case wrongPassphrase
    case unsupported
    case damaged

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase: String(localized: "Wrong passphrase.", bundle: .module)
        case .unsupported: String(localized: "This file's saved passwords are in a format this version can't read.", bundle: .module)
        case .damaged: String(localized: "The saved passwords in this file are damaged.", bundle: .module)
        }
    }
}

/// The encrypted passwords in a server export: `{server id: password}` as
/// JSON, encrypted with Fernet under a key derived from a passphrase with
/// scrypt. Byte-compatible with the Linux app's servers_transfer.py.
public struct SecretsBlob: Codable, Equatable, Sendable {
    public var kdf: String
    public var n: Int
    public var r: Int
    public var p: Int
    /// Standard base64.
    public var salt: String
    /// A Fernet token (URL-safe base64).
    public var data: String

    /// The Linux app's parameters: about 100 ms per derivation.
    public static let defaultN = 1 << 15, defaultR = 8, defaultP = 1

    public func decrypt(passphrase: String) throws -> [String: String] {
        guard kdf == "scrypt" else { throw SecretsError.unsupported }
        guard let saltBytes = Data(base64Encoded: salt) else { throw SecretsError.damaged }
        let key = try scrypt(passphrase: passphrase, salt: saltBytes, n: n, r: r, p: p)
        let plain = try fernetDecrypt(token: data, key: key)
        guard let secrets = try? JSONSerialization.jsonObject(with: plain) as? [String: String] else {
            throw SecretsError.damaged
        }
        return secrets
    }

    public static func encrypt(_ secrets: [String: String], passphrase: String) throws -> SecretsBlob {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = try scrypt(passphrase: passphrase, salt: salt, n: defaultN, r: defaultR, p: defaultP)
        let token = try fernetEncrypt(try JSONSerialization.data(withJSONObject: secrets), key: key)
        return SecretsBlob(kdf: "scrypt", n: defaultN, r: defaultR, p: defaultP, salt: salt.base64EncodedString(), data: token)
    }
}

// MARK: - scrypt

/// 32 bytes of scrypt output, as Python's `Scrypt(length=32)`.
///
/// The parameters come from the file, so they're bounded: a crafted export
/// mustn't be able to ask for gigabytes of memory.
func scrypt(passphrase: String, salt: Data, n: Int, r: Int, p: Int, length: Int = 32) throws -> Data {
    guard n > 1, n & (n - 1) == 0, n <= 1 << 20, (1...32).contains(r), (1...16).contains(p) else {
        throw SecretsError.unsupported
    }
    let maxMemory = UInt64(128 * r * (n + p + 2))
    var key = Data(count: length)
    let password = Array(passphrase.utf8)
    let ok = key.withUnsafeMutableBytes { out in
        salt.withUnsafeBytes { saltBytes in
            EVP_PBE_scrypt(password, password.count,
                           saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                           UInt64(n), UInt64(r), UInt64(p), maxMemory,
                           out.bindMemory(to: UInt8.self).baseAddress, length)
        }
    }
    guard ok == 1 else { throw SecretsError.unsupported }
    return key
}

// MARK: - Fernet

/// Decrypts a Fernet token (version 0x80): the first half of the 32-byte key
/// signs with HMAC-SHA256, the second half encrypts with AES-128-CBC.
/// The token's timestamp isn't checked; exports don't expire.
func fernetDecrypt(token: String, key: Data) throws -> Data {
    guard key.count == 32, let raw = base64URLDecode(token), raw.count >= 1 + 8 + 16 + 16 + 32, raw.first == 0x80 else {
        throw SecretsError.damaged
    }
    let signed = raw.prefix(raw.count - 32)
    let mac = raw.suffix(32)
    // A wrong passphrase gives a wrong key, which shows up here first.
    guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: signed, using: SymmetricKey(data: key.prefix(16))) else {
        throw SecretsError.wrongPassphrase
    }
    let iv = raw.dropFirst(9).prefix(16)
    let ciphertext = signed.dropFirst(25)
    return try aes128CBC(CCOperation(kCCDecrypt), key: key.suffix(16), iv: iv, data: ciphertext)
}

func fernetEncrypt(_ plain: Data, key: Data, iv: Data? = nil, timestamp: UInt64 = UInt64(Date().timeIntervalSince1970)) throws -> String {
    let iv = iv ?? Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    var token = Data([0x80])
    token.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
    token.append(iv)
    token.append(try aes128CBC(CCOperation(kCCEncrypt), key: key.suffix(16), iv: iv, data: plain))
    token.append(contentsOf: HMAC<SHA256>.authenticationCode(for: token, using: SymmetricKey(data: key.prefix(16))))
    return token.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
}

private func aes128CBC(_ operation: CCOperation, key: Data, iv: Data, data: Data) throws -> Data {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = out.withUnsafeMutableBytes { outBytes in
        data.withUnsafeBytes { inBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, data.count, outBytes.baseAddress, outBytes.count, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else { throw SecretsError.damaged }
    return out.prefix(moved)
}

private func base64URLDecode(_ s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b += String(repeating: "=", count: (4 - b.count % 4) % 4)
    return Data(base64Encoded: b)
}
