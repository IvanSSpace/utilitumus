#!/bin/bash
# Дашборд, меню-бар, чек-лист и остановка при передаче для модулей, которых ведёт утилита. Статус подставной, подпись не нужна,
# окно за экраном (x: -10000). Настройки: Kit.defaults в своём suite, ModuleManager.shared — в домене бинарника, снят на выходе.
# Папка: DASHBOARD_ROUTING_CHECK_DIR, иначе $TMPDIR/dashboard-routing-check. PNG остаются в png/.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${DASHBOARD_ROUTING_CHECK_DIR:-${TMPDIR:-/tmp}/dashboard-routing-check}"
BIN="dashboard-routing-stand"
SUITE="local.utilitumus.test.kit.dashboard-routing"

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache dashboard-routing "$TARGET" KIT_TEST_DEFAULTS)"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/DashboardRoutingCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift UtilitumusApp.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
# UtilitumusApp.swift у стенда свой, без @main.
HUB_LIST="$(scripts/hub-sources.sh)"
FILES=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift")
while IFS= read -r f; do case "$f" in */UtilitumusApp.swift) ;; *) FILES+=("$f") ;; esac; done <<<"$HUB_LIST"
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name DashboardRoutingStand -o "$OUT/$BIN" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true; defaults delete dashboard-routing-stand-manager >/dev/null 2>&1 || true' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png"
