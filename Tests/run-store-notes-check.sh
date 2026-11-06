#!/bin/bash
# Заметки к обновлению: чтение из каталога и вид в Сторе. Стенд за экраном собирается дважды: из нынешних исходников
# и из BASE, где заметок ещё нет. Без заметок снимки обеих сборок должны совпасть попиксельно, а BASE заодно
# показывает, как каталог с заметками читает старый центр. Вид Стора поменяли намеренно — BASE переносится на коммит
# с этим видом. Настройки: Kit.defaults подменён на домен бинарника, настоящий домен и настоящие пути не трогаются.
# Папка: STORE_NOTES_CHECK_DIR, иначе $TMPDIR/store-notes-check. PNG остаются в ней: base/png, new/png.
# STORE_NOTES_REUSE_BASE=1 берёт снимки BASE с прошлого запуска.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BASE=509cdb3
OUT="${STORE_NOTES_CHECK_DIR:-${TMPDIR:-/tmp}/store-notes-check}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
BIN="store-notes-stand"

same() { # описание, что есть, что ждали
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "ПРОВАЛ: $1: «${2}», ждали «${3}»"; exit 1; fi
}

# grep: 0 — нашёл, 1 — пусто, больше — ошибка самого grep.
status=0
found="$(grep -nE 'AttributedString|LocalizedStringKey|Link\(|openURL' Sources/App/Store/StoreDetail.swift Sources/App/Store/StoreView.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: разметка или ссылки в Сторе:"; echo "$found"; exit 1 ;;
  1) echo "ok   разметки и ссылок в Сторе нет" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac
same "настоящий каталог пуст и не изменён" "$(cat Catalog/catalog.json)" '{"schema":1,"apps":[]}'
same "формат каталога прежний" "$(sed -n 's/.*catalog.schema == \([0-9]*\).*/\1/p' Sources/Kit/SatelliteCatalog.swift)" 1

# build <папка с исходниками> <папка стенда> [флаги swiftc]
build() {
  local from="$1" to="$2"
  shift 2
  mkdir -p "$to/src" "$to/png"
  # Код Kit вне центра читал бы настоящий домен local.utilitumus: здесь Kit.defaults — домен самого бинарника.
  sed 's/Bundle\.main\.bundleIdentifier == hubBundleID/true/' "$from/Sources/Kit/KitDefaults.swift" > "$to/src/KitDefaults.swift"
  grep -q 'UserDefaults = true' "$to/src/KitDefaults.swift" || { echo "ПРОВАЛ: подмена Kit.defaults не сработала"; exit 1; }
  # Точка входа у стенда своя.
  sed 's/^@main$//' "$from/Sources/App/UtilitumusApp.swift" > "$to/src/UtilitumusApp.swift"
  if grep -q '^@main' "$to/src/UtilitumusApp.swift"; then echo "ПРОВАЛ: @main остался"; exit 1; fi
  cp "$ROOT/Tests/StoreNotesCheck.swift" "$to/src/main.swift"
  # shellcheck disable=SC2046
  (cd "$from" && swiftc -target "$TARGET" -module-name StoreNotesStand -o "$to/$BIN" "$@" \
    "$to/src/main.swift" "$to/src/KitDefaults.swift" "$to/src/UtilitumusApp.swift" \
    $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' \
      -not -name KitDefaults.swift -not -name UtilitumusApp.swift) \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit)
}

# Домен настроек стенда — по имени бинарника: чистый на входе, снят на выходе. У обеих сборок одно имя.
run() {
  defaults delete "$BIN" >/dev/null 2>&1 || true
  (cd "$1" && "./$BIN" "$1/work" "$1/png" "$OUT/base/png")
}
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true' EXIT

if [ -z "${STORE_NOTES_REUSE_BASE:-}" ] || [ ! -d "$OUT/base/png" ]; then
  rm -rf "$OUT"
  mkdir -p "$OUT/base/tree"
  /usr/bin/git cat-file -e "$BASE^{commit}" || { echo "ПРОВАЛ: нет коммита $BASE"; exit 1; }
  /usr/bin/git archive "$BASE" Sources | tar -x -C "$OUT/base/tree"
  echo "== сборка из $BASE: заметок в коде нет"
  build "$OUT/base/tree" "$OUT/base" -D BASE_BUILD
  run "$OUT/base"
fi

echo "== нынешняя сборка"
rm -rf "$OUT/new"
build "$ROOT" "$OUT/new"
run "$OUT/new"
