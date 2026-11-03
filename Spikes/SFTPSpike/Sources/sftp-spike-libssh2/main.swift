// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import CLibssh2
import CryptoKit
import Darwin
import Foundation
import SpikeKit

/// libssh2 in blocking mode on a plain BSD socket. The real client will run
/// this inside an actor on its own thread; for a spike, blocking is fine.
struct LibSSH2Client: SpikeClient {
    var sock: Int32 = -1
    var session: OpaquePointer?
    var sftp: OpaquePointer?

    func lastError() -> SpikeError {
        var msg: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        let code = libssh2_session_last_error(session, &msg, &len, 0)
        let text = msg.map { String(cString: $0) } ?? "unknown"
        if code == LIBSSH2_ERROR_SFTP_PROTOCOL, let sftp {
            return SpikeError("\(text) (sftp status \(libssh2_sftp_last_error(sftp)))")
        }
        return SpikeError("\(text) (\(code))")
    }

    mutating func connect(_ o: SpikeOptions) async throws -> (keyType: String, fingerprint: String, status: HostKeyStatus) {
        libssh2_init(0)
        sock = try openSocket(host: o.host, port: o.port)

        session = libssh2_session_init_ex(nil, nil, nil, nil)
        libssh2_session_set_blocking(session, 1)
        // libssh2 prefers ECDSA host keys; OpenSSH prefers ed25519. Matching
        // OpenSSH's order means we get the key type known_hosts already holds.
        // The real client should go further and put the types known_hosts has
        // for this host first, as OpenSSH does.
        libssh2_session_method_pref(session, LIBSSH2_METHOD_HOSTKEY,
            "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256,ssh-rsa")
        guard libssh2_session_handshake(session, sock) == 0 else { throw lastError() }

        // Host key, checked against known_hosts the way OpenSSH would.
        var keyLen = 0
        var keyType: Int32 = 0
        guard let key = libssh2_session_hostkey(session, &keyLen, &keyType) else { throw lastError() }
        let keyBytes = UnsafeRawBufferPointer(start: key, count: keyLen)
        let fingerprint = openSSHFingerprint(sha256: Array(SHA256.hash(data: keyBytes)))
        let status = checkKnownHosts(o, key: key, keyLen: keyLen, keyType: keyType)

        try authenticate(o)
        sftp = libssh2_sftp_init(session)
        guard sftp != nil else { throw lastError() }
        return (hostKeyName(keyType), fingerprint, status)
    }

    func checkKnownHosts(_ o: SpikeOptions, key: UnsafePointer<CChar>, keyLen: Int, keyType: Int32) -> HostKeyStatus {
        guard let kh = libssh2_knownhost_init(session) else { return .unchecked }
        defer { libssh2_knownhost_free(kh) }
        guard libssh2_knownhost_readfile(kh, o.knownHosts, LIBSSH2_KNOWNHOST_FILE_OPENSSH) >= 0 else { return .unchecked }

        let keyBit: Int32 = switch keyType {
        case LIBSSH2_HOSTKEY_TYPE_RSA: LIBSSH2_KNOWNHOST_KEY_SSHRSA
        case LIBSSH2_HOSTKEY_TYPE_ED25519: LIBSSH2_KNOWNHOST_KEY_ED25519
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: LIBSSH2_KNOWNHOST_KEY_ECDSA_256
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: LIBSSH2_KNOWNHOST_KEY_ECDSA_384
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: LIBSSH2_KNOWNHOST_KEY_ECDSA_521
        default: LIBSSH2_KNOWNHOST_KEY_UNKNOWN
        }
        let mask = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW | keyBit
        var found: UnsafeMutablePointer<libssh2_knownhost>?
        return switch libssh2_knownhost_checkp(kh, o.host, Int32(o.port), key, keyLen, mask, &found) {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH: .match
        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH: .mismatch
        case LIBSSH2_KNOWNHOST_CHECK_NOTFOUND: .notFound
        default: .unchecked
        }
    }

    func authenticate(_ o: SpikeOptions) throws {
        let user = o.user
        let userLen = UInt32(user.utf8.count)
        switch o.auth {
        case .password(let pw):
            guard libssh2_userauth_password_ex(session, user, userLen, pw, UInt32(pw.utf8.count), nil) == 0
            else { throw lastError() }
        case .key(let path, let passphrase):
            // A nil public key path makes libssh2 derive it from the private key.
            guard libssh2_userauth_publickey_fromfile_ex(session, user, userLen, nil, path, passphrase) == 0
            else { throw lastError() }
        case .agent:
            guard let agent = libssh2_agent_init(session) else { throw lastError() }
            defer { libssh2_agent_disconnect(agent); libssh2_agent_free(agent) }
            guard libssh2_agent_connect(agent) == 0, libssh2_agent_list_identities(agent) == 0
            else { throw lastError() }
            var prev: UnsafeMutablePointer<libssh2_agent_publickey>?
            var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
            while libssh2_agent_get_identity(agent, &identity, prev) == 0 {
                if libssh2_agent_userauth(agent, user, identity) == 0 { return }
                prev = identity
            }
            throw SpikeError("all agent keys were rejected")
        }
    }

