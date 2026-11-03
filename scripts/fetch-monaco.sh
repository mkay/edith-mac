#!/usr/bin/env bash
# Download Monaco Editor, Emmet, terser and csso into the EdithEditor package.
# Same versions as the Linux app's scripts/fetch-monaco.sh, fetched straight
# from the npm registry so neither node nor npm is needed.
set -euo pipefail

MONACO_VERSION="0.52.2"
EMMET_VERSION="5.0.0"
TERSER_VERSION="5.51.2"
CSSO_VERSION="5.0.5"
DATADIR="$(cd "$(dirname "$0")/.." && pwd)/Packages/EdithEditor/Sources/EdithEditor/Resources/Monaco"
DEST="$DATADIR/vs"

if [ -d "$DEST" ]; then
    echo "Monaco already present at $DEST — remove it first to re-fetch."
    exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# fetch <package> <version>: unpack the registry tarball into $TMPDIR/package
fetch() {
    local name="$1" version="$2"
    echo "Downloading ${name}@${version}…"
    rm -rf "$TMPDIR/package"
    curl -fsSL "https://registry.npmjs.org/${name}/-/${name}-${version}.tgz" | tar -xz -C "$TMPDIR"
}

mkdir -p "$DATADIR"

fetch monaco-editor "$MONACO_VERSION"
mv "$TMPDIR/package/min/vs" "$DEST"

fetch emmet-monaco-es "$EMMET_VERSION"
cp "$TMPDIR/package/dist/emmet-monaco.min.js" "$DATADIR/emmet.js"

# The minifiers run under JavaScriptCore, not in the web view.
fetch terser "$TERSER_VERSION"
cp "$TMPDIR/package/dist/bundle.min.js" "$DATADIR/terser.js"

fetch csso "$CSSO_VERSION"
cp "$TMPDIR/package/dist/csso.js" "$DATADIR/csso.js"

echo "Done — $DATADIR"
