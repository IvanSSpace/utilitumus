#!/bin/bash
# Выпуск утилиты со своего Mac: собрать, подписать, выложить в GitHub Releases без пометки Latest
# (старые центры берут /releases/latest), затем записать в Catalog/catalog.json.
#   ./scripts/release-app.sh awake Awake 1.0.0 [--dry-run]
# --dry-run проверяет и собирает так же, но вместо выкладки печатает команды, а новый каталог
# и архив оставляет во временной папке.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "$1" >&2; exit 1; }

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  fail "Использование: ./scripts/release-app.sh <id> <Имя> X.Y.Z [--dry-run]"
fi
ID="$1"
NAME="$2"
VERSION="$3"
DRY_RUN=""
if [ $# -eq 4 ]; then
  # Опечатка в --dry-run не должна превращаться в настоящий выпуск.
  [ "$4" = "--dry-run" ] || fail "Неизвестный аргумент: ${4}"
  DRY_RUN=1
fi

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
source, target, app_id, version, url, archive, min_hub = sys.argv[1:]
with open(source) as f:
    catalog = json.load(f)
if catalog["schema"] != 1:
    sys.exit("Каталог другого формата: %s" % catalog["schema"])
entry = next((a for a in catalog["apps"] if a["id"] == app_id), None)
if entry is None:
    entry = {"id": app_id, "version": version, "minHub": min_hub}
    catalog["apps"].append(entry)
with open(archive, "rb") as f:
    sha256 = hashlib.sha256(f.read()).hexdigest()
entry.update(version=version, url=url, sha256=sha256, sizeMB=math.ceil(os.path.getsize(archive) / 1048576))
with open(target, "w") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2)
    f.write("\n")
' Catalog/catalog.json "$NEW_CATALOG" "$ID" "$VERSION" \
  "https://github.com/$REPO/releases/download/$TAG/$NAME.zip" "$ZIP" "$MIN_HUB"

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
