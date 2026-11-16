#!/bin/bash
# «Озвучка»: ядро без настоящего звука, AX и горячей клавиши — синтезатор, чтение выделения и сочетание подменены.
# Сборка со швом KIT_TEST_DEFAULTS: настройки только в своём тестовом suite, на выходе он удаляется. Настоящие настройки не трогаются.
# Папка стенда: SPEAK_CORE_DIR, иначе $TMPDIR/speak-core-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${SPEAK_CORE_DIR:-${T%/}/speak-core-check}"
# Свой suite: проверки разных модулей идут одновременно.
export KIT_TEST_SUITE="local.utilitumus.test.kit.speak-core"

cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
cleanup

mkdir -p "$OUT/src"
cp Tests/SpeakCoreCheck.swift "$OUT/src/main.swift"
# Все исходники «Озвучки» и весь Kit, как в утилите: экран и мини-плеер модуля стоят на компонентах Kit.
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/main.swift" Tests/SpeakCheckStubs.swift \
  Sources/Modules/Speak/*.swift Sources/Modules/Speak/UI/*.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort)
"$OUT/check"
