#!/bin/bash
# Шаги workflow Check models после проверки: ветка с правкой суммы и задача в Issues.
#   scripts/model-watch-publish.sh branch   создаёт и пушит ветку model-update/<папка>-<12 знаков суммы> с одним коммитом
#   scripts/model-watch-publish.sh issue    заводит задачу: ветка готова, проверка не прошла или модель пропала
# Запрос на слияние не создаётся (в репозитории это запрещено настройкой), в задаче ссылка compare на один клик.
# В main не пушит, ничего не сливает, релизов не делает. Пушит только refs/heads/model-update/* и без --force.
# Идемпотентно: ветка с таким именем уже есть — коммита нет; задача с таким заголовком есть (открытая или закрытая) —
# ничего не пишется. Закрытая задача с той же суммой ветку тоже не возрождает.
#
# Окружение (пути и значения ставит workflow, события и отчёт недоверенные, всё проверяется по шаблону):
#   MW_EVENTS    файл событий из check-model-updates.sh (MODEL_WATCH_EVENTS)
#   MW_REPORT    текст отчёта проверки (только для issue)
#   MW_BRANCHES  branch: сюда пишутся строки «папка<TAB>сумма<TAB>ветка<TAB>created|exists|closed»; issue: оттуда читаются
#   MW_RUN_URL   ссылка на запуск (необязательно); MW_DEFAULT_BRANCH — основная ветка (по умолчанию main)
#   GITHUB_REPOSITORY (владелец/репо), GH_TOKEN для gh; git должен уметь пушить в origin (checkout с токеном).
# Коды: 0 — ок; 1 — событие или шаг не сошлись (запуск краснеет); 2 — сбой сети или API.
set -u
cd "$(dirname "$0")/.."

MODE="${1:-}"
EVENTS="${MW_EVENTS:-}"
REPORT="${MW_REPORT:-}"
BRANCHES="${MW_BRANCHES:-}"
REPO="${GITHUB_REPOSITORY:-}"
DEFAULT_BRANCH="${MW_DEFAULT_BRANCH:-main}"
RUN_URL="${MW_RUN_URL:-}"
SWIFT_PATH="Sources/Modules/Voice/VoiceModels.swift"
CHECK="./scripts/check-model-updates.sh"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

die() { echo "$1" >&2; exit "${2:-1}"; }
[ "$MODE" = branch ] || [ "$MODE" = issue ] || die "Использование: model-watch-publish.sh branch|issue" 1
[ -f "$EVENTS" ] || die "MW_EVENTS: нет файла событий" 1
[ -n "$BRANCHES" ] || die "MW_BRANCHES не задан" 1
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "GITHUB_REPOSITORY не похож на владелец/репозиторий" 1
[[ "$DEFAULT_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "основная ветка с недопустимыми знаками" 1
[[ "$RUN_URL" =~ ^https://[A-Za-z0-9./_-]+$ ]] || RUN_URL=""

T="$(mktemp -d "${TMPDIR:-/tmp}/model-watch-publish.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
TAB="$(printf '\t')"
ISSUES="$T/issues.json"

# --- Проверка полей события по шаблону ---------------------------------------------------------------------------
RE_FOLDER='^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid_folder() { [[ "$1" =~ $RE_FOLDER ]] && [[ "$1" != *..* ]] && [[ "$1" != *.lock ]] && [[ "$1" != *. ]]; }
valid_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }
clean_who() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] && printf '%s' "$1" || printf '?'; }
clean_when() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$ ]] && printf '%s' "$1" || printf '?'; }

title_ok() { printf 'Модель изменилась у авторов: %s (sha256:%s)' "$1" "$2"; }
title_fail() { printf 'Похоже на подмену модели у авторов, не принимать: %s (sha256:%s)' "$1" "$2"; }
title_missing() { printf 'Модель пропала у авторов: %s' "$1"; }

load_issues() {
  [ -f "$ISSUES" ] && return 0
  gh issue list --state all --limit 1000 --json number,title,state > "$ISSUES" 2>/dev/null </dev/null \
    || die "Не удалось получить список задач (gh issue list): сбой API" 2
  jq -e 'type == "array"' "$ISSUES" >/dev/null 2>&1 || die "gh issue list вернул не список" 2
}
issue_exists() { jq -e --arg t "$1" 'any(.[]; .title == $t)' "$ISSUES" >/dev/null 2>&1; }
issue_open() { jq -e --arg t "$1" 'any(.[]; .title == $t and .state == "OPEN")' "$ISSUES" >/dev/null 2>&1; }

