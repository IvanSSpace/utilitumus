#!/bin/bash
# «Озвучка»: как берётся выделенное — AX, Electron (AXManualAccessibility), копирование через ⌘C с возвратом буфера.
# AX, защищённый ввод, Electron, ⌘C, модификаторы и паузы подменены; буфер — свой именованный под настоящим SpeakSystemPasteboard.
# Общий буфер обмена, настоящий ⌘C и AX проверка не трогает. Сборка со швом KIT_TEST_DEFAULTS, дом подставной.
# Папка стенда: SPEAK_COPY_DIR, иначе $TMPDIR/speak-copy-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${SPEAK_COPY_DIR:-${T%/}/speak-copy-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.speak-copy"

cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
cleanup

rm -rf "$OUT/src" "$OUT/home"
mkdir -p "$OUT/src" "$OUT/home"
cp Tests/SpeakCopyCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/main.swift" Tests/SpeakCheckStubs.swift \
  Sources/Modules/Speak/*.swift Sources/Modules/Speak/UI/*.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort)
env HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" "$OUT/check"
