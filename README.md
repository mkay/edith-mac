# Edith for macOS

A native macOS SFTP/FTP client for live remote file editing, rebuilt in
Swift and SwiftUI from [Edith for Linux](https://github.com/mkay/edith).
The editor is Monaco, hosted in a `WKWebView`.

> Phase 1: core services (config, Keychain, SFTP, transfers). No UI yet.

## Layout

| Path | What |
|---|---|
| `App/` | The SwiftUI app target |
| `Packages/EdithCore/` | Models, config, Keychain, known_hosts, SFTP client, transfer queue. No UI imports. |
| `Packages/EdithEditor/` | Monaco host: `WKWebView`, `edith://` scheme handler, `bridge.js` |
| `Spikes/SFTPSpike/` | libssh2 vs Citadel comparison ([results](Spikes/SFTPSpike/RESULTS.md)) |
| `project.yml` | XcodeGen spec. `Edith.xcodeproj` is generated, not checked in. |

## Building

Requires Xcode 26 or later, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
scripts/fetch-monaco.sh      # Monaco, Emmet, terser, csso from the npm registry
scripts/build-libssh2.sh     # libssh2 + OpenSSL as a universal xcframework (~2 min)
xcodegen generate
open Edith.xcodeproj
```

Tests:

```sh
(cd Packages/EdithCore && swift test)
(cd Packages/EdithEditor && swift test)
```

The SFTP tests start a throwaway OpenSSH server (`/usr/sbin/sshd`) on a free
loopback port, running as you with key auth only, and stop it when the run
ends. They read and write only inside a temp directory.

## Translations

English and German. The strings live in String Catalogs: `App/Localizable.xcstrings`
for the app and `Packages/EdithCore/Sources/EdithCore/Resources/Localizable.xcstrings`
for error messages. After changing user-visible text, run `scripts/sync-strings.sh`:
it adds new strings to the catalogs and lists the ones still without German. Terms
follow the Linux app's `po/de.po`.

## Sharing with the Linux app

- `servers.json` and server exports use the Linux app's format, so both
  apps read each other's files.
- `bridge.js` comes from the Linux repo. The one change here (a relative
  `vs` path in `require.config`, needed for the `edith://` scheme) also works
  under `file://` and can go upstream.

## License

GPL-3.0-or-later