# --- branch ------------------------------------------------------------------------------------------------------
cmd_branch() {
  : > "$BRANCHES"
  local rc=0 base kind folder digest size uploader updated verdict hex branch title old_line old_sha old_size msg_sha status out lr
  base="$(git rev-parse HEAD 2>/dev/null)" || die "git: нет текущего коммита" 2
  while IFS="$TAB" read -r -u 3 kind folder digest size uploader updated verdict; do
    [ "$kind" = changed ] && [ "$verdict" = ok ] || continue
    if ! valid_folder "$folder" || ! valid_digest "$digest" || ! [[ "$size" =~ ^[1-9][0-9]{0,14}$ ]]; then
      echo "Событие отвергнуто: папка, сумма или размер не по шаблону. Ветка не создаётся." >&2; rc=1; continue
    fi
    hex="${digest#sha256:}"
    branch="model-update/$folder-${hex:0:12}"
    if ! git check-ref-format "refs/heads/$branch" 2>/dev/null; then
      echo "Имя ветки недопустимо для git: $branch" >&2; rc=1; continue
    fi
    uploader="$(clean_who "$uploader")"; updated="$(clean_when "$updated")"

    load_issues
    title="$(title_ok "$folder" "${hex:0:12}")"
    if issue_exists "$title" && ! issue_open "$title"; then
      echo "Задача «${title}» закрыта: ветку заново не создаю."
      printf '%s\t%s\t%s\t%s\n' "$folder" "$digest" "$branch" closed >> "$BRANCHES"; continue
    fi

    git ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1 </dev/null
    lr=$?
    if [ "$lr" = 0 ]; then
      echo "Ветка $branch уже есть, нового коммита нет."
      printf '%s\t%s\t%s\t%s\n' "$folder" "$digest" "$branch" exists >> "$BRANCHES"; continue
    elif [ "$lr" != 2 ]; then
      echo "Не удалось спросить origin про ветку $branch (git ls-remote, код $lr): сбой сети." >&2; rc=2; continue
    fi

    old_line="$($CHECK --parse 2>/dev/null | awk -F'\t' -v f="$folder" '$1 == "MODEL" && $3 == f')"
    old_sha="$(printf '%s' "$old_line" | cut -f4)"; old_size="$(printf '%s' "$old_line" | cut -f5)"
    if ! [[ "$old_sha" =~ ^[0-9a-f]{64}$ ]] || ! [[ "$old_size" =~ ^[0-9]+$ ]]; then
      echo "Модели с папкой $folder нет в VoiceModels.swift." >&2; rc=1; continue
    fi

    git switch -q -c "$branch" </dev/null || { echo "Не создать локальную ветку $branch" >&2; rc=1; continue; }
    if ! out="$($CHECK --apply "$folder" "$hex" "$size" 2>&1)"; then
      echo "Правка отвергнута: $out" >&2; rc=1
      git checkout -q -- . ; git switch -q --detach "$base"; git branch -q -D "$branch"; continue
    fi
    echo "$out"
    status="$(git status --porcelain)"
    if [ "$status" != " M $SWIFT_PATH" ]; then
      echo "После правки изменено не только $SWIFT_PATH: $status" >&2; rc=1
      git checkout -q -- . ; git switch -q --detach "$base"; git branch -q -D "$branch"; continue
    fi
    git add -- "$SWIFT_PATH"
    msg_sha="${old_sha:0:12} -> ${hex:0:12}"
    if ! GIT_AUTHOR_NAME="$BOT_NAME" GIT_AUTHOR_EMAIL="$BOT_EMAIL" GIT_COMMITTER_NAME="$BOT_NAME" GIT_COMMITTER_EMAIL="$BOT_EMAIL" \
      git commit -q -m "Голос: новая сумма модели $folder" \
        -m "Авторы переиздали архив в релизе asr-models. Сумма: $msg_sha, размер: $old_size -> $size байт. Залил: $uploader, обновлено: $updated." \
        -m "Проверки в workflow Check models прошли: digest и размер архива, состав и пути, файлы .onnx совпали с Hugging Face. Сумма не принимается автоматически: слияние и выпуск за человеком." </dev/null; then
      echo "git commit не удался" >&2; rc=1; git switch -q --detach "$base"; git branch -q -D "$branch"; continue
    fi
    if ! git push -q origin "refs/heads/$branch:refs/heads/$branch" </dev/null; then
      echo "git push ветки $branch не удался" >&2; rc=2; git switch -q --detach "$base"; git branch -q -D "$branch"; continue
    fi
    echo "Ветка $branch запушена (один коммит от $BOT_NAME)."
    printf '%s\t%s\t%s\t%s\n' "$folder" "$digest" "$branch" created >> "$BRANCHES"
    git switch -q --detach "$base"
    git branch -q -D "$branch"
  done 3< "$EVENTS"
  return "$rc"
}

