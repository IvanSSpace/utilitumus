#!/bin/bash
# Стор и каталог: стенд за экраном (x: -10000) из всей сборки центра, подставные launchctl, загрузка, связь и каталог,
# пути в папке стенда. Настройки: Kit.defaults подменён на домен бинарника, у которого своё имя.
# Папка: STORE_CATALOG_CHECK_DIR, иначе $TMPDIR/store-catalog-check. PNG остаются в ней, в png/.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${STORE_CATALOG_CHECK_DIR:-${TMPDIR:-/tmp}/store-catalog-check}"
BIN="store-catalog-stand"

# grep: 0 — нашёл, 1 — пусто, больше — ошибка самого grep.
forbid() {
  local status=0 found
  found="$(grep -nE "$1" "${@:3}")" || status=$?
  case "$status" in
    0) echo "ПРОВАЛ: $2:"; echo "$found"; exit 1 ;;
    1) echo "ok   $2: нет" ;;
    *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
  esac
}
# Ни один тест не имеет права дотянуться до настоящих путей и настоящей связи.
# Ищем настоящие `.live`, `Тип.live` и `liveИмя`; поле `state.live` и слова вроде keepalive сюда не попадают.
# Кроме `liveVerify`: он только читает бандл (HelperIdentityCheck). И кроме `BotsMonitor.liveProbe(getpid())`: читает libproc про сам тест.
status=0
found="$(grep -rnE '(^|[^A-Za-z0-9_])\.live\b|[A-Z][A-Za-z0-9]*\.live\b|\blive([A-UW-Z(]|V[^e])' Tests --include='*.swift')" || status=$?
if [ "$status" = 0 ]; then found="$(printf '%s\n' "$found" | grep -vF 'BotsMonitor.liveProbe(getpid())')" || status=$?; fi
case "$status" in
  0) echo "ПРОВАЛ: настоящие замыкания и пути в тестах:"; echo "$found"; exit 1 ;;
  1) echo "ok   настоящие замыкания и пути в тестах: нет" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache store-catalog "$TARGET")"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/fixture/Awake.app/Contents/MacOS"

# Категории без замков и без запрета нажатия (версия 0.5.3): запертое выглядело как поломка, а ставить модуль надо с плитки.
# Вкладок категорий больше нет: категории — ряды витрины Стора, вместо вкладок боковая панель.
: > "$OUT/tab.txt"
for view in StoreShelf StoreTile StoreTileInstall; do
  sed -n "/^private struct $view: View/,/^}/p" Sources/App/Store/StoreView.swift > "$OUT/$view.txt"
  if [ ! -s "$OUT/$view.txt" ]; then
    echo "ПРОВАЛ: не найден вид $view"
    exit 1
  fi
  cat "$OUT/$view.txt" >> "$OUT/tab.txt"
done
forbid 'systemName: "lock|\.disabled\(' 'замок или запрет в рядах Стора и на плитке' "$OUT/tab.txt"
forbid 'systemName: "lock|\.disabled\(' 'замок или запрет в боковой панели' Sources/App/Design/SidebarView.swift
if ! grep -q 'store\.install(module)' "$OUT/StoreTileInstall.txt" || ! grep -q 'StoreTileInstall(' "$OUT/StoreTile.txt"; then
  echo "ПРОВАЛ: на плитке Стора нет кнопки установки"
  exit 1
fi

# Код Kit вне центра читал бы настоящий домен local.utilitumus: здесь Kit.defaults — домен самого бинарника.
sed 's/Bundle\.main\.bundleIdentifier == hubBundleID/true/' Sources/Kit/KitDefaults.swift > "$OUT/src/KitDefaults.swift"
if ! grep -q 'UserDefaults = true' "$OUT/src/KitDefaults.swift"; then
  echo "ПРОВАЛ: подмена Kit.defaults не сработала"
  exit 1
fi

# Точка входа у стенда своя.
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
if grep -q '^@main' "$OUT/src/UtilitumusApp.swift"; then
  echo "ПРОВАЛ: @main остался"
  exit 1
fi

# Архив как у выпуска. Подпись не проверяется: проверка подставная, тут важен путь через установщик.
{
  echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
  echo '<key>CFBundleIdentifier</key><string>local.utilitumus.app.awake</string>'
  echo '<key>CFBundleExecutable</key><string>Awake</string>'
  echo '<key>CFBundleShortVersionString</key><string>1.0.0</string>'
  echo '</dict></plist>'
} > "$OUT/fixture/Awake.app/Contents/Info.plist"
printf '#!/bin/sh\n' > "$OUT/fixture/Awake.app/Contents/MacOS/Awake"
chmod 755 "$OUT/fixture/Awake.app/Contents/MacOS/Awake"
chmod -R go-w "$OUT/fixture"
ditto -c -k --keepParent "$OUT/fixture/Awake.app" "$OUT/fixture/Awake.zip"

cp Tests/StoreCatalogCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift KitDefaults.swift UtilitumusApp.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
# shellcheck disable=SC2046
FILES=("$CACHE/src/main.swift" "$CACHE/src/KitDefaults.swift" "$CACHE/src/UtilitumusApp.swift" $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' \
  -not -name KitDefaults.swift -not -name UtilitumusApp.swift | sort))
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -module-name StoreCatalogStand -o "$OUT/$BIN" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

# Домен настроек стенда — по имени бинарника: чистый на входе, снят на выходе.
defaults delete "$BIN" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true' EXIT
cd "$OUT"
"./$BIN" "$OUT/work" "$OUT/fixture/Awake.zip" "$(shasum -a 256 "$OUT/fixture/Awake.zip" | cut -d' ' -f1)" "$OUT/png"
