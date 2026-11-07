#!/bin/bash
# Возврат системного действия 🌐 «Клавиатурой» (настоящий FnSystemAction.swift со швом). Система не трогается:
# AppleFnUsageType и горячие клавиши подменены ключами Test.* тестового домена.
# FN_RESTORE_OLD=<коммит> собирает проверку со старым InputSources.swift, где тогда лежал FnSystemAction (показать, что она падала).
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${FN_RESTORE_DIR:-${TMPDIR:-/tmp}/fn-restore-check}"
export KIT_TEST_SUITE="local.utilitumus.test.fnrestore"
cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
rm -rf "$OUT"; mkdir -p "$OUT/src"
cleanup
cp Tests/FnRestoreCheck.swift "$OUT/src/main.swift"
if [ -n "${FN_RESTORE_OLD:-}" ]; then
  /usr/bin/git show "$FN_RESTORE_OLD:Sources/Modules/Keyboard/InputSources.swift" > "$OUT/src/FnSystemAction.swift"
else
  cp Sources/Modules/Keyboard/UI/FnSystemAction.swift "$OUT/src/FnSystemAction.swift"
fi
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" \
  "$OUT/src/main.swift" "$OUT/src/FnSystemAction.swift" Sources/Kit/KitDefaults.swift -framework AppKit -framework Carbon
"$OUT/check"