# --- issue -------------------------------------------------------------------------------------------------------
# Кусок отчёта про одну папку: от заголовка «ИЗМЕНИЛОСЬ/ПРОПАЛ … (папка)» до следующей строки без отступа.
report_section() {
  local part
  part="$(awk -v f="($1)" '/^[^ ]/ { p = 0 } /^(ИЗМЕНИЛОСЬ|ПРОПАЛ)/ && index($0, f) { p = 1 } p' "$REPORT" 2>/dev/null)"
  [ -n "$part" ] || part="$(cat "$REPORT" 2>/dev/null)"
  # Недоверенный текст: без обратных кавычек (не выйти из блока), без @ (не упоминать людей), без управляющих знаков.
  printf '%s\n' "$part" | tr -d '`\000-\010\013\014\016-\037' | sed 's/@/(at)/g' | head -c 40000
}

emit_report_block() {
  echo
  echo "## Отчёт проверки"
  echo '```'
  report_section "$1"
  echo '```'
  [ -z "$RUN_URL" ] || { echo; echo "Запуск: $RUN_URL"; }
}

body_ok() { # папка сумма размер залил когда ветка состояние
  local folder="$1" digest="$2" size="$3" who="$4" when="$5" branch="$6" state="$7" old_line old_sha old_size
  old_line="$($CHECK --parse 2>/dev/null | awk -F'\t' -v f="$folder" '$1 == "MODEL" && $3 == f')"
  old_sha="$(printf '%s' "$old_line" | cut -f4)"; old_size="$(printf '%s' "$old_line" | cut -f5)"
  echo "Авторы модели переиздали архив \`$folder\` в релизе asr-models (k2-fsa/sherpa-onnx). Все проверки прошли, ветка с правкой запушена."
  echo "Запрос на слияние автоматически не создаётся (в репозитории так настроено): его создаёте вы одной ссылкой."
  echo
  echo "## Что изменилось"
  echo "- Модель: \`$folder\`"
  echo "- Сумма: \`sha256:${old_sha:-?}\` -> \`$digest\`"
  echo "- Размер: ${old_size:-?} -> $size байт"
  echo "- Залил: $who, обновлено: $when (UTC)"
  echo
  echo "## Итог проверок: все прошли"
  echo "- sha256 скачанного архива совпал с digest GitHub, размер совпал."
  echo "- Состав архива безопасен: нужные файлы на месте, путей и ссылок наружу нет."
  echo "- Файлы .onnx совпали с копией на Hugging Face."
  echo
  echo "## Как принять"
  echo "1. Создайте запрос на слияние одним нажатием: https://github.com/$REPO/compare/$DEFAULT_BRANCH...$branch?expand=1"
  echo "2. В diff должны быть ровно две строки (сумма и размер) в \`$SWIFT_PATH\`."
  echo "3. Слейте запрос, обновите локальный main и выпустите:"
  echo
  echo "    scripts/fix.sh voice --note \"Голос: обновлена сумма модели $folder, авторы переиздали архив\""
  echo
  echo "Ветка: \`$branch\` ($( [ "$state" = created ] && echo 'создана в этом запуске' || echo 'уже была' ))."
  echo "Не принимаете: закройте задачу, заново для этой суммы она не заводится."
  emit_report_block "$folder"
}