    mutating func list(_ path: String) async throws -> [(name: String, size: UInt64, isDir: Bool)] {
        guard let handle = libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR)
        else { throw lastError() }
        defer { libssh2_sftp_close_handle(handle) }

        var entries: [(name: String, size: UInt64, isDir: Bool)] = []
        var name = [CChar](repeating: 0, count: 1024)
        var longEntry = [CChar](repeating: 0, count: 1024)
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        while true {
            let n = libssh2_sftp_readdir_ex(handle, &name, name.count, &longEntry, longEntry.count, &attrs)
            if n == 0 { break }
            guard n > 0 else { throw lastError() }
            let s = String(cString: name)
            if s == "." || s == ".." { continue }
            let isDir = attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
                && attrs.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFDIR)
            entries.append((s, attrs.filesize, isDir))
        }
        return entries
    }

    mutating func download(_ remote: String, to local: URL) async throws -> UInt64 {
        guard let handle = libssh2_sftp_open_ex(sftp, remote, UInt32(remote.utf8.count),
                                                UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
        else { throw lastError() }
        defer { libssh2_sftp_close_handle(handle) }

        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }

        // A large buffer lets libssh2 1.11 keep several reads in flight.
        var buffer = [CChar](repeating: 0, count: 1 << 20)
        var total: UInt64 = 0
        while true {
            let n = libssh2_sftp_read(handle, &buffer, buffer.count)
            if n == 0 { break }
            guard n > 0 else { throw lastError() }
            buffer.withUnsafeBytes { out.write(Data($0.prefix(n))) }
            total += UInt64(n)
        }
        return total
    }

    mutating func exec(_ command: String) async throws -> (status: Int, stdout: String, stderr: String) {
        guard let channel = libssh2_channel_open_ex(session, "session", 7,
                                                    channelWindowDefault, channelPacketDefault, nil, 0)
        else { throw lastError() }
        defer { libssh2_channel_free(channel) }
        guard libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count)) == 0
        else { throw lastError() }

        func drain(_ stream: Int32) -> String {
            var data = Data()
            var buffer = [CChar](repeating: 0, count: 65536)
            while true {
                let n = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
                if n <= 0 { break }
                buffer.withUnsafeBytes { data.append(contentsOf: $0.prefix(n)) }
            }
            return String(decoding: data, as: UTF8.self)
        }
        let stdout = drain(0)
        let stderr = drain(SSH_EXTENDED_DATA_STDERR)
        libssh2_channel_close(channel)
        libssh2_channel_wait_closed(channel)
        return (Int(libssh2_channel_get_exit_status(channel)), stdout, stderr)
    }

    mutating func close() async {
        if let sftp { libssh2_sftp_shutdown(sftp) }
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
        }
        if sock >= 0 { Darwin.close(sock) }
        libssh2_exit()
    }
}

func openSocket(host: String, port: Int) throws -> Int32 {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                         ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, String(port), &hints, &res)
    guard rc == 0, let first = res else { throw SpikeError("resolve \(host): \(String(cString: gai_strerror(rc)))") }
    defer { freeaddrinfo(res) }
    var ai: UnsafeMutablePointer<addrinfo>? = first
    while let a = ai {
        let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
        if fd >= 0 {
            if Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return fd }
            Darwin.close(fd)
        }
        ai = a.pointee.ai_next
    }
    throw SpikeError("connect \(host):\(port): \(String(cString: strerror(errno)))")
}

// libssh2.h defines these as expressions Swift doesn't import.
let channelWindowDefault: UInt32 = 2 * 1024 * 1024
let channelPacketDefault: UInt32 = 32768

func hostKeyName(_ type: Int32) -> String {
    switch type {
    case LIBSSH2_HOSTKEY_TYPE_RSA: "ssh-rsa"
    case LIBSSH2_HOSTKEY_TYPE_ED25519: "ssh-ed25519"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: "ecdsa-sha2-nistp256"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: "ecdsa-sha2-nistp384"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: "ecdsa-sha2-nistp521"
    default: "unknown(\(type))"
    }
}

func main() async {
    var client = LibSSH2Client()
    await runSpike("libssh2", &client)
}

await main()
