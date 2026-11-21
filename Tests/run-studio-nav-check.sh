#!/bin/bash
# «Студия»: куда можно ходить странице (только свой http://127.0.0.1:<порт> и localhost:<порт>, чужое в браузер, file: и прочее нигде),
# одноразовое хранилище страницы, «открыть в браузере» только с новым кодом, когда странице нужен новый код входа.
# Страница не грузится: сети нет. Папка стенда: STUDIO_NAV_DIR.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${STUDIO_NAV_DIR:-${T%/}/studio-nav-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.studio-nav"
trap 'defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"' EXIT

mkdir -p "$OUT/src"
cp Tests/StudioNavCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/main.swift" \
  Sources/Modules/Studio/UI/*.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort) \
  -framework SwiftUI -framework AppKit -framework WebKit
"$OUT/check"
