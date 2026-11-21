#!/bin/bash
# Провод модуля «Студия»: форма состояния и действий, строгий разбор, проверка пути, настройки. Токена в состоянии нет.
# Сборка со швом KIT_TEST_DEFAULTS: настройки только в своём тестовом suite, на выходе он удаляется. Папка стенда: STUDIO_WIRE_DIR.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${STUDIO_WIRE_DIR:-${T%/}/studio-wire-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.studio-wire"

cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
cleanup

mkdir -p "$OUT/src"
cp Tests/StudioWireCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/main.swift" \
  Sources/Modules/Studio/UI/StudioWire.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort) \
  -framework SwiftUI -framework AppKit
"$OUT/check"
