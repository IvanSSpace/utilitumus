#!/bin/bash
# Перетаскивание в боковой панели настоящими событиями мыши (NSWindow.sendEvent: нажатие, много мелких сдвигов, отпускание, Esc):
# порядок строк и плиток, список <-> сетка, «Скрытые» с линией вставки, десятая плитка, прокрутка и автопрокрутка, клик и меню.
# Меряет, где поднятая копия относительно курсора на каждом шаге, и посадку без скачка. Окна за экраном (x: -10000), подпись не нужна.
# Настройки: Kit.defaults в своём suite, домен бинарника снят на выходе.
# Папка: SIDEBAR_DRAG_CHECK_DIR, иначе $TMPDIR/sidebar-drag-check. Кадры перетаскивания: SIDEBAR_DRAG_PNG, иначе png/.
# SIDEBAR_DRAG_ONLY=clicks,hidden — только эти сценарии (clicks, reorder, between, hidden, cancelling, scrolled).
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SIDEBAR_DRAG_CHECK_DIR:-${TMPDIR:-/tmp}/sidebar-drag-check}"
BIN="sidebar-drag-stand"
SUITE="local.utilitumus.test.kit.sidebar-drag"

# Инкрементальная сборка: кэш рядом с папкой проверки, а не в ней (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="${SIDEBAR_DRAG_CACHE:-$OUT-cache}"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$CACHE/src/UtilitumusApp.swift.new"
cmp -s "$CACHE/src/UtilitumusApp.swift.new" "$CACHE/src/UtilitumusApp.swift" || mv "$CACHE/src/UtilitumusApp.swift.new" "$CACHE/src/UtilitumusApp.swift"
rm -f "$CACHE/src/UtilitumusApp.swift.new"
cmp -s Tests/SidebarDragCheck.swift "$CACHE/src/main.swift" || cp Tests/SidebarDragCheck.swift "$CACHE/src/main.swift"
FILES=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift")
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' \
  -not -path 'Sources/Apps/*' -not -name UtilitumusApp.swift | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name SidebarDragStand -o "$OUT/$BIN" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png"
