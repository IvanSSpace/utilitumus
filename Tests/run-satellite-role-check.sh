#!/bin/bash
# Роль утилиты и её включённость: чистая логика, UserDefaults только в тестовом suite.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SATELLITE_ROLE_CHECK_DIR:-${TMPDIR:-/tmp}/satellite-role-check}"
mkdir -p "$OUT"
cp Tests/SatelliteRoleCheck.swift "$OUT/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/main.swift" \
  Sources/Kit/KitDefaults.swift Sources/Kit/KitSigning.swift Sources/Kit/SatelliteCatalog.swift \
  Sources/Kit/SatelliteRole.swift Sources/Kit/SatelliteSelfUpdate.swift Sources/Kit/KitArchive.swift $(find Sources/Kit/Link -name '*.swift')
# Пустой файл от тестового suite: removePersistentDomain оставляет его в Preferences.
trap 'rm -f "$HOME/Library/Preferences/local.utilitumus.test.role.plist"' EXIT
"$OUT/check"
