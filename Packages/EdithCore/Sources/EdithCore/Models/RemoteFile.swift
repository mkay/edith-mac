// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A file or directory on a server.
public struct RemoteFile: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var size: UInt64
    public var isDirectory: Bool
    /// The entry itself is a symlink. `isDirectory` then describes its target.
    public var isSymlink: Bool
    /// Full st_mode, including the file type bits.
    public var mode: UInt32
    public var modified: Date?
    public var owner: String
    public var group: String

    public var id: String { path }

    public init(
        name: String, path: String, size: UInt64 = 0, isDirectory: Bool = false, isSymlink: Bool = false,
        mode: UInt32 = 0, modified: Date? = nil, owner: String = "", group: String = ""
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.mode = mode
        self.modified = modified
        self.owner = owner
        self.group = group
    }

    /// Permission bits only (0o755 and the like).
    public var permissions: UInt32 { mode & 0o7777 }

    /// `ls -l` style, e.g. `drwxr-xr-x`. Unknown modes show as dashes.
    public var permissionsString: String {
        guard mode != 0 else { return "----------" }
        let type: Character = switch mode & 0o170000 {
        case 0o040000: "d"
        case 0o120000: "l"
        case 0o020000: "c"
        case 0o060000: "b"
        case 0o010000: "p"
        case 0o140000: "s"
        default: "-"
        }
        var s = String(type)
        let bits: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        for (bit, ch) in bits { s.append(mode & bit != 0 ? ch : "-") }

        // setuid, setgid and sticky replace the matching x, as ls shows them.
        func overlay(_ index: Int, _ flag: UInt32, _ set: Character, _ unset: Character) {
            guard mode & flag != 0 else { return }
            let i = s.index(s.startIndex, offsetBy: index)
            s.replaceSubrange(i...i, with: String(s[i] == "x" ? set : unset))
        }
        overlay(3, 0o4000, "s", "S")
        overlay(6, 0o2000, "s", "S")
        overlay(9, 0o1000, "t", "T")
        return s
    }
}

/// Joins a remote directory and a name with exactly one slash.
public func remoteJoin(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? dir + name : dir + "/" + name
}

/// The last path component of a remote path.
public func remoteName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
