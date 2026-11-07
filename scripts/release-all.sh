#!/bin/bash
# Общий выпуск: все утилиты, каталог, потом центр. По умолчанию --dry-run: собирает, проверяет, печатает план,
# ничего не выкладывает (ни push, ни тега, настоящий каталог не меняется; gh только читает, и только если тег уже есть).
#   ./scripts/release-all.sh [--dry-run] --note awake="Что изменилось" [--note mouse="..."] ...
#   ./scripts/release-all.sh --publish --note awake="..." ...     (нужен терминал: версию центра печатают руками)
#   --only id,id  — собрать, выпустить и записать в каталог только эти утилиты; остальные и их записи в каталоге не трогаются
#                   (поэтапный выпуск: в каталоге только то, что автор проверил).
#   --utilities-only — без центра: релизы утилит и один коммит каталога. При --publish печатают наибольшую версию из выпускаемых утилит.
# Заметка нужна каждой утилите, которой есть что выкладывать; заметки центра — Resources/WhatsNew.json.
# Порядок выкладки: релизы утилит (--latest=false), один коммит каталога, центр с --latest=true последним:
# старые центры берут /releases/latest, и пока в каталоге нет утилит, центр не должен стать «последним».
# Сборки и релизы утилит идут параллельно (RELEASE_ALL_JOBS, по умолчанию 5), логи в <рабочая папка>/logs. Каталог и центр — только
# после всех релизов. Сорвалось — запусти ту же команду ещё раз: готовое не повторится, а в каталог попадёт сумма выложенного архива.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "${UTILITUMUS_DEV_CACHE:-}" ] || { echo "UTILITUMUS_DEV_CACHE задан: выпуск только из обычной сборки (-O)." >&2; exit 1; }

fail() { echo "$1" >&2; exit 1; }
USAGE='Использование: ./scripts/release-all.sh [--dry-run | --publish] [--only id,id] [--utilities-only] --note <id>="Что изменилось" ...'
# Кавычки для eval и для вывода: printf %q в bash 3.2 портит кириллицу в $'...', такое не скопировать из терминала.
shell_quote() {
  case "$1" in
    "" | *[!A-Za-z0-9_./:=,+@%-]*) printf "'%s'" "${1//\'/\'\\\'\'}" ;;
    *) printf '%s' "$1" ;;
  esac
}
quoted() { local cmd="" a; for a in "$@"; do cmd+="$(shell_quote "$a") "; done; printf '%s' "${cmd% }"; }
# Для подсказки «запусти ту же команду».
SAME_COMMAND="$(quoted ./scripts/release-all.sh "$@")"

# Публикация только по явному --publish: опечатка не должна превращаться в настоящий выпуск.
PUBLISH=""
EXPLICIT_DRY=""
NOTE_IDS=()
NOTE_TEXTS=()
ONLY=""
UTILITIES_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) EXPLICIT_DRY=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    --utilities-only) UTILITIES_ONLY=1; shift ;;
    --only)
      if [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then fail "После --only нужен список id через запятую. ${USAGE}"; fi
      ONLY=",$2,"
      shift 2
      ;;
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
MIN_HUB="0.7.0"
LEAF="$(grep -oE '"[0-9a-f]{40}"' Sources/Kit/KitSigning.swift | head -1 | tr -d '"')"
EPOCH="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -n "$LEAF" ] && [ -n "$EPOCH" ] || fail "В Sources/Kit/KitSigning.swift нет хэша сертификата или securityEpoch."
HUB_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
HUB_TAG="v$HUB_VERSION"
JOBS="${RELEASE_ALL_JOBS:-5}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_ALL_JOBS: нужно целое больше нуля."
# swiftc без -j компилирует файлы по одному. 5 сборок по -j2 — это 10 компиляторов на 10 ядер, около 2 ГБ памяти: быстрее 6 по одному и
# наравне с 6 по -j2, но без очереди на ядра (замер: 102, 67 и 66 с, пик загрузки 7, 10 и 22).
SWIFT_JOBS=2

# --- 1. Репозиторий
echo "== 1. Репозиторий"
[ -z "$(git status --porcelain)" ] || fail "Есть незакоммиченные изменения — сначала закоммить их."
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "Локальный main не совпадает с GitHub — сначала git push."
echo "чисто, HEAD совпадает с origin/main"
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_TAGS="$(git ls-remote --tags origin)"

# Без gh, пока тега нет ни здесь, ни в origin: релиз идёт только по готовому тегу (--verify-tag), а --dry-run первого выпуска обходится без gh.
# Токен в основной оболочке: дальше им скачивают архив с релиза, а активный аккаунт gh на этом Mac другой.
use_release_token() { [ -n "${GH_TOKEN:-}" ] || export GH_TOKEN="$(gh auth token --user IvanSSpace 2>/dev/null || true)"; }
local_tag() { git rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true; }
remote_tag() { LC_ALL=C awk -v ref="refs/tags/$1" '$2 == ref { print $1 }' <<<"$REMOTE_TAGS"; }
# Что на GitHub по тегу: none, ready или broken (черновик или нет архива). Сбой сети не должен выглядеть как «релиза нет».
release_state() { # тег, имя архива
  local out
  if ! out="$(gh release view "$1" -R "$REPO" --json isDraft,assets --jq '"\(.isDraft) " + ([.assets[].name] | join(","))' 2>&1)"; then
    [[ "$out" == *"release not found"* ]] || fail "gh не ответил про релиз ${1}: ${out}"
    echo none
    return 0
  fi
  case "$out" in
    "false "*) [[ ",${out#false }," == *",$2,"* ]] && echo ready || echo broken ;;
    *) echo broken ;;
  esac
}

