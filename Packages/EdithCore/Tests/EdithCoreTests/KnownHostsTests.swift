// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import EdithCore

private let keyA = Data("key-a".utf8)
private let keyB = Data("key-b".utf8)
private var a64: String { keyA.base64EncodedString() }
private var b64: String { keyB.base64EncodedString() }

/// The hashed form `ssh-keygen -H` writes for `name`.
private func hashed(_ name: String, salt: Data = Data((0..<20).map { UInt8($0) })) -> String {
    let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
    return "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
}

@Test func plainEntriesMatchAndMismatch() {
    let kh = KnownHosts(contents: """
    # comment
    example.com,10.0.0.1 ssh-ed25519 \(a64)
    """)
    #expect(kh.status(host: "example.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .match)
    #expect(kh.status(host: "10.0.0.1", port: 22, keyType: "ssh-ed25519", key: keyA) == .match)
    #expect(kh.status(host: "EXAMPLE.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .match)
    #expect(kh.status(host: "example.com", port: 22, keyType: "ssh-ed25519", key: keyB) == .mismatch)
    #expect(kh.status(host: "example.com", port: 22, keyType: "ssh-rsa", key: keyB) == .notFound(otherTypes: ["ssh-ed25519"]))
    #expect(kh.status(host: "other.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .notFound(otherTypes: []))
}

@Test func nonStandardPortsUseBracketForm() {
    let kh = KnownHosts(contents: "[example.com]:2222 ssh-ed25519 \(a64)")
    #expect(kh.status(host: "example.com", port: 2222, keyType: "ssh-ed25519", key: keyA) == .match)
    #expect(kh.status(host: "example.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .notFound(otherTypes: []))
    #expect(KnownHosts.line(host: "h", port: 2222, keyType: "t", key: keyA) == "[h]:2222 t \(a64)")
    #expect(KnownHosts.line(host: "h", port: 22, keyType: "t", key: keyA) == "h t \(a64)")
}

@Test func hashedEntries() {
    let kh = KnownHosts(contents: """
    \(hashed("example.com")) ssh-ed25519 \(a64)
    \(hashed("[example.com]:2222")) ssh-rsa \(b64)
    """)
    #expect(kh.status(host: "example.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .match)
    #expect(kh.status(host: "example.com", port: 2222, keyType: "ssh-rsa", key: keyB) == .match)
    #expect(kh.status(host: "example.org", port: 22, keyType: "ssh-ed25519", key: keyA) == .notFound(otherTypes: []))
}

@Test func wildcardsAndNegation() {
    let kh = KnownHosts(contents: "*.example.com,!bad.example.com,web?.test ssh-ed25519 \(a64)")
    #expect(kh.status(host: "a.example.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .match)
    #expect(kh.status(host: "bad.example.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .notFound(otherTypes: []))
    #expect(kh.status(host: "web1.test", port: 22, keyType: "ssh-ed25519", key: keyA) == .match)
    #expect(kh.status(host: "web10.test", port: 22, keyType: "ssh-ed25519", key: keyA) == .notFound(otherTypes: []))
}

@Test func revokedWinsAndCertAuthorityIsSkipped() {
    let kh = KnownHosts(contents: """
    example.com ssh-ed25519 \(a64)
    @revoked * ssh-ed25519 \(a64)
    @cert-authority *.example.com ssh-rsa \(b64)
    """)
    #expect(kh.status(host: "example.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .revoked)
    #expect(kh.knownKeyTypes(host: "a.example.com", port: 22) == [])
}

@Test func knownKeyTypesKeepFileOrder() {
    let kh = KnownHosts(contents: """
    example.com ssh-rsa \(b64)
    example.com ssh-ed25519 \(a64)
    example.com ssh-rsa \(a64)
    """)
    #expect(kh.knownKeyTypes(host: "example.com", port: 22) == ["ssh-rsa", "ssh-ed25519"])
}

@Test func storeReadsBothFilesAndWritesOnlyItsOwn() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "kh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let user = dir.appending(path: "user_known_hosts")
    try "example.com ssh-ed25519 \(a64)\n".write(to: user, atomically: true, encoding: .utf8)

    let store = HostKeyStore(userFile: user, appFile: dir.appending(path: "app/known_hosts"))
    #expect(store.status(host: "example.com", port: 22, keyType: "ssh-ed25519", key: keyA) == .match)
    try store.add(host: "other.com", port: 2222, keyType: "ssh-rsa", key: keyB)
    try store.add(host: "third.com", port: 22, keyType: "ssh-rsa", key: keyB)
    #expect(store.status(host: "other.com", port: 2222, keyType: "ssh-rsa", key: keyB) == .match)
    #expect(store.status(host: "third.com", port: 22, keyType: "ssh-rsa", key: keyB) == .match)
    #expect(try String(contentsOf: user, encoding: .utf8) == "example.com ssh-ed25519 \(a64)\n")
}

@Test func wildcardMatching() {
    #expect(wildcardMatch("*", "anything"))
    #expect(wildcardMatch("a*c", "abbbc"))
    #expect(wildcardMatch("a*c", "ac"))
    #expect(!wildcardMatch("a*c", "acb"))
    #expect(wildcardMatch("?b", "ab"))
    #expect(!wildcardMatch("?b", "b"))
}
