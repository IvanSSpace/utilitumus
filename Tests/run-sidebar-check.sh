#!/bin/bash
# Боковая панель: чистая раскладка (зоны, переносы, сетка плиток), настройки и переход, снимки панели в двух темах.
# Подпись не нужна, окна за экраном (x: -10000). Настройки: Kit.defaults в своём suite, домен бинарника снят на выходе.
# Папка: SIDEBAR_CHECK_DIR, иначе $TMPDIR/sidebar-check. PNG остаются в png/.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SIDEBAR_CHECK_DIR:-${TMPDIR:-/tmp}/sidebar-check}"
BIN="sidebar-stand"
SUITE="local.utilitumus.test.kit.sidebar"

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache sidebar "$TARGET" KIT_TEST_DEFAULTS)"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/SidebarCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift UtilitumusApp.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
# UtilitumusApp.swift у стенда свой, без @main.
HUB_LIST="$(scripts/hub-sources.sh)"
FILES=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift")
while IFS= read -r f; do case "$f" in */UtilitumusApp.swift) ;; *) FILES+=("$f") ;; esac; done <<<"$HUB_LIST"
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name SidebarStand -o "$OUT/$BIN" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png"
