#!/bin/bash
# Модуль Стеша в утилите, без launchd и подписи: защита своих программ (Kit.isOurs), общий домен записи стеша,
# один писатель, замер по аренде экрана. Все программы поддельные; настройки только в тестовом домене Kit.
# Папка стенда: STASH_MODULE_DIR, иначе $TMPDIR/stash-module-check.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${STASH_MODULE_DIR:-${TMPDIR:-/tmp}/stash-module-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.stash-module"
cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
cleanup

# Проверка не должна дотягиваться до настоящего.
status=0
FOUND="$(grep -nE 'StashStore\.shared|\.standard|NSWorkspace|local\.utilitumus"' Tests/StashModuleCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка дотягивается до настоящего:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   в проверке нет общего экземпляра, .standard и NSWorkspace" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"
swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name StashModuleCheck -o "$OUT/check" \
  Tests/StashModuleCheck.swift Sources/Apps/Stash/StashModule.swift \
  $(find Sources/Modules/Stash Sources/Kit -name '*.swift') -framework SwiftUI -framework AppKit -framework IOKit
"$OUT/check"
