# Edith for macOS

A native macOS SFTP/FTP client for live remote file editing, rebuilt in
Swift and SwiftUI from [Edith for Linux](https://github.com/mkay/edith).
The editor is Monaco, hosted in a `WKWebView`.

> Phase 0: project skeleton and spikes. Not usable yet.

## Layout

| Path | What |
|---|---|
| `App/` | The SwiftUI app target |
| `Packages/EdithCore/` | Models, config, remote file systems, transfers. No UI imports. |
| `Packages/EdithEditor/` | Monaco host: `WKWebView`, `edith://` scheme handler, `bridge.js` |
| `Spikes/SFTPSpike/` | libssh2 vs Citadel comparison ([results](Spikes/SFTPSpike/RESULTS.md)) |
| `project.yml` | XcodeGen spec. `Edith.xcodeproj` is generated, not checked in. |

## Building

Requires Xcode 26 or later, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
scripts/fetch-monaco.sh      # Monaco, Emmet, terser, csso from the npm registry
xcodegen generate
open Edith.xcodeproj
```

Tests:

```sh
(cd Packages/EdithCore && swift test)
(cd Packages/EdithEditor && swift test)
```

## Sharing with the Linux app

- `servers.json` and server exports use the Linux app's format, so both
  apps read each other's files.
- `bridge.js` comes from the Linux repo. The one change here (a relative
  `vs` path in `require.config`, needed for the `edith://` scheme) also works
  under `file://` and can go upstream.

## License

GPL-3.0-or-later
