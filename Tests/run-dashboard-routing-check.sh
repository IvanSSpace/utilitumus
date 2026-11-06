#!/bin/bash
# Дашборд, меню-бар, чек-лист и остановка при передаче для модулей, которых ведёт утилита. Статус подставной, подпись не нужна,
# окно за экраном (x: -10000). Настройки: Kit.defaults в своём suite, ModuleManager.shared — в домене бинарника, снят на выходе.
# Папка: DASHBOARD_ROUTING_CHECK_DIR, иначе $TMPDIR/dashboard-routing-check. PNG остаются в png/.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${DASHBOARD_ROUTING_CHECK_DIR:-${TMPDIR:-/tmp}/dashboard-routing-check}"
BIN="dashboard-routing-stand"
SUITE="local.utilitumus.test.kit.dashboard-routing"

rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/DashboardRoutingCheck.swift "$OUT/src/main.swift"
# shellcheck disable=SC2046
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name DashboardRoutingStand -o "$OUT/$BIN" \
  "$OUT/src/main.swift" "$OUT/src/UtilitumusApp.swift" \
  $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' \
    -not -name UtilitumusApp.swift) \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true; defaults delete dashboard-routing-stand-manager >/dev/null 2>&1 || true' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png"
