// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

private func hex(_ s: String) -> Data {
    let digits = s.filter(\.isHexDigit)
    return Data(stride(from: 0, to: digits.count, by: 2).map { i in
        UInt8(digits[digits.index(digits.startIndex, offsetBy: i)...].prefix(2), radix: 16)!
    })
}

/// RFC 7914 §12. PBKDF2's output prefix doesn't depend on its length, so
/// the first 32 bytes of the published 64 must match.
@Test func scryptMatchesRFC7914() throws {
    let a = try scrypt(passphrase: "password", salt: Data("NaCl".utf8), n: 1024, r: 8, p: 16)
    #expect(a == hex("fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"))
    let b = try scrypt(passphrase: "pleaseletmein", salt: Data("SodiumChloride".utf8), n: 16384, r: 8, p: 1)
    #expect(b == hex("7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2"))
}

@Test func scryptRejectsUnreasonableParameters() {
    for (n, r, p) in [(1000, 8, 1), (1 << 21, 8, 1), (1024, 0, 1), (1024, 8, 99)] {
        #expect(throws: SecretsError.unsupported) { try scrypt(passphrase: "x", salt: Data(), n: n, r: r, p: p) }
    }
}

/// The Fernet spec's own vector (github.com/fernet/spec, generate.json).
@Test func fernetMatchesSpec() throws {
    let key = try #require(Data(base64Encoded: "cw/0x689RpI+jtRR7oE8h/eQsKImvJapLeSbXpwF4e4="))
    let token = "gAAAAAAdwJ6wAAECAwQFBgcICQoLDA0ODy021cpGVWKZ_eEwCGM4BLLF_5CV9dOPmrhuVUPgJobwOz7JcbmrR64jVmpU4IwqDA=="
    let made = try fernetEncrypt(Data("hello".utf8), key: key, iv: Data(0..<16), timestamp: 499_162_800)
    #expect(made == token)
    #expect(try fernetDecrypt(token: token, key: key) == Data("hello".utf8))
}

@Test func blobRoundTripAndWrongPassphrase() throws {
    let secrets = ["6f1c2a7e-0d1b-4c55-9a51-2f7d3e8b9c01": "hunter2", "x": "ünïcödé"]
    let blob = try SecretsBlob.encrypt(secrets, passphrase: "correct horse")
    #expect(blob.n == 1 << 15 && blob.r == 8 && blob.p == 1 && blob.kdf == "scrypt")
    #expect(try blob.decrypt(passphrase: "correct horse") == secrets)
    #expect(throws: SecretsError.wrongPassphrase) { try blob.decrypt(passphrase: "wrong") }

    var tampered = blob
    tampered.kdf = "argon2"
    #expect(throws: SecretsError.unsupported) { try tampered.decrypt(passphrase: "correct horse") }
    tampered = blob
    tampered.data = "not a token"
    #expect(throws: SecretsError.damaged) { try tampered.decrypt(passphrase: "correct horse") }
}

@Test func exportFileWithSecretsParses() throws {
    let blob = try SecretsBlob.encrypt(["a": "pw"], passphrase: "p")
    let json: [String: Any] = [
        "edith_export": 1, "exported": "2026-10-28 12:00:00",
        "servers": [["id": "a", "host": "h"]], "folders": [],
        "secrets": ["kdf": blob.kdf, "n": blob.n, "r": blob.r, "p": blob.p, "salt": blob.salt, "data": blob.data],
    ]
    let url = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let file = try ConfigStore.parseServerFile(url)
    #expect(file.servers.map(\.id) == ["a"])
    #expect(try file.secrets?.decrypt(passphrase: "p") == ["a": "pw"])
}