# --- 2. Таблица версий
echo "== 2. Версии"
IDS=(); NAMES=(); VERSIONS=(); TODO=(); STATES=()
for manifest in Sources/Apps/*/manifest.json; do
  [ -e "$manifest" ] || continue
  dir="$(dirname "$manifest")"
  name="$(basename "$dir")"
  [ -f "$dir/Info.plist" ] || continue
  if [ -n "$ONLY" ] && [[ "$ONLY" != *",$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]'),"* ]]; then continue; fi
  IDS+=("$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')")
  NAMES+=("$name")
  VERSIONS+=("$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dir/Info.plist")")
done
[ ${#IDS[@]} -gt 0 ] || fail "В Sources/Apps нет утилит."
# Опечатка в --only не должна молча выпустить меньше, чем задумано.
if [ -n "$ONLY" ]; then
  wanted="${ONLY#,}"; wanted="${wanted%,}"
  IFS=',' read -r -a WANTED <<<"$wanted"
  for w in "${WANTED[@]}"; do
    found=""
    for id in "${IDS[@]}"; do if [ "$id" = "$w" ]; then found=1; fi; done
    [ -n "$found" ] || fail "--only: утилиты «${w}» нет в Sources/Apps."
  done
  [ ${#IDS[@]} -eq ${#WANTED[@]} ] || fail "--only: id повторяется."
fi
catalog_version() {
  python3 -I -c '
import json, sys
catalog = json.load(open("Catalog/catalog.json", encoding="utf-8"))
print(next((a["version"] for a in catalog["apps"] if a["id"] == sys.argv[1]), ""))' "$1"
}
printf '%-10s %-10s %-10s %s\n' утилита версия каталог действие
for i in "${!IDS[@]}"; do
  in_catalog="$(catalog_version "${IDS[$i]}")"
  # scripts/fix.sh выпускает на патч выше, не меняя Info.plist утилиты: каталог бывает новее исходников, и это не повод выпускать старую версию.
  if [ -n "$in_catalog" ] && [ "$(printf '%s\n%s\n' "$in_catalog" "${VERSIONS[$i]}" | sort -V | tail -1)" = "$in_catalog" ]; then
    action="уже в каталоге"
    TODO+=("")
  else
    tag="${IDS[$i]}-v${VERSIONS[$i]}"
    action="выпустить $tag"
    TODO+=(1)
    state=""
    here="$(local_tag "$tag")"; there="$(remote_tag "$tag")"
    if [ -n "$here$there" ]; then
      # Прошлый запуск сорвался до каталога: тег на этом же коммите. Тег на другом коммите — чужая история, сборка ему не соответствует.
      if [ "${here:-$HEAD_SHA}" != "$HEAD_SHA" ] || [ "${there:-$HEAD_SHA}" != "$HEAD_SHA" ]; then
        fail "Тег $tag уже есть, а в каталоге записи нет — разберись вручную. Он не на текущем коммите ($HEAD_SHA)."
      fi
      use_release_token
      state="$(release_state "$tag" "${NAMES[$i]}.zip")"
      case "$state" in
        none) action="продолжить $tag: тег уже есть" ;;
        ready) action="взять архив с релиза $tag" ;;
        *) fail "Релиз $tag есть, но это черновик или в нём нет ${NAMES[$i]}.zip. Посмотри и удали его, тег оставь: gh release delete $tag -R $REPO --yes. Потом запусти снова." ;;
      esac
    fi
    STATES[$i]="$state"
  fi
  printf '%-10s %-10s %-10s %s\n' "${IDS[$i]}" "${VERSIONS[$i]}" "${in_catalog:--}" "$action"
done
if [ -n "$UTILITIES_ONLY" ]; then
  printf '%-10s %-10s %-10s %s\n' центр "$HUB_VERSION" - "не трогаем (--utilities-only)"
  HUB_NOTICE=""
  [ -n "$(remote_tag "$HUB_TAG")" ] || HUB_NOTICE="Центр $HUB_VERSION ещё не выпущен: утилиты выйдут раньше него, и ставить их будет центр прошлой версии."
else
  printf '%-10s %-10s %-10s %s\n' центр "$HUB_VERSION" - "выпустить $HUB_TAG последним"
  # Центр сорвался после своего тега: release.sh продолжит. Выпущенный центр повторно не выйдет.
  here="$(local_tag "$HUB_TAG")"; there="$(remote_tag "$HUB_TAG")"
  if [ -n "$here$there" ]; then
    use_release_token
    if [ "${here:-$HEAD_SHA}" != "$HEAD_SHA" ] || [ "${there:-$HEAD_SHA}" != "$HEAD_SHA" ] || [ "$(release_state "$HUB_TAG" Utilitumus.zip)" != none ]; then
      fail "Тег $HUB_TAG уже есть. Только утилиты, без центра: --utilities-only."
    fi
  fi
fi

catalog_has_note() { # id, заметка
  python3 -I -c '
import json, sys
catalog = json.load(open("Catalog/catalog.json", encoding="utf-8"))
sys.exit(0 if any(a["id"] == sys.argv[1] and sys.argv[2] in a.get("notes", []) for a in catalog["apps"]) else 1)' "$1" "$2"
}
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
    [ "${IDS[$i]}" = "${NOTE_IDS[$j]}" ] || continue
    # Та же команда после сбоя на центре: утилита уже в каталоге с этой самой заметкой.
    if [ -n "${TODO[$i]}" ] || catalog_has_note "${IDS[$i]}" "${NOTE_TEXTS[$j]}"; then found=1; fi
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
if [ -z "$UTILITIES_ONLY" ]; then
HUB_NOTES="$(python3 -I -c '
import json, sys
v = sys.argv[1]
e = next((e for e in json.load(open("Resources/WhatsNew.json", encoding="utf-8")) if e["version"] == v), None)
print("\n".join("- " + (i["text"] if isinstance(i, dict) else i) for i in e["items"]) if e else "")' "$HUB_VERSION")"
[ -n "$HUB_NOTES" ] || fail "Нет записи для $HUB_VERSION в Resources/WhatsNew.json — допиши, что изменилось."
fi
QUEUE=()
for i in "${!IDS[@]}"; do
  if [ -n "${TODO[$i]}" ]; then QUEUE+=("$i"); fi
done
if [ -n "$UTILITIES_ONLY" ] && [ ${#QUEUE[@]} -eq 0 ]; then
  echo "Нечего выпускать: все утилиты уже в каталоге."
  exit 0
fi

# Пул заданий. Системный /bin/bash 3.2 не знает wait -n, поэтому опрос. После первого сбоя новые не начинаются, начатые доходят:
# снятая посреди выгрузки утилита оставила бы черновик релиза. Итог: POOL_OK, POOL_BAD, POOL_LEFT (индексы утилит).
RUN_PIDS=(); RUN_IDX=()
run_pool() { # задание, папка логов, индексы...
  local job="$1" logs="$2" next=0 n st pid
  shift 2
  local queue=("$@") pids idx
  POOL_OK=(); POOL_BAD=(); POOL_LEFT=()
  mkdir -p "$logs"
  while :; do
    while [ ${#POOL_BAD[@]} -eq 0 ] && [ "$next" -lt ${#queue[@]} ] && [ ${#RUN_PIDS[@]} -lt "$JOBS" ]; do
      ( "$job" "${queue[$next]}" ) >"$logs/${IDS[${queue[$next]}]}.log" 2>&1 </dev/null &
      RUN_PIDS+=("$!"); RUN_IDX+=("${queue[$next]}")
      next=$((next + 1))
    done
    [ ${#RUN_PIDS[@]} -gt 0 ] || break
    pids=(); idx=(); n=0
    while [ "$n" -lt ${#RUN_PIDS[@]} ]; do
      pid="${RUN_PIDS[$n]}"
      if kill -0 "$pid" 2>/dev/null; then
        pids+=("$pid"); idx+=("${RUN_IDX[$n]}")
      else
        st=0; wait "$pid" || st=$?
        if [ "$st" -eq 0 ]; then POOL_OK+=("${RUN_IDX[$n]}"); else POOL_BAD+=("${RUN_IDX[$n]}"); fi
        pool_report "$st" "${RUN_IDX[$n]}" "$logs/${IDS[${RUN_IDX[$n]}]}.log"
      fi
      n=$((n + 1))
    done
    RUN_PIDS=(${pids[@]+"${pids[@]}"}); RUN_IDX=(${idx[@]+"${idx[@]}"})
    [ ${#RUN_PIDS[@]} -eq 0 ] || sleep 0.2
  done
  while [ "$next" -lt ${#queue[@]} ]; do POOL_LEFT+=("${queue[$next]}"); next=$((next + 1)); done
}
pool_report() { # код, индекс, лог
  if [ "$1" -eq 0 ]; then
    tail -n 1 "$3"
  else
    echo "КРАСНОЕ: ${IDS[$2]}, лог $3" >&2
    tail -n 30 "$3" >&2
  fi
}
# Фоновые задания скрипта не получают Ctrl-C: без этого начатый релиз вышел бы уже после отмены.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$child"; done
  kill -TERM "$1" 2>/dev/null || true
}
on_interrupt() {
  trap - INT TERM
  local pid
  for pid in ${RUN_PIDS[@]+"${RUN_PIDS[@]}"}; do kill_tree "$pid"; done
  echo "Прервано. Каталог и центр не тронуты. Продолжить: $SAME_COMMAND" >&2
  exit 130
}
trap on_interrupt INT TERM

# --- 3. Сборка и проверка
echo "== 3. Сборка и проверка"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-all.XXXXXX")"
echo "рабочая папка: $WORK"
# Один раз и заранее: несколько одновременных unlock к связке, из которой тут же подписывают, ни к чему.
NEED_BUILD=""
for i in ${QUEUE[@]+"${QUEUE[@]}"}; do
  if [ "${STATES[$i]:-}" != ready ]; then NEED_BUILD=1; fi
done
if [ -n "$NEED_BUILD" ]; then scripts/unlock-signing.sh; fi

build_job() { # индекс: сборка или архив с уже выложенного релиза, потом те же проверки
  local i="$1" id="${IDS[$1]}" name="${NAMES[$1]}" version="${VERSIONS[$1]}" app helpers path identifier found
  app="$WORK/$name.app"
  if [ "${STATES[$i]:-}" = ready ]; then
    # Пересборка дала бы другой архив, и каталог обещал бы сумму, которой нет на релизе.
    gh release download "$id-v$version" -R "$REPO" -p "$name.zip" -D "$WORK"
    ditto -x -k "$WORK/$name.zip" "$WORK"
  else
    UTILITUMUS_SIGNING_UNLOCKED=1 UTILITUMUS_SWIFT_JOBS="$SWIFT_JOBS" scripts/build-app.sh "$id" "$name" "$version" "$WORK"
  fi
  [ -d "$app" ] || fail "Сборка $name не дала $app."
  codesign --verify --deep --strict -R="identifier \"local.utilitumus.app.$id\" and certificate leaf = H\"$LEAF\"" "$app" 2>/dev/null \
    || fail "$name: подпись не «Utilitumus Signing» или не тот identifier — выпуск остановлен."
  found="$(plutil -extract UtilitumusSecurityEpoch xml1 -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$found" == *"<string>$EPOCH</string>"* ]] || fail "$name: в собранном бандле нет UtilitumusSecurityEpoch ${EPOCH}."
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version" ] \
    || fail "$name: версия в бандле не $version."
  scripts/check-no-seam.sh "$app" || fail "$name: в сборке следы тестового шва — выпуск остановлен."
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
  [ "${STATES[$i]:-}" = ready ] || ditto -c -k --keepParent "$app" "$WORK/$name.zip"
  echo "ok   $name $version: подпись, сертификат, метка $EPOCH, помощники"
}
SECONDS=0
run_pool build_job "$WORK/logs" ${QUEUE[@]+"${QUEUE[@]}"}
if [ ${#POOL_BAD[@]} -gt 0 ]; then
  fail "Сборка или проверка красная: ничего не выложено. Логи: $WORK/logs"
fi
echo "сборка и проверка: ${#POOL_OK[@]} за $SECONDS с, разом до $JOBS, swiftc по -j$SWIFT_JOBS"

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
# PUB_STEPS[i] — шаги одной утилиты, по одному на строку: они идут параллельно с другими утилитами. PLAN — потом, по очереди.
PLAN=()
add() { PLAN+=("$(quoted "$@")"); }
RELEASED=(); PUB_QUEUE=(); RELEASED_VERSIONS=""
for i in ${QUEUE[@]+"${QUEUE[@]}"}; do
  tag="${IDS[$i]}-v${VERSIONS[$i]}"
  RELEASED+=("$tag")
  RELEASED_VERSIONS+="${VERSIONS[$i]}"$'\n'
  [ "${STATES[$i]:-}" != ready ] || continue
  steps=""
  if [ -z "$(local_tag "$tag")$(remote_tag "$tag")" ]; then steps+="$(quoted git tag "$tag")"$'\n'; fi
  if [ -z "$(remote_tag "$tag")" ]; then steps+="$(quoted git push -q origin "$tag")"$'\n'; fi
  steps+="$(quoted gh release create "$tag" "$WORK/${NAMES[$i]}.zip" -R "$REPO" --title "${NAMES[$i]} ${VERSIONS[$i]}" --notes "${NAMES[$i]} ${VERSIONS[$i]}" --latest=false --verify-tag)"
  PUB_STEPS[$i]="$steps"
  PUB_QUEUE+=("$i")
done
if [ ${#RELEASED[@]} -gt 0 ]; then
  add cp "$WORK/catalog.json" Catalog/catalog.json
  add git add Catalog/catalog.json
  if [ -n "$UTILITIES_ONLY" ]; then
    add git commit -q -m "Каталог: выпуск утилит (${RELEASED[*]})"
  else
    add git commit -q -m "Каталог: общий выпуск, центр $HUB_VERSION"
  fi
  add git push -q origin HEAD:main
fi
# Центр сам делает коммит версии, тег и релиз с --latest=true (scripts/release.sh).
if [ -z "$UTILITIES_ONLY" ]; then add scripts/release.sh "$HUB_VERSION"; fi

echo "== Каталог после выпуска (в нём: $(python3 -I -c '
import json, sys
print(", ".join("%s %s" % (a["id"], a["version"]) for a in json.load(open(sys.argv[1], encoding="utf-8"))["apps"]) or "пусто")' "$WORK/catalog.json"))"
echo "== План выкладки"
for i in ${QUEUE[@]+"${QUEUE[@]}"}; do
  if [ "${STATES[$i]:-}" = ready ]; then echo "уже выложено: ${IDS[$i]}-v${VERSIONS[$i]}, в каталог идёт сумма архива с релиза"; fi
done
if [ ${#PUB_QUEUE[@]} -gt 0 ]; then
  echo "параллельно, до $JOBS утилит разом:"
  for i in "${PUB_QUEUE[@]}"; do
    while IFS= read -r step; do echo "+ $step"; done <<<"${PUB_STEPS[$i]}"
  done
fi
echo "потом по очереди, только если все релизы выше вышли:"
for step in ${PLAN[@]+"${PLAN[@]}"}; do echo "+ $step"; done
if [ -n "$UTILITIES_ONLY" ]; then
  echo "Центр не выпускается и /releases/latest не меняется."
  if [ -n "$HUB_NOTICE" ]; then echo "$HUB_NOTICE"; fi
else
  echo "Служба вентиляторов: v5 должна выйти вместе с этим центром ($HUB_TAG). Центр 0.5.3 управляет службой v4 и новую не ставит;"
  echo "утилита Fans с v5 до выхода центра не должна попасть к людям, а центр без неё не должен выйти."
  echo "Центр идёт последним и с --latest=true: старые центры берут /releases/latest."
fi

if [ -z "$PUBLISH" ]; then
  echo "Ничего не выложено (--dry-run). Рабочая папка: $WORK"
  exit 0
fi

# --- 6. Выкладка
[ -t 0 ] || fail "Для --publish нужен терминал: версию печатают руками."
if [ -n "$UTILITIES_ONLY" ]; then
  # Версия центра здесь ни при чём, и печатать её по привычке не должно сработать.
  EXPECTED="$(sed '/^$/d' <<<"$RELEASED_VERSIONS" | sort -V | tail -1)"
  printf 'Выложить утилиты (%s) без центра? Напиши наибольшую версию из них, %s: ' "${RELEASED[*]}" "$EXPECTED"
else
  EXPECTED="$HUB_VERSION"
  printf 'Выложить центр %s и утилиты (%s)? Напиши версию центра: ' "$HUB_VERSION" "${RELEASED[*]:-нет}"
fi
read -r typed
[ "$typed" = "$EXPECTED" ] || fail "Версия не совпала, ничего не выложено."
use_release_token

publish_job() { # индекс: шаги утилиты по порядку; первый сбой прерывает цепочку (set -e)
  local step
  while IFS= read -r step; do
    eval "$step"
  done <<<"${PUB_STEPS[$1]}"
  echo "ok   выложено ${IDS[$1]}-v${VERSIONS[$1]}"
}
if [ ${#PUB_QUEUE[@]} -gt 0 ]; then
  SECONDS=0
  run_pool publish_job "$WORK/logs/publish" "${PUB_QUEUE[@]}"
  if [ ${#POOL_BAD[@]} -gt 0 ]; then
    echo "ОСТАНОВЛЕНО на релизах утилит: каталог и центр не тронуты. Архивы и каталог: $WORK" >&2
    for i in ${POOL_OK[@]+"${POOL_OK[@]}"}; do echo "  выложено: ${IDS[$i]}-v${VERSIONS[$i]}" >&2; done
    for i in "${POOL_BAD[@]}"; do echo "  сорвалось: ${IDS[$i]}-v${VERSIONS[$i]}, лог $WORK/logs/publish/${IDS[$i]}.log" >&2; done
    for i in ${POOL_LEFT[@]+"${POOL_LEFT[@]}"}; do echo "  не начато: ${IDS[$i]}-v${VERSIONS[$i]}" >&2; done
    echo "Продолжить: запусти ту же команду, выложенное она не повторит и возьмёт его архивы для каталога:" >&2
    echo "  $SAME_COMMAND" >&2
    exit 1
  fi
  echo "релизы утилит: ${#POOL_OK[@]} за $SECONDS с"
fi

# Дальше шаги идут на переднем плане, и Ctrl-C снимает их сам. «Каталог не тронут» здесь уже было бы неправдой.
trap - INT TERM
done_count=0
for step in ${PLAN[@]+"${PLAN[@]}"}; do
  if ! eval "$step"; then
    echo "ОСТАНОВЛЕНО на шаге: $step" >&2
    echo "Релизы утилит выложены. Выполнено шагов после них: $done_count из ${#PLAN[@]}. Архивы и каталог: $WORK" >&2
    n=0
    while [ "$n" -lt "$done_count" ]; do echo "  выложено: ${PLAN[$n]}" >&2; n=$((n + 1)); done
    echo "Продолжить вручную, по порядку, начиная с упавшего шага:" >&2
    while [ "$n" -lt ${#PLAN[@]} ]; do echo "  ${PLAN[$n]}" >&2; n=$((n + 1)); done
    echo "Или, когда дерево чистое и HEAD совпадает с origin/main, запусти ту же команду: $SAME_COMMAND" >&2
    exit 1
  fi
  done_count=$((done_count + 1))
done
if [ -n "$UTILITIES_ONLY" ]; then
  echo "Выложено: ${RELEASED[*]}"
else
  echo "Выложено: https://github.com/$REPO/releases/tag/$HUB_TAG"
fi