body_fail() { # папка сумма размер залил когда
  echo "**ПОХОЖЕ НА ПОДМЕНУ ИЛИ СБОЙ, НЕ ПРИНИМАТЬ.** Авторы изменили архив \`$1\` в релизе asr-models, но проверка не прошла."
  echo "Ветка с правкой не создавалась, в \`$SWIFT_PATH\` ничего не менялось, у пользователей остаётся прежняя сумма."
  echo
  echo "## Что изменилось"
  echo "- Модель: \`$1\`"
  echo "- Новая сумма по данным GitHub: \`$2\`, размер $3 байт"
  echo "- Залил: $4, обновлено: $5 (UTC)"
  echo
  echo "## Что делать"
  echo "Ничего не принимать. Что именно не сошлось (digest, размер, состав архива или Hugging Face), видно в отчёте ниже: строки с «НЕ СОВПАЛ», «ПРОБЛЕМЫ», «сверить не с чем»."
  echo "Если авторы переиздали архив законно, сверьте файл вручную и закройте эту задачу."
  emit_report_block "$1"
}

body_missing() {
  echo "Файл модели \`$1\` пропал из релиза asr-models (k2-fsa/sherpa-onnx): авторы удалили или переименовали архив, либо исчез сам релиз."
  echo "У пользователей скачивание этой модели сейчас не работает. Автоматически чинить нечего: нужен другой источник или другое имя файла."
  emit_report_block "$1"
}

create_issue() { # заголовок файл-тела
  if gh issue create --title "$1" --body-file "$2" </dev/null; then return 0; fi
  echo "Не удалось завести задачу «$1»" >&2; return 1
}

cmd_issue() {
  local rc=0 kind folder digest size uploader updated verdict hex title state branch
  [ -f "$REPORT" ] || die "MW_REPORT: нет файла отчёта" 1
  [ -f "$BRANCHES" ] || : > "$BRANCHES"
  while IFS="$TAB" read -r -u 3 kind folder digest size uploader updated verdict; do
    case "$kind" in changed|missing) ;; *) continue ;; esac
    if ! valid_folder "$folder"; then echo "Событие отвергнуто: папка не по шаблону." >&2; rc=1; continue; fi
    load_issues
    if [ "$kind" = missing ]; then
      title="$(title_missing "$folder")"
      if issue_exists "$title"; then echo "Задача «${title}» уже есть, ничего не пишу."; continue; fi
      body_missing "$folder" > "$T/body.md"
      create_issue "$title" "$T/body.md" || rc=1
      continue
    fi
    if ! valid_digest "$digest" || ! [[ "$size" =~ ^[1-9][0-9]{0,14}$ ]]; then
      echo "Событие отвергнуто: сумма или размер не по шаблону." >&2; rc=1; continue
    fi
    hex="${digest#sha256:}"; hex="${hex:0:12}"
    uploader="$(clean_who "$uploader")"; updated="$(clean_when "$updated")"
    if [ "$verdict" = ok ]; then
      title="$(title_ok "$folder" "$hex")"
      if issue_exists "$title"; then echo "Задача «${title}» уже есть (открытая или закрытая), ничего не пишу."; continue; fi
      state="$(awk -F'\t' -v f="$folder" -v d="$digest" '$1 == f && $2 == d { print $4; exit }' "$BRANCHES")"
      branch="$(awk -F'\t' -v f="$folder" -v d="$digest" '$1 == f && $2 == d { print $3; exit }' "$BRANCHES")"
      case "$state" in
        created|exists) ;;
        *) echo "Ветки для $folder ($hex) нет (шаг ветки не отработал): задачу не завожу, повтор при следующем запуске." >&2; rc=1; continue ;;
      esac
      body_ok "$folder" "$digest" "$size" "$uploader" "$updated" "$branch" "$state" > "$T/body.md"
    else
      title="$(title_fail "$folder" "$hex")"
      if issue_exists "$title"; then echo "Задача «${title}» уже есть (открытая или закрытая), ничего не пишу."; continue; fi
      body_fail "$folder" "$digest" "$size" "$uploader" "$updated" > "$T/body.md"
    fi
    create_issue "$title" "$T/body.md" || rc=1
  done 3< "$EVENTS"
  return "$rc"
}

if [ "$MODE" = branch ]; then cmd_branch; else cmd_issue; fi
exit $?
