#!/bin/bash
# Сборка для пилота без публикации: центр читает каталог из папки вывода, а не с GitHub.
#   scripts/build-pilot.sh <папка-вывода>
#   PILOT_ONLY="voice bots" scripts/build-pilot.sh <папка-вывода> — только эти утилиты и центр, в уже собранную папку:
#     остальные записи каталога остаются как были. PILOT_ONLY="-" — один центр. PILOT_HUB_DIR — куда положить центр.
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

VERSION="${PILOT_VERSION:-1.0.0}"
# Все модули. Автопереход в пилоте выключен: утилита встаёт только по «＋» автора.
PILOT_APPS="awake:Awake sound:Sound mouse:Mouse mixer:Mixer stash:Stash load:Load voice:Voice keyboard:Keyboard clipboard:Clipboard fans:Fans browser:Browser bots:Bots"
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
ENTRIES=""
for pair in $PILOT_APPS; do
  ID="${pair%%:*}"; NAME="${pair##*:}"
  if [ -n "${PILOT_ONLY:-}" ] && [[ " $PILOT_ONLY " != *" $ID "* ]]; then continue; fi
  scripts/build-app.sh "$ID" "$NAME" "$VERSION" "$OUT/app"
  signed_by_author "$OUT/app/$NAME.app" "local.utilitumus.app.$ID"
  ZIP="$OUT/$NAME.zip"
  rm -f -- "$ZIP"
  ditto -c -k --keepParent "$OUT/app/$NAME.app" "$ZIP"
  SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  SIZE_MB="$(( ($(stat -f %z "$ZIP") + 999999) / 1000000 ))"
  ENTRIES="${ENTRIES:+$ENTRIES,}{\"id\":\"$ID\",\"version\":\"$VERSION\",\"minHub\":\"$MIN_HUB\",\"url\":\"file://$ZIP\",\"sha256\":\"$SHA\",\"sizeMB\":$SIZE_MB,\"notes\":[\"Первая отдельная версия\"]}"
done

CATALOG="$OUT/catalog.json"
if [ -n "${PILOT_ONLY:-}" ]; then
  [ -f "$CATALOG" ] || fail "PILOT_ONLY: в $OUT нет каталога, сначала полная сборка."
  # Новые записи заменяют старые с тем же id, порядок прежний.
  ENTRIES="$ENTRIES" python3 -I - "$CATALOG" <<'PY'
import json, os, sys
path = sys.argv[1]
catalog = json.load(open(path))
fresh = {a["id"]: a for a in json.loads("[" + os.environ["ENTRIES"] + "]")}
apps = [fresh.pop(a["id"], a) for a in catalog["apps"]] + list(fresh.values())
catalog["apps"] = apps
json.dump(catalog, open(path, "w"), ensure_ascii=False)
PY
else
  printf '{"schema":1,"apps":[%s]}\n' "$ENTRIES" > "$CATALOG"
fi

SOURCE="$OUT/PilotCatalog.swift"
cat > "$SOURCE" <<SWIFT
enum KitPilotCatalog {
    static let path = "$CATALOG"
}
SWIFT

HUB_DIR="${PILOT_HUB_DIR:-$OUT/hub}"
NO_INSTALL=1 BUILD_DIR="$HUB_DIR" ./build.sh --pilot-catalog-source "$SOURCE"
HUB="$HUB_DIR/Utilitumus.app"
signed_by_author "$HUB" local.utilitumus
STRINGS="$(strings -a "$HUB/Contents/MacOS/Utilitumus")"
[[ "$STRINGS" == *"$CATALOG"* ]] || fail "В собранном центре нет пути к каталогу пилота."

cat <<TEXT

Собрано для пилота, ничего не установлено и не выложено.
  Центр $HUB_VERSION: $HUB
  Каталог: $CATALOG
  Утилиты $VERSION: $PILOT_APPS

Что сделать автору:
  1. Закрыть Utilitumus.
  2. Поставить центр:
       rm -rf /Applications/Utilitumus.app && ditto "$HUB" /Applications/Utilitumus.app
       open /Applications/Utilitumus.app
  3. Если встроенный модуль включён, в Сторе нажать «Удалить». Настройки останутся.
  4. В Сторе нажать «＋». Приложение встанет в /Applications/Utilitumus/<Имя>.app,
     агент в ~/Library/LaunchAgents/local.utilitumus.app.<id>.plist.
Автопереход в пилоте выключен: ставишь сам. 
Папку $OUT не удалять до конца пилота: центр читает каталог из неё.
Вернуть как было: «Удалить» в Сторе, затем обычный install.sh без аргументов поставит выпущенный центр.
TEXT
