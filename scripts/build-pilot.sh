#!/bin/bash
# Сборка для пилота без публикации: центр читает каталог из папки вывода, а не с GitHub.
#   scripts/build-pilot.sh <папка-вывода>
# Адрес каталога подменяется только флагом компилятора KIT_PILOT_CATALOG: окружением, аргументами и настройками
# обычную сборку не перенаправить. Утилита ставится в /Applications/Utilitumus как настоящая.
# Сам скрипт в /Applications ничего не кладёт: что делать дальше, он печатает.
set -euo pipefail
# Установщик отвергает архив с файлами, доступными на запись группе или всем.
umask 022

[ $# -eq 1 ] || { echo "Использование: scripts/build-pilot.sh <папка-вывода>" >&2; exit 1; }
fail() { echo "$1" >&2; exit 1; }

case "$1" in
  /*) OUT="$1" ;;
  *) OUT="$PWD/$1" ;;
esac
# Путь попадает в строку Swift, в JSON и в file://-адрес: без пробелов, кавычек и кириллицы.
# Вне UTF-8: диапазоны не должны зависеть от языка системы.
matches() { local LC_ALL=C; [[ "$1" =~ $2 ]]; }
matches "$OUT" '^[A-Za-z0-9/._-]+$' || fail "В пути к папке вывода только латиница, цифры и . _ - /: ${OUT}"
cd "$(dirname "$0")/.."

AWAKE_VERSION="1.0.0"
MIN_HUB="0.6.0"
LEAF="$(grep -oE '"[0-9a-f]{40}"' Sources/Kit/KitSigning.swift | head -1 | tr -d '"')"
HUB_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Info.plist)"
if [ "$(printf '%s\n%s\n' "$MIN_HUB" "$HUB_VERSION" | sort -V | head -1)" != "$MIN_HUB" ]; then
  fail "Центр ${HUB_VERSION} старше ${MIN_HUB}: каталог его не примет."
fi
# Чужую подпись установщик центра отвергнет: лучше узнать об этом сейчас.
signed_by_author() {
  codesign --verify --deep --strict -R="identifier \"$2\" and certificate leaf = H\"$LEAF\"" "$1" 2>/dev/null \
    || fail "$1 не подписан сертификатом «Utilitumus Signing»."
}

mkdir -p "$OUT"
scripts/build-app.sh awake Awake "$AWAKE_VERSION" "$OUT/app"
signed_by_author "$OUT/app/Awake.app" local.utilitumus.app.awake
ZIP="$OUT/Awake.zip"
rm -f -- "$ZIP"
ditto -c -k --keepParent "$OUT/app/Awake.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE_MB="$(( ($(stat -f %z "$ZIP") + 999999) / 1000000 ))"

CATALOG="$OUT/catalog.json"
cat > "$CATALOG" <<JSON
{"schema":1,"apps":[{"id":"awake","version":"$AWAKE_VERSION","minHub":"$MIN_HUB","url":"file://$ZIP","sha256":"$SHA","sizeMB":$SIZE_MB}]}
JSON

SOURCE="$OUT/PilotCatalog.swift"
cat > "$SOURCE" <<SWIFT
enum KitPilotCatalog {
    static let path = "$CATALOG"
}
SWIFT

NO_INSTALL=1 BUILD_DIR="$OUT/hub" ./build.sh --pilot-catalog-source "$SOURCE"
HUB="$OUT/hub/Utilitumus.app"
signed_by_author "$HUB" local.utilitumus
STRINGS="$(strings -a "$HUB/Contents/MacOS/Utilitumus")"
[[ "$STRINGS" == *"$CATALOG"* ]] || fail "В собранном центре нет пути к каталогу пилота."

cat <<TEXT

Собрано для пилота, ничего не установлено и не выложено.
  Центр $HUB_VERSION: $HUB
  Каталог: $CATALOG
  Не спать $AWAKE_VERSION: $ZIP, sha256 $SHA

Что сделать автору:
  1. Закрыть Utilitumus.
  2. Поставить центр:
       rm -rf /Applications/Utilitumus.app && ditto "$HUB" /Applications/Utilitumus.app
       open /Applications/Utilitumus.app
  3. Если встроенный «Не спать» включён, в Сторе нажать «Удалить». Настройки останутся.
  4. В Сторе нажать «＋» на «Не спать». Приложение встанет в /Applications/Utilitumus/Awake.app,
     агент в ~/Library/LaunchAgents/local.utilitumus.app.awake.plist.
Папку $OUT не удалять до конца пилота: центр читает каталог из неё.
Вернуть как было: «Удалить» в Сторе, затем обычный install.sh без аргументов поставит выпущенный центр.
TEXT
