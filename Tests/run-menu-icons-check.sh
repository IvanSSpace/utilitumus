#!/bin/bash
# Значки модулей в строке меню: маршрутизация и настройка, закрытость связи для чужих, снимок раздела в двух темах на узкой ширине.
# Подпись не нужна, окна за экраном (x: -10000), значков в настоящей строке меню нет. Настройки: Kit.defaults в своём suite,
# домен бинарника снят на выходе. Папка: MENU_ICONS_CHECK_DIR, иначе $TMPDIR/menu-icons-check. PNG остаются в png/.
source "$(dirname "$0")/lib/check-limit.sh"
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
# Центр значков не рисует: у модуля без утилиты вышел бы пустой значок, а компилятору это не видно.
if grep -rn 'MenuBarIconItem(' Sources/App; then echo "ПРОВАЛ: центр снова создаёт значок в строке меню"; exit 1; fi
if grep -rn 'hubShows' Sources; then echo "ПРОВАЛ: вернулось правило «значок рисует центр»"; exit 1; fi
# Меню и настройки строят переключатели из `switchable`: полный порядок дал бы их и модулям без утилиты.
if grep -n 'ForEach(modules.order)' Sources/App/MenuBar.swift Sources/App/ModuleMenuIcons.swift; then echo "ПРОВАЛ: переключатели у модулей без утилиты"; exit 1; fi
# Выключает утилита у себя. `ModuleOn` без неё ничего не включит: такой переключатель врал бы.
if grep -nE 'modules\.(setOn|isOn)|ModuleManager\.shared\.(setOn|isOn)' Sources/App/MenuBar.swift Sources/App/ModuleControlsHub.swift Sources/App/Design/Shell.swift Sources/App/Design/Dashboard.swift; then echo "ПРОВАЛ: переключатель снова идёт мимо утилиты"; exit 1; fi
echo "ok   центр значков не рисует, переключатели только у модулей с утилитой"

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache menu-icons "$TARGET" KIT_TEST_DEFAULTS)"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/work"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/MenuBarIconCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift UtilitumusApp.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
# UtilitumusApp.swift у стенда свой, без @main.
HUB_LIST="$(scripts/hub-sources.sh)"
FILES=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift")
while IFS= read -r f; do case "$f" in */UtilitumusApp.swift) ;; *) FILES+=("$f") ;; esac; done <<<"$HUB_LIST"
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name MenuIconsStand -o "$OUT/$BIN" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png"
