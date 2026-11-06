#!/bin/bash
# Боковая панель: чистая раскладка (зоны, переносы, сетка плиток), настройки и переход, снимки панели в двух темах.
# Подпись не нужна, окна за экраном (x: -10000). Настройки: Kit.defaults в своём suite, домен бинарника снят на выходе.
# Папка: SIDEBAR_DRAG_CHECK_DIR, иначе $TMPDIR/sidebar-drag-check. PNG остаются в png/.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SIDEBAR_DRAG_CHECK_DIR:-${TMPDIR:-/tmp}/sidebar-drag-check}"
BIN="sidebar-drag-stand"
SUITE="local.utilitumus.test.kit.sidebar-drag"

rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/SidebarDragCheck.swift "$OUT/src/main.swift"
# shellcheck disable=SC2046
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name SidebarDragStand -o "$OUT/$BIN" \
  "$OUT/src/main.swift" "$OUT/src/UtilitumusApp.swift" \
  $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' \
    -not -name UtilitumusApp.swift) \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png"
