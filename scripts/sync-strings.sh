#!/usr/bin/env bash
# Pull new UI strings into the String Catalogs and list what lacks German.
# Run after changing user-visible text; then translate in Xcode, or in the
# .xcstrings JSON directly.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/DerivedData
xcodebuild -project Edith.xcodeproj -scheme Edith -configuration Debug \
    -derivedDataPath "$DERIVED" SWIFT_EMIT_LOC_STRINGS=YES build >/dev/null

app_data=$(find "$DERIVED" -path "*/Edith.build/*" -name "*.stringsdata")
core_data=$(find "$DERIVED" -path "*/EdithCore.build/*" -name "*.stringsdata")
# shellcheck disable=SC2086
xcrun xcstringstool sync App/Localizable.xcstrings --stringsdata $app_data
# shellcheck disable=SC2086
xcrun xcstringstool sync Packages/EdithCore/Sources/EdithCore/Resources/Localizable.xcstrings --stringsdata $core_data

python3 -I - <<'PY'
import json
for path in ["App/Localizable.xcstrings", "Packages/EdithCore/Sources/EdithCore/Resources/Localizable.xcstrings"]:
    strings = json.load(open(path))["strings"]
    todo = [k for k, e in strings.items()
            if e.get("shouldTranslate", True) and "de" not in e.get("localizations", {})]
    print(f"{path}: {len(strings)} strings, {len(todo)} without German")
    for k in todo:
        print("  ", json.dumps(k, ensure_ascii=False))
PY
