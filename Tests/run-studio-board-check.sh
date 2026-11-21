#!/bin/bash
# «Студия»: родной экран со стороны утилиты. Опрос /api/state только при открытом экране, снимок на проводе без токена и путей,
# значки один раз, дело только выбранной, действия с телами страницы, отказы на месте, ошибки сервера строками (401, таймаут,
# 409, 500, кривой JSON, сервер пропал). Сервер, процесс и система подменены; настоящая Студия, порт 47870 и её .cache не
# трогаются: всё во временной папке (mktemp -d). Настройки только в своём тестовом suite.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.studio-board"

# rm -rf разрешён, только когда путь доказанно из mktemp под $TMPDIR.
WORK="$(mktemp -d "${T%/}/studio-board-check.XXXXXX")"
case "$WORK" in "${T%/}"/studio-board-check.*) ;; *) echo "ПРОВАЛ: странная рабочая папка $WORK"; exit 1 ;; esac
cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/src" "$WORK/run"
cp Tests/StudioBoardCheck.swift "$WORK/src/StudioBoardCheck.swift"
swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$WORK/check" "$WORK/src/StudioBoardCheck.swift" \
  Sources/Modules/Studio/StudioRunner.swift Sources/Modules/Studio/StudioController.swift Sources/Modules/Studio/StudioLive.swift \
  Sources/Modules/Studio/StudioBoardLoader.swift Sources/Modules/Studio/StudioBoardParser.swift Sources/Modules/Studio/UI/StudioBoard.swift \
  Sources/Modules/Studio/UI/StudioWire.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort) \
  -framework SwiftUI -framework AppKit
"$WORK/check" "$WORK/run"
