#!/bin/bash
# Выпуск утилиты со своего Mac: собрать, подписать, выложить в GitHub Releases без пометки Latest
# (старые центры берут /releases/latest), затем записать в Catalog/catalog.json.
#   ./scripts/release-app.sh awake Awake 1.0.0 --note "Что изменилось" [--note "Ещё"] [--dry-run]
# --note обязателен: заметки попадают в каталог и видны в Сторе рядом с обновлением.
# --dry-run проверяет и собирает так же, но вместо выкладки печатает команды, а новый каталог
# и архив оставляет во временной папке.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "$1" >&2; exit 1; }

USAGE='Использование: ./scripts/release-app.sh <id> <Имя> X.Y.Z --note "Что изменилось" [--note "Ещё"] [--dry-run]'
if [ $# -lt 3 ]; then
  fail "$USAGE"
fi
ID="$1"
NAME="$2"
VERSION="$3"
shift 3
DRY_RUN=""
NOTES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --note)
      # Иначе «--note --dry-run» съел бы флаг, и вместо проверки вышел бы настоящий выпуск.
      if [ $# -lt 2 ] || [ "${2#--}" != "$2" ]; then
        fail "После --note нужен текст заметки."
      fi
      NOTES+=("$2")
      shift 2
      ;;
    # Опечатка в --dry-run не должна превращаться в настоящий выпуск.
    *) fail "Неизвестный аргумент: ${1}. ${USAGE}" ;;
  esac
done
if [ ${#NOTES[@]} -eq 0 ]; then
  fail "Нет заметок: напиши через --note, что изменилось в ${VERSION}."
fi
# Те же пределы у SatelliteCatalog.cleanNotes. Заметку, которую центр исправил бы при чтении, выпуск отвергает.
python3 -c '
import sys, unicodedata
MAX_NOTES = 8
MAX_NOTE_LENGTH = 200
notes = sys.argv[1:]
if len(notes) > MAX_NOTES:
    sys.exit("Заметок больше %d." % MAX_NOTES)
for note in notes:
    if not note.strip():
        sys.exit("Пустая заметка.")
    if len(note) > MAX_NOTE_LENGTH:
        sys.exit("Заметка длиннее %d знаков: %s" % (MAX_NOTE_LENGTH, note))
    if any(unicodedata.category(c) in ("Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp") for c in note):
        sys.exit("В заметке перевод строки или управляющий символ: %r" % note)
' "${NOTES[@]}"

TAG="$ID-v$VERSION"
REPO="IvanSSpace/utilitumus"
# Новая запись в каталоге. Первая версия центра, которая умеет вести утилиты; у имеющейся записи minHub не меняется.
MIN_HUB="0.6.0"
# Тот же хэш, что в Sources/Kit/KitSigning.swift и install.sh: чужую подпись установщик всё равно отвергнет.
TRUSTED_LEAF_HASH="31e93f4b9e4ada7f6de82066c2194b35d92f7db4"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token --user IvanSSpace 2>/dev/null || true)}"

if [ -n "$(git status --porcelain)" ]; then
  fail "Есть незакоммиченные изменения — сначала закоммить их."
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  fail "Локальный main не совпадает с GitHub — сначала git push."
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  fail "Релиз ${TAG} уже есть."
fi

# С шаблоном: без него mktemp на macOS не смотрит на TMPDIR.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-app.XXXXXX")"
[ -n "$DRY_RUN" ] || trap 'rm -rf -- "$WORK"' EXIT

# Всё, что меняет репозиторий или GitHub, идёт через run: --dry-run проходит те же шаги в том же порядке.
run() {
  if [ -n "$DRY_RUN" ]; then
    echo "+ $*"
  else
    "$@"
  fi
}

scripts/build-app.sh "$ID" "$NAME" "$VERSION" "$WORK"
APP="$WORK/$NAME.app"
if ! codesign --verify --deep --strict \
  -R="identifier \"local.utilitumus.app.$ID\" and certificate leaf = H\"$TRUSTED_LEAF_HASH\"" "$APP" 2>/dev/null; then
  fail "Сборка не подписана сертификатом «Utilitumus Signing» — релиз не выкладываю."
fi
ZIP="$WORK/$NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# Каталог готовится до выкладки: ошибка в нём не должна оставить выпуск без записи.
# Без minHub или sizeMB центр отвергнет каталог целиком (CatalogApp.init(from:)).
NEW_CATALOG="$WORK/catalog.json"
python3 -c '
import hashlib, json, math, os, sys
source, target, app_id, version, url, archive, min_hub, *notes = sys.argv[1:]
with open(source, encoding="utf-8") as f:
    catalog = json.load(f)
if catalog["schema"] != 1:
    sys.exit("Каталог другого формата: %s" % catalog["schema"])
entry = next((a for a in catalog["apps"] if a["id"] == app_id), None)
if entry is None:
    entry = {"id": app_id, "version": version, "minHub": min_hub}
    catalog["apps"].append(entry)
with open(archive, "rb") as f:
    sha256 = hashlib.sha256(f.read()).hexdigest()
entry.update(version=version, url=url, sha256=sha256, sizeMB=math.ceil(os.path.getsize(archive) / 1048576), notes=notes)
with open(target, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2)
    f.write("\n")
' Catalog/catalog.json "$NEW_CATALOG" "$ID" "$VERSION" \
  "https://github.com/$REPO/releases/download/$TAG/$NAME.zip" "$ZIP" "$MIN_HUB" "${NOTES[@]}"

if [ -n "$DRY_RUN" ]; then
  echo "Архив: $ZIP"
  echo "Каталог: $NEW_CATALOG"
fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || run git tag "$TAG"
run git push -q origin "$TAG"
run gh release create "$TAG" "$ZIP" -R "$REPO" --title "$NAME $VERSION" --notes "$NAME $VERSION" --latest=false --verify-tag

# Только после выкладки: каталог не должен обещать ассет, которого ещё нет.
if ! { run cp "$NEW_CATALOG" Catalog/catalog.json &&
  run git add Catalog/catalog.json &&
  run git commit -q -m "Каталог: $ID $VERSION" &&
  run git push -q origin HEAD:main; }; then
  fail "Выпуск ${TAG} выложен, а каталог не опубликован: допиши Catalog/catalog.json, закоммить и запушь вручную."
fi

if [ -n "$DRY_RUN" ]; then
  echo "Ничего не выложено (--dry-run)."
else
  echo "Выложено: https://github.com/$REPO/releases/tag/$TAG"
fi
