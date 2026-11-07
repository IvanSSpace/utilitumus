#!/bin/bash
# Заметки к обновлению: чтение из каталога и вид в Сторе. Стенд за экраном собирается дважды: из нынешних исходников
# и из тех же исходников без кода заметок (BASE: из HEAD отменён коммит NOTES_COMMIT, который их добавил). Вид Стора
# менялся и без заметок, поэтому старый коммит для сравнения не годится. Без заметок снимки обеих сборок должны
# совпасть попиксельно, а BASE заодно показывает, как каталог с заметками читает центр без их кода. Настройки: Kit.defaults подменён на домен бинарника, настоящий домен и настоящие пути не трогаются.
# Папка: STORE_NOTES_CHECK_DIR, иначе $TMPDIR/store-notes-check. PNG остаются в ней: base/png, new/png.
# STORE_NOTES_REUSE_BASE=1 берёт снимки BASE с прошлого запуска.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

NOTES_COMMIT=49c5537
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
# Каталог опубликован и меняется только выпуском: проверка его не трогает, сверка в самом конце.
CATALOG_BEFORE="$(shasum -a 256 < Catalog/catalog.json)"
same "формат каталога прежний" "$(sed -n 's/.*catalog.schema == \([0-9]*\).*/\1/p' Sources/Kit/SatelliteCatalog.swift)" 1

# Инкрементальная сборка: у каждой из двух сборок свой кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE_BASE="$(incremental_cache store-notes-base "$TARGET" BASE_BUILD)"
CACHE_NEW="$(incremental_cache store-notes "$TARGET")"

# build <папка с исходниками> <папка стенда> <кэш> [флаги swiftc]
build() {
  local from="$1" to="$2" cache="$3" f
  shift 3
  mkdir -p "$to/src" "$to/png" "$cache/src"
  # Код Kit вне центра читал бы настоящий домен local.utilitumus: здесь Kit.defaults — домен самого бинарника.
  sed 's/Bundle\.main\.bundleIdentifier == hubBundleID/true/' "$from/Sources/Kit/KitDefaults.swift" > "$to/src/KitDefaults.swift"
  grep -q 'UserDefaults = true' "$to/src/KitDefaults.swift" || { echo "ПРОВАЛ: подмена Kit.defaults не сработала"; exit 1; }
  # Точка входа у стенда своя.
  sed 's/^@main$//' "$from/Sources/App/UtilitumusApp.swift" > "$to/src/UtilitumusApp.swift"
  if grep -q '^@main' "$to/src/UtilitumusApp.swift"; then echo "ПРОВАЛ: @main остался"; exit 1; fi
  cp "$ROOT/Tests/StoreNotesCheck.swift" "$to/src/main.swift"
  # В BASE замыкание выхода ещё без причины: те же строки проверки, старая форма closure.
  if grep -q 'var quit: (String) async' "$from/Sources/App/Satellites/SatelliteInstaller.swift"; then
    sed -i '' 's/quit: { _, _ in }/quit: { _ in }/' "$to/src/main.swift"
  fi
  # Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
  for f in main.swift KitDefaults.swift UtilitumusApp.swift; do cmp -s "$to/src/$f" "$cache/src/$f" || cp "$to/src/$f" "$cache/src/$f"; done
  # shellcheck disable=SC2046
  (cd "$from"
    FILES=("$cache/src/main.swift" "$cache/src/KitDefaults.swift" "$cache/src/UtilitumusApp.swift" $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' \
      -not -name KitDefaults.swift -not -name UtilitumusApp.swift | sort))
    incremental_flags "$cache" "${FILES[@]}"
    swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -module-name StoreNotesStand -o "$to/$BIN" "$@" \
      "${FILES[@]}" \
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
  /usr/bin/git cat-file -e "$NOTES_COMMIT^{commit}" || { echo "ПРОВАЛ: нет коммита $NOTES_COMMIT"; exit 1; }
  /usr/bin/git archive HEAD Sources | tar -x -C "$OUT/base/tree"
  # Обратный патч с запасом по строкам: позже в тех же файлах правили и другое.
  /usr/bin/git diff "$NOTES_COMMIT^" "$NOTES_COMMIT" -- Sources > "$OUT/base/notes.diff"
  [ -s "$OUT/base/notes.diff" ] || { echo "ПРОВАЛ: коммит $NOTES_COMMIT не меняет Sources"; exit 1; }
  (cd "$OUT/base/tree" && patch -R -p1 -F3 --no-backup-if-mismatch < "$OUT/base/notes.diff" > "$OUT/base/patch.log") \
    || { echo "ПРОВАЛ: заметки не отделились от нынешних исходников"; cat "$OUT/base/patch.log"; exit 1; }
  # «Обновить всё» появилось позже коммита заметок и читает те же поля каталога: в BASE строка обновления без заметок.
  sed -i '' 's/notes: held\.notes,/notes: [],/; s/notes: app\.notes,/notes: [],/' "$OUT/base/tree/Sources/App/Store/UpdateAll.swift"
  ! grep -rq 'updateNotes\|StoreUpdateNotes' "$OUT/base/tree/Sources" || { echo "ПРОВАЛ: в BASE остался код заметок"; exit 1; }
  echo "== сборка из HEAD без кода заметок"
  # Дерево BASE распаковывается заново при каждом запуске: в кэш копируются только файлы с другим содержимым
  # (время изменения прочих не меняется), а удалённые из него убираются.
  mkdir -p "$CACHE_BASE/tree"
  rsync -rc --delete "$OUT/base/tree/" "$CACHE_BASE/tree/"
  build "$CACHE_BASE/tree" "$OUT/base" "$CACHE_BASE" -D BASE_BUILD
  run "$OUT/base"
fi

echo "== нынешняя сборка"
rm -rf "$OUT/new"
build "$ROOT" "$OUT/new" "$CACHE_NEW"
run "$OUT/new"
same "настоящий каталог не изменён" "$(shasum -a 256 < "$ROOT/Catalog/catalog.json")" "$CATALOG_BEFORE"
