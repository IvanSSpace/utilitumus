#!/bin/bash
# Общий выпуск: все утилиты, каталог, потом центр. По умолчанию --dry-run: собирает, проверяет, печатает план,
# ничего не выкладывает (ни gh, ни push, ни тега, настоящий каталог не меняется).
#   ./scripts/release-all.sh [--dry-run] --note awake="Что изменилось" [--note mouse="..."] ...
#   ./scripts/release-all.sh --publish --note awake="..." ...     (нужен терминал: версию центра печатают руками)
# Заметка нужна каждой утилите, которой есть что выкладывать; заметки центра — Resources/WhatsNew.json.
# Порядок выкладки: релизы утилит (--latest=false), один коммит каталога, центр с --latest=true последним:
# старые центры берут /releases/latest, и пока в каталоге нет утилит, центр не должен стать «последним».
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "$1" >&2; exit 1; }
USAGE='Использование: ./scripts/release-all.sh [--dry-run | --publish] --note <id>="Что изменилось" ...'

# Публикация только по явному --publish: опечатка не должна превращаться в настоящий выпуск.
PUBLISH=""
EXPLICIT_DRY=""
NOTE_IDS=()
NOTE_TEXTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) EXPLICIT_DRY=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    --note)
      if [ $# -lt 2 ] || [[ "$2" != *=* ]] || [ -z "${2#*=}" ]; then
        fail "После --note нужно <id>=текст."
      fi
      NOTE_IDS+=("${2%%=*}")
      NOTE_TEXTS+=("${2#*=}")
      shift 2
      ;;
    *) fail "Неизвестный аргумент: ${1}. ${USAGE}" ;;
  esac
done
[ -z "$PUBLISH" ] || [ -z "$EXPLICIT_DRY" ] || fail "--dry-run и --publish вместе нельзя. ${USAGE}"

REPO="IvanSSpace/utilitumus"
# Новая запись в каталоге; у имеющейся minHub не меняется (как в release-app.sh).
MIN_HUB="0.6.0"
LEAF="$(grep -oE '"[0-9a-f]{40}"' Sources/Kit/KitSigning.swift | head -1 | tr -d '"')"
EPOCH="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -n "$LEAF" ] && [ -n "$EPOCH" ] || fail "В Sources/Kit/KitSigning.swift нет хэша сертификата или securityEpoch."
HUB_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
HUB_TAG="v$HUB_VERSION"

# --- 1. Репозиторий
echo "== 1. Репозиторий"
[ -z "$(git status --porcelain)" ] || fail "Есть незакоммиченные изменения — сначала закоммить их."
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "Локальный main не совпадает с GitHub — сначала git push."
echo "чисто, HEAD совпадает с origin/main"

