#!/usr/bin/env bash
# Build a release: scripts/release.sh VERSION [--publish]
#
# Builds Edith in the Release configuration, signed with the Apple
# Development certificate (not notarised: see README), packs it into a DMG,
# signs that for Sparkle and writes appcast.xml. Everything lands in
# dist/VERSION/. With --publish, and the GitHub CLI logged in, it also
# creates the GitHub release vVERSION on mkay/edith-mac with both files:
# the app's update feed is releases/latest/download/appcast.xml.
#
# Before running: bump the notes in App/Resources/whatsnew.md, commit.
set -euo pipefail

REPO="mkay/edith-mac"
VERSION="${1:-}"
PUBLISH="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 VERSION [--publish]  (e.g. 0.1.0)" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -n "$(git status --porcelain)" ]; then
    echo "Uncommitted changes: commit first, so the release is a known commit." >&2
    exit 1
fi
# Sparkle compares build numbers; the commit count only ever goes up.
BUILD="$(git rev-list --count HEAD)"
DIST="$ROOT/dist/$VERSION"
DMG="$DIST/Edith-$VERSION.dmg"
mkdir -p "$DIST"

echo "== Dependencies"
scripts/fetch-monaco.sh >/dev/null
scripts/build-libssh2.sh >/dev/null
scripts/fetch-sparkle-tools.sh >/dev/null
xcodegen generate >/dev/null

echo "== Building Edith $VERSION ($BUILD)"
xcodebuild -project Edith.xcodeproj -scheme Edith -configuration Release \
    -derivedDataPath build/Release MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    build >/dev/null
APP="build/Release/Build/Products/Release/Edith.app"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^Authority=Apple Development" >/dev/null || {
    echo "Not signed with an Apple Development certificate; Keychain access would break between versions." >&2
    exit 1
}

echo "== DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Edith $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null

echo "== Sparkle"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$(build/tools/sparkle/bin/sign_update "$DMG")"
NOTES_HTML="$(python3 -I - App/Resources/whatsnew.md <<'PY'
import html, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
items = []
for line in text.splitlines():
    line = line.strip().lstrip("-*•").strip()
    if not line:
        continue
    line = html.escape(line)
    line = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', line)
    items.append(f"<li>{line}</li>")
print("<ul>" + "".join(items) + "</ul>")
PY
)"
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Edith</title>
    <item>
      <title>Edith $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Edith-$VERSION.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

if [ "$PUBLISH" = "--publish" ]; then
    command -v gh >/dev/null || { echo "--publish needs the GitHub CLI (brew install gh; gh auth login)." >&2; exit 1; }
    echo "== GitHub release v$VERSION"
    NOTES="$(sed -e '/<!--/,/-->/d' App/Resources/whatsnew.md)"
    gh release create "v$VERSION" "$DMG" "$DIST/appcast.xml" --repo "$REPO" \
        --title "Edith $VERSION" --notes "$NOTES"$'\n\n'"First launch: macOS blocks apps that aren't notarised. Open Edith once, then allow it under System Settings → Privacy & Security → Open Anyway."
fi

echo "Done: $DMG"
echo "      $DIST/appcast.xml"
