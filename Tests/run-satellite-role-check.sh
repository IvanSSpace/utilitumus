#!/bin/bash
# Роль утилиты и её включённость: чистая логика, UserDefaults только в тестовом suite.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SATELLITE_ROLE_CHECK_DIR:-${TMPDIR:-/tmp}/satellite-role-check}"
mkdir -p "$OUT"
# Инкрементальная сборка: кэш вне папки проверки. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache satellite-role KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
cmp -s Tests/SatelliteRoleCheck.swift "$CACHE/src/main.swift" || cp Tests/SatelliteRoleCheck.swift "$CACHE/src/main.swift"
FILES=("$CACHE/src/main.swift" Sources/Kit/KitDefaults.swift Sources/Kit/KitSigning.swift Sources/Kit/SatelliteCatalog.swift \
  Sources/Kit/SatelliteRole.swift Sources/Kit/SatelliteSelfUpdate.swift Sources/Kit/KitArchive.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit/Link -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name SatelliteRoleCheck -o "$OUT/check" "${FILES[@]}"
# Пустой файл от тестового suite: removePersistentDomain оставляет его в Preferences.
trap 'rm -f "$HOME/Library/Preferences/local.utilitumus.test.role.plist"' EXIT
"$OUT/check"