# --- 2. Таблица версий
echo "== 2. Версии"
IDS=(); NAMES=(); VERSIONS=(); TODO=()
for manifest in Sources/Apps/*/manifest.json; do
  [ -e "$manifest" ] || continue
  dir="$(dirname "$manifest")"
  name="$(basename "$dir")"
  [ -f "$dir/Info.plist" ] || continue
  IDS+=("$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')")
  NAMES+=("$name")
  VERSIONS+=("$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dir/Info.plist")")
done
[ ${#IDS[@]} -gt 0 ] || fail "В Sources/Apps нет утилит."
catalog_version() {
  python3 -I -c '
import json, sys
catalog = json.load(open("Catalog/catalog.json", encoding="utf-8"))
print(next((a["version"] for a in catalog["apps"] if a["id"] == sys.argv[1]), ""))' "$1"
}
printf '%-10s %-10s %-10s %s\n' утилита версия каталог действие
for i in "${!IDS[@]}"; do
  in_catalog="$(catalog_version "${IDS[$i]}")"
  if [ "$in_catalog" = "${VERSIONS[$i]}" ]; then
    action="уже в каталоге"
    TODO+=("")
  else
    action="выпустить ${IDS[$i]}-v${VERSIONS[$i]}"
    TODO+=(1)
    if git rev-parse -q --verify "refs/tags/${IDS[$i]}-v${VERSIONS[$i]}" >/dev/null; then
      fail "Тег ${IDS[$i]}-v${VERSIONS[$i]} уже есть, а в каталоге записи нет — разберись вручную."
    fi
  fi
  printf '%-10s %-10s %-10s %s\n' "${IDS[$i]}" "${VERSIONS[$i]}" "${in_catalog:--}" "$action"
done
printf '%-10s %-10s %-10s %s\n' центр "$HUB_VERSION" - "выпустить $HUB_TAG последним"
if git rev-parse -q --verify "refs/tags/$HUB_TAG" >/dev/null; then fail "Тег $HUB_TAG уже есть."; fi

note_of() { # id: заметки, по одной на строку
  local j
  for j in "${!NOTE_IDS[@]}"; do
    if [ "${NOTE_IDS[$j]}" = "$1" ]; then printf '%s\n' "${NOTE_TEXTS[$j]}"; fi
  done
  return 0
}
for j in "${!NOTE_IDS[@]}"; do
  found=""
  for i in "${!IDS[@]}"; do
    if [ "${IDS[$i]}" = "${NOTE_IDS[$j]}" ] && [ -n "${TODO[$i]}" ]; then found=1; fi
  done
  [ -n "$found" ] || fail "Заметка для «${NOTE_IDS[$j]}»: такой утилиты нет среди выпускаемых."
done
for i in "${!IDS[@]}"; do
  if [ -n "${TODO[$i]}" ] && [ -z "$(note_of "${IDS[$i]}")" ]; then
    fail "Нет заметок для ${IDS[$i]} ${VERSIONS[$i]}: добавь --note ${IDS[$i]}=\"Что изменилось\"."
  fi
  if [ "$(note_of "${IDS[$i]}" | grep -c .)" -gt 8 ]; then fail "Заметок для ${IDS[$i]} больше 8."; fi
done
# Те же пределы, что у SatelliteCatalog.cleanNotes и release-app.sh.
for j in "${!NOTE_IDS[@]}"; do
  python3 -I -c '
import sys, unicodedata
note = sys.argv[1]
if not note.strip():
    sys.exit("Пустая заметка.")
if len(note) > 200:
    sys.exit("Заметка длиннее 200 знаков: %s" % note)
if any(unicodedata.category(c) in ("Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp") for c in note):
    sys.exit("В заметке перевод строки или управляющий символ: %r" % note)' "${NOTE_TEXTS[$j]}"
done
HUB_NOTES="$(python3 -I -c '
import json, sys
v = sys.argv[1]
e = next((e for e in json.load(open("Resources/WhatsNew.json", encoding="utf-8")) if e["version"] == v), None)
print("\n".join("- " + (i["text"] if isinstance(i, dict) else i) for i in e["items"]) if e else "")' "$HUB_VERSION")"
[ -n "$HUB_NOTES" ] || fail "Нет записи для $HUB_VERSION в Resources/WhatsNew.json — допиши, что изменилось."

# --- 3. Сборка и проверка
echo "== 3. Сборка и проверка"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-all.XXXXXX")"
echo "рабочая папка: $WORK"
for i in "${!IDS[@]}"; do
  [ -n "${TODO[$i]}" ] || continue
  id="${IDS[$i]}"; name="${NAMES[$i]}"; version="${VERSIONS[$i]}"
  scripts/build-app.sh "$id" "$name" "$version" "$WORK"
  app="$WORK/$name.app"
  [ -d "$app" ] || fail "Сборка $name не дала $app."
  codesign --verify --deep --strict -R="identifier \"local.utilitumus.app.$id\" and certificate leaf = H\"$LEAF\"" "$app" 2>/dev/null \
    || fail "$name: подпись не «Utilitumus Signing» или не тот identifier — выпуск остановлен."
  found="$(plutil -extract UtilitumusSecurityEpoch xml1 -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$found" == *"<string>$EPOCH</string>"* ]] || fail "$name: в собранном бандле нет UtilitumusSecurityEpoch ${EPOCH}."
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version" ] \
    || fail "$name: версия в бандле не $version."
  # Вложенные помощники: каждый на месте и подписан тем же сертификатом со своим identifier.
  helpers="$(python3 -I -c '
import json, sys
for h in json.load(open(sys.argv[1], encoding="utf-8")).get("helpers", []):
    print(h["path"] + "|" + h["identifier"])' "Sources/Apps/$name/manifest.json")"
  while IFS='|' read -r path identifier; do
    [ -n "$path" ] || continue
    [ -e "$app/$path" ] || fail "$name: нет помощника $path."
    codesign --verify --strict -R="identifier \"$identifier\" and certificate leaf = H\"$LEAF\"" "$app/$path" 2>/dev/null \
      || fail "$name: помощник $path не подписан как $identifier."
  done <<<"$helpers"
  ditto -c -k --keepParent "$app" "$WORK/$name.zip"
  echo "ok   $name $version: подпись, сертификат, метка $EPOCH, помощники"
done

# --- 4. Каталог (в рабочей папке; настоящий меняется только при выкладке)
echo "== 4. Каталог"
cp Catalog/catalog.json "$WORK/catalog.json"
for i in "${!IDS[@]}"; do
  [ -n "${TODO[$i]}" ] || continue
  id="${IDS[$i]}"; name="${NAMES[$i]}"; version="${VERSIONS[$i]}"
  notes=()
  while IFS= read -r line; do
    if [ -n "$line" ]; then notes+=("$line"); fi
  done <<<"$(note_of "$id")"
  python3 -I -c '
import hashlib, json, math, os, sys
target, app_id, version, url, archive, min_hub, *notes = sys.argv[1:]
with open(target, encoding="utf-8") as f:
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
    f.write("\n")' "$WORK/catalog.json" "$id" "$version" \
    "https://github.com/$REPO/releases/download/$id-v$version/$name.zip" "$WORK/$name.zip" "$MIN_HUB" "${notes[@]}"
  echo "ok   $id $version: запись с ${#notes[@]} заметками"
done

# --- 5. План
PLAN=()
add() { local cmd="" a; for a in "$@"; do cmd+="$(printf '%q ' "$a")"; done; PLAN+=("${cmd% }"); }
RELEASED=()
for i in "${!IDS[@]}"; do
  [ -n "${TODO[$i]}" ] || continue
  tag="${IDS[$i]}-v${VERSIONS[$i]}"
  add git tag "$tag"
  add git push -q origin "$tag"
  add gh release create "$tag" "$WORK/${NAMES[$i]}.zip" -R "$REPO" --title "${NAMES[$i]} ${VERSIONS[$i]}" --notes "${NAMES[$i]} ${VERSIONS[$i]}" --latest=false --verify-tag
  RELEASED+=("$tag")
done
if [ ${#RELEASED[@]} -gt 0 ]; then
  add cp "$WORK/catalog.json" Catalog/catalog.json
  add git add Catalog/catalog.json
  add git commit -q -m "Каталог: общий выпуск, центр $HUB_VERSION"
  add git push -q origin HEAD:main
fi
# Центр сам делает коммит версии, тег и релиз с --latest=true (scripts/release.sh).
add scripts/release.sh "$HUB_VERSION"

echo "== План выкладки"
for step in "${PLAN[@]}"; do echo "+ $step"; done
echo "Служба вентиляторов: v5 должна выйти вместе с этим центром ($HUB_TAG). Центр 0.5.3 управляет службой v4 и новую не ставит;"
echo "утилита Fans с v5 до выхода центра не должна попасть к людям, а центр без неё не должен выйти."
echo "Центр идёт последним и с --latest=true: старые центры берут /releases/latest."

if [ -z "$PUBLISH" ]; then
  echo "Ничего не выложено (--dry-run). Рабочая папка: $WORK"
  exit 0
fi

# --- 6. Выкладка
[ -t 0 ] || fail "Для --publish нужен терминал: версию центра печатают руками."
printf 'Выложить центр %s и утилиты (%s)? Напиши версию центра: ' "$HUB_VERSION" "${RELEASED[*]:-нет}"
read -r typed
[ "$typed" = "$HUB_VERSION" ] || fail "Версия не совпала, ничего не выложено."
export GH_TOKEN="${GH_TOKEN:-$(gh auth token --user IvanSSpace 2>/dev/null || true)}"

done_count=0
for step in "${PLAN[@]}"; do
  if ! eval "$step"; then
    echo "ОСТАНОВЛЕНО на шаге: $step" >&2
    echo "Выполнено шагов: $done_count из ${#PLAN[@]}. Архивы и каталог: $WORK" >&2
    for s in "${PLAN[@]:0:$done_count}"; do echo "  выложено: $s" >&2; done
    echo "Продолжить вручную, по порядку, начиная с упавшего шага:" >&2
    for s in "${PLAN[@]:$done_count}"; do echo "  $s" >&2; done
    exit 1
  fi
  done_count=$((done_count + 1))
done
echo "Выложено: https://github.com/$REPO/releases/tag/$HUB_TAG"
