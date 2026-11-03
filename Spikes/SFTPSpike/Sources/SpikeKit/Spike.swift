// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Command-line options shared by both spike binaries.
///
///     sftp-spike-<impl> --host H [--port 22] --user U
///         [--password-env VAR | --key PATH [--passphrase-env VAR] | --agent]
///         [--known-hosts PATH] [--list PATH] [--download REMOTE] [--exec CMD]
///
/// Secrets come from environment variables so they never land in shell history.
public struct SpikeOptions: Sendable {
    public enum Auth: Sendable {
        case password(String)
        case key(path: String, passphrase: String?)
        case agent
    }

    public var host = ""
    public var port = 22
    public var user = ""
    public var auth: Auth = .agent
    public var knownHosts = NSString(string: "~/.ssh/known_hosts").expandingTildeInPath
    public var list: String?
    public var download: String?
    public var exec: String?

    public static func parse(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> SpikeOptions {
        var o = SpikeOptions()
        var keyPath: String?
        var passphrase: String?
        var it = args.makeIterator()
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("\(flag) needs a value") }
            return v
        }
        while let arg = it.next() {
            switch arg {
            case "--host": o.host = value(arg)
            case "--port": o.port = Int(value(arg)) ?? 22
            case "--user": o.user = value(arg)
            case "--password-env":
                let name = value(arg)
                guard let pw = ProcessInfo.processInfo.environment[name] else { fail("$\(name) is not set") }
                o.auth = .password(pw)
            case "--key": keyPath = NSString(string: value(arg)).expandingTildeInPath
            case "--passphrase-env":
                let name = value(arg)
                guard let pp = ProcessInfo.processInfo.environment[name] else { fail("$\(name) is not set") }
                passphrase = pp
            case "--agent": o.auth = .agent
            case "--known-hosts": o.knownHosts = NSString(string: value(arg)).expandingTildeInPath
            case "--list": o.list = value(arg)
            case "--download": o.download = value(arg)
            case "--exec": o.exec = value(arg)
            default: fail("unknown argument \(arg)")
            }
        }
        if let keyPath { o.auth = .key(path: keyPath, passphrase: passphrase) }
        if o.host.isEmpty || o.user.isEmpty { fail("--host and --user are required") }
        return o
    }
}

public enum HostKeyStatus: String, Sendable {
    case match, mismatch, notFound = "not found", unchecked
}

/// What each backend implements. Kept deliberately close to the shape the
/// real RemoteFileSystem protocol will have.
public protocol SpikeClient {
    /// Connects and authenticates. Returns the host key's type, its OpenSSH
    /// style SHA256 fingerprint, and how it compares with known_hosts.
    mutating func connect(_ o: SpikeOptions) async throws -> (keyType: String, fingerprint: String, status: HostKeyStatus)
    mutating func list(_ path: String) async throws -> [(name: String, size: UInt64, isDir: Bool)]
    /// Streams a file to `local`, returning bytes written.
    mutating func download(_ remote: String, to local: URL) async throws -> UInt64
    mutating func exec(_ command: String) async throws -> (status: Int, stdout: String, stderr: String)
    mutating func close() async
}

public struct SpikeError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

/// Runs every requested check against `client`, printing one line per step.
/// Each step reports independently, so one failure doesn't hide the others.
public func runSpike<C: SpikeClient>(_ name: String, _ client: inout C) async {
    let o = SpikeOptions.parse()
    print("[\(name)] \(o.user)@\(o.host):\(o.port) auth=\(describe(o.auth))")

    let clock = ContinuousClock()
    do {
        var hk: (keyType: String, fingerprint: String, status: HostKeyStatus)!
        let t = try await clock.measure { hk = try await client.connect(o) }
        print("  connect+auth  ok   \(ms(t))  hostkey=\(hk.keyType) \(hk.fingerprint) known_hosts=\(hk.status.rawValue)")
    } catch {
        print("  connect+auth  FAIL \(error)")
        exit(1)
    }

    if let path = o.list {
        do {
            var entries: [(name: String, size: UInt64, isDir: Bool)] = []
            let t = try await clock.measure { entries = try await client.list(path) }
            let dirs = entries.filter(\.isDir).count
            print("  list          ok   \(ms(t))  \(entries.count) entries (\(dirs) dirs) in \(path)")
        } catch {
            print("  list          FAIL \(error)")
        }
    }

    if let remote = o.download {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        do {
            var bytes: UInt64 = 0
            let t = try await clock.measure { bytes = try await client.download(remote, to: local) }
            let secs = Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18
            let mbps = Double(bytes) / 1_048_576 / max(secs, 0.000_001)
            print("  download      ok   \(ms(t))  \(bytes) bytes, \(String(format: "%.1f", mbps)) MB/s")
        } catch {
            print("  download      FAIL \(error)")
        }
    }

    if let command = o.exec {
        do {
            var r: (status: Int, stdout: String, stderr: String)!
            let t = try await clock.measure { r = try await client.exec(command) }
            let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
            print("  exec          ok   \(ms(t))  status=\(r.status) stdout=\"\(out)\"")
        } catch {
            print("  exec          FAIL \(error)")
        }
    }

    await client.close()
}

private func describe(_ auth: SpikeOptions.Auth) -> String {
    switch auth {
    case .password: "password"
    case .key(let path, let pp): "key(\((path as NSString).lastPathComponent)\(pp == nil ? "" : ", passphrase"))"
    case .agent: "agent"
    }
}

private func ms(_ d: Duration) -> String {
    let v = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    return String(format: "%7.1f ms", v)
}

/// OpenSSH's fingerprint format: "SHA256:" plus unpadded base64.
public func openSSHFingerprint(sha256 digest: some Collection<UInt8>) -> String {
    "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
}
