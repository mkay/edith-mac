// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// What a known_hosts lookup concluded about a server's host key.
public enum HostKeyStatus: Equatable, Sendable {
    case match
    /// Keys of this type are recorded for the host, but none is this key.
    case mismatch
    /// The key is listed under `@revoked`.
    case revoked
    /// Nothing recorded for this key type. `otherTypes` are the key types
    /// that are known, if any, which a trust prompt should mention.
    case notFound(otherTypes: [String])
}

/// A parsed OpenSSH known_hosts file.
///
/// Supports what OpenSSH writes and what people commonly hand-edit: plain
/// and hashed (`|1|salt|hash`) names, `[host]:port`, comma lists, `*` and
/// `?` wildcards, `!` negation and `@revoked`. `@cert-authority` lines are
/// skipped, since certificate host keys aren't supported.
public struct KnownHosts: Sendable {
    struct Entry: Sendable {
        enum Names: Sendable {
            case patterns([String])
            case hashed(salt: Data, hash: Data)
        }

        var names: Names
        var revoked: Bool
        var keyType: String
        var key: String  // base64 key blob, as written

        func matches(_ hostName: String) -> Bool {
            switch names {
            case .hashed(let salt, let hash):
                let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(hostName.utf8), using: SymmetricKey(data: salt))
                return Data(mac) == hash
            case .patterns(let patterns):
                var matched = false
                for pattern in patterns {
                    if pattern.hasPrefix("!") {
                        if wildcardMatch(String(pattern.dropFirst()), hostName) { return false }
                    } else if wildcardMatch(pattern, hostName) {
                        matched = true
                    }
                }
                return matched
            }
        }
    }

    var entries: [Entry]

    public init(contents: String) {
        entries = contents.split(whereSeparator: \.isNewline).compactMap { Self.parse(String($0)) }
    }

    public init(fileURL: URL) {
        self.init(contents: (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
    }

    /// The name OpenSSH records: `host`, or `[host]:port` off port 22.
    public static func hostName(_ host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// One known_hosts line for this key, in plain (unhashed) form.
    public static func line(host: String, port: Int, keyType: String, key: Data) -> String {
        "\(hostName(host, port: port)) \(keyType) \(key.base64EncodedString())"
    }

    public func status(host: String, port: Int, keyType: String, key: Data) -> HostKeyStatus {
        let name = Self.hostName(host, port: port)
        let blob = key.base64EncodedString()
        let relevant = entries.filter { $0.matches(name) }

        if relevant.contains(where: { $0.revoked && $0.key == blob }) { return .revoked }
        let current = relevant.filter { !$0.revoked }
        if current.contains(where: { $0.keyType == keyType && $0.key == blob }) { return .match }
        if current.contains(where: { $0.keyType == keyType }) { return .mismatch }
        return .notFound(otherTypes: knownKeyTypes(in: current))
    }

    /// Key types recorded for the host, in file order, without duplicates.
    /// Used to ask the server for a key type we can actually check.
    public func knownKeyTypes(host: String, port: Int) -> [String] {
        let name = Self.hostName(host, port: port)
        return knownKeyTypes(in: entries.filter { !$0.revoked && $0.matches(name) })
    }

    private func knownKeyTypes(in entries: [Entry]) -> [String] {
        var seen: [String] = []
        for e in entries where !seen.contains(e.keyType) { seen.append(e.keyType) }
        return seen
    }

    static func parse(_ line: String) -> Entry? {
        var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = fields.first, !first.hasPrefix("#") else { return nil }

        var revoked = false
        if first.hasPrefix("@") {
            guard first == "@revoked" else { return nil }  // @cert-authority
            revoked = true
            fields.removeFirst()
        }
        guard fields.count >= 3 else { return nil }

        let names: Entry.Names
        if fields[0].hasPrefix("|1|") {
            let parts = fields[0].split(separator: "|")
            guard parts.count == 3,
                  let salt = Data(base64Encoded: String(parts[1])),
                  let hash = Data(base64Encoded: String(parts[2]))
            else { return nil }
            names = .hashed(salt: salt, hash: hash)
        } else {
            names = .patterns(fields[0].split(separator: ",").map(String.init))
        }
        return Entry(names: names, revoked: revoked, keyType: fields[1], key: fields[2])
    }
}

/// OpenSSH-style glob: `*` is any run of characters, `?` exactly one.
/// Host names compare case-insensitively.
func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern.lowercased()), t = Array(text.lowercased())
    var pi = 0, ti = 0
    var star = -1, mark = 0
    while ti < t.count {
        if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
            pi += 1; ti += 1
        } else if pi < p.count, p[pi] == "*" {
            star = pi; mark = ti; pi += 1
        } else if star >= 0 {
            pi = star + 1; mark += 1; ti = mark
        } else {
            return false
        }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
}

/// The known_hosts files Edith checks: the user's own `~/.ssh/known_hosts`,
/// read only, plus Edith's file, where keys accepted in the app are added.
/// Edith never writes to `~/.ssh`.
public final class HostKeyStore: Sendable {
    public let userFile: URL
    public let appFile: URL

    public static var defaultAppFile: URL {
        URL.applicationSupportDirectory.appending(path: "Edith/known_hosts")
    }

    public init(
        userFile: URL = URL.homeDirectory.appending(path: ".ssh/known_hosts"),
        appFile: URL = HostKeyStore.defaultAppFile
    ) {
        self.userFile = userFile
        self.appFile = appFile
    }

    var knownHosts: KnownHosts {
        let user = (try? String(contentsOf: userFile, encoding: .utf8)) ?? ""
        let app = (try? String(contentsOf: appFile, encoding: .utf8)) ?? ""
        return KnownHosts(contents: user + "\n" + app)
    }

    public func status(host: String, port: Int, keyType: String, key: Data) -> HostKeyStatus {
        knownHosts.status(host: host, port: port, keyType: keyType, key: key)
    }

    public func knownKeyTypes(host: String, port: Int) -> [String] {
        knownHosts.knownKeyTypes(host: host, port: port)
    }

    /// Records a key the user accepted.
    public func add(host: String, port: Int, keyType: String, key: Data) throws {
        let line = KnownHosts.line(host: host, port: port, keyType: keyType, key: key) + "\n"
        try FileManager.default.createDirectory(at: appFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: appFile) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: appFile)
        }
    }
}
