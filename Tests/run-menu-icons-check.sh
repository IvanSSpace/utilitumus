#!/bin/bash
# Значки модулей в строке меню: маршрутизация и настройка, закрытость связи для чужих, снимок раздела в двух темах на узкой ширине.
# Подпись не нужна, окна за экраном (x: -10000), значков в настоящей строке меню нет. Настройки: Kit.defaults в своём suite,
# домен бинарника снят на выходе. Папка: MENU_ICONS_CHECK_DIR, иначе $TMPDIR/menu-icons-check. PNG остаются в png/.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MENU_ICONS_CHECK_DIR:-${TMPDIR:-/tmp}/menu-icons-check}"
BIN="menu-icons-stand"
SUITE="local.utilitumus.test.kit.menu-icons"

# Сигнал через процессы: утилита после смены значка сообщает статус, центр по статусу перечитывает настройку.
awk '/func setMenuIcon\(_ on: Bool\)/,/^    }$/' Sources/Kit/SatelliteHost.swift | grep -q 'postStatus()' || { echo "ПРОВАЛ: утилита не сообщает о смене значка"; exit 1; }
awk '/func statusDidChange/,/^    }$/' Sources/App/Satellites/SatelliteRegistry.swift | grep -q 'statusPinged.send' || { echo "ПРОВАЛ: реестр не передаёт сигнал статуса"; exit 1; }
# Снятый ключ словом `false` не передать: утилита перечитывает настройку, а не пишет её.
awk '/func linkSetMenuIcon/,/^    }$/' Sources/Kit/SatelliteHost.swift | grep -q 'MenuBarIcon.set' && { echo "ПРОВАЛ: команда центра записала бы false поверх снятого ключа"; exit 1; }
echo "ok   утилита и центр сообщают друг другу о значке"

rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/MenuBarIconCheck.swift "$OUT/src/main.swift"
# shellcheck disable=SC2046
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name MenuIconsStand -o "$OUT/$BIN" \
  "$OUT/src/main.swift" "$OUT/src/UtilitumusApp.swift" \
  $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' \
    -not -name UtilitumusApp.swift) \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png"
