#!/usr/bin/env bash
# Sparkle's command-line tools (generate_keys, sign_update) into
# build/tools/sparkle, for release.sh. Same version as the app's package.
set -euo pipefail
VERSION="2.10.1"
# GitHub's digest for the release asset; the tools themselves are only
# ad-hoc signed, so this is what says they're Sparkle's.
SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
DEST="$(cd "$(dirname "$0")/.." && pwd)/build/tools/sparkle"
if [ -x "$DEST/bin/sign_update" ]; then exit 0; fi
mkdir -p "$DEST"
echo "Downloading Sparkle $VERSION tools…"
ARCHIVE="$DEST/Sparkle-$VERSION.tar.xz"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$ARCHIVE"
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c --status || { echo "checksum mismatch" >&2; rm -f "$ARCHIVE"; exit 1; }
tar -xJf "$ARCHIVE" -C "$DEST"
rm "$ARCHIVE"
echo "Sparkle tools in $DEST/bin"
