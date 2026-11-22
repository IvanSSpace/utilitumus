#!/bin/bash
# «Студия»: раннер сервера. Запуск без шелла и окружение, подключение к чужой Студии, токен и код входа, остановка только своего,
# недоверие к файлам (права, ссылки, pid) и к ответам. Процесс, сеть и система подменены; настоящая Студия, порт 47870 и её
# .cache не трогаются: всё во временной папке (mktemp -d), порты случайные. Настройки только в своём тестовом suite.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${STUDIO_RUNNER_DIR:-${T%/}/studio-runner-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.studio-runner"

# Рабочая папка проверки: только своя временная. rm -rf разрешён, когда путь доказанно из mktemp под $TMPDIR.
WORK="$(mktemp -d "${T%/}/studio-runner-check.XXXXXX")"
case "$WORK" in "${T%/}"/studio-runner-check.*) ;; *) echo "ПРОВАЛ: странная рабочая папка $WORK"; exit 1 ;; esac
cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
  chmod -R u+rwx "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$OUT/src"
cp Tests/StudioRunnerCheck.swift "$OUT/src/StudioRunnerCheck.swift"
swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/StudioRunnerCheck.swift" \
  Sources/Modules/Studio/StudioRunner.swift Sources/Modules/Studio/StudioController.swift Sources/Modules/Studio/StudioLive.swift \
  Sources/Modules/Studio/StudioBoardLoader.swift Sources/Modules/Studio/StudioBoardParser.swift Sources/Modules/Studio/UI/StudioBoard.swift \
  Sources/Modules/Studio/UI/StudioWire.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort) \
  -framework SwiftUI -framework AppKit
"$OUT/check" "$WORK"
