#!/bin/bash
# Проверка scripts/check-model-updates.sh без сети: вместо настоящего curl подставной, ответы из файлов-фикстур.
# Сценарии: совпало, изменилась сумма, изменился размер, файл пропал, релиз пропал, сбой сети и API (код 2, не «изменилось»),
# страницы списка файлов, разбор настоящего VoiceTypes.swift, --verify (состав архива, опасные пути, сверка с Hugging Face).
# --apply: меняет только сумму и размер нужной модели, повтор ничего не меняет, всё кривое отвергается.
# scripts/model-watch-publish.sh (ветка и задача) прогоняется с настоящим git на временном «origin» и подставным gh:
# новая, повтор, закрытая, проверка не прошла, новая сумма поверх старой, пропажа, кривые события, сбои.
# Потом поломки обоих скриптов. Каждая поломка обязана покраснеть, иначе проверка ничего не стоит.
# Настоящая сеть, настоящие модели и настроек не затрагиваются: всё во временной папке.
# Tests/lib/check-limit.sh в этой ветке нет, поэтому лимит времени здесь не подключён.
source "$(dirname "$0")/lib/check-limit.sh"
set -u
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/check-model-updates.sh"
REAL_SWIFT="$PWD/Sources/Modules/Voice/UI/VoiceTypes.swift"
W="$(mktemp -d "${TMPDIR:-/tmp}/model-watch-check.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT

FAILS=0
QUIET=0
say() { [ "$QUIET" = 1 ] || echo "$1"; }
pass() { say "ok   $1"; }
fail() { say "ПРОВАЛ: $1"; FAILS=$((FAILS + 1)); }

# --- Подставной curl --------------------------------------------------------------------------------------------
BIN="$W/bin"; ROUTES="$W/routes"; mkdir -p "$BIN" "$ROUTES"
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
# Ключ ответа — адрес без схемы, всё кроме букв и цифр заменено на «_». Нет файла — сбой сети (код 6).
out=""; url=""; want_code=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) want_code=1; shift ;;
    -K|-H|--max-time|--retry|--retry-delay) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$url" >> "$FAKE_ROUTES/calls.log"
[ -n "${FAKE_NET_DOWN:-}" ] && exit 6
key="$(echo "${url#*://}" | tr -c 'A-Za-z0-9\n' '_')"
[ -f "$FAKE_ROUTES/$key.body" ] || exit 6
cp "$FAKE_ROUTES/$key.body" "$out"
[ "$want_code" = 1 ] && { cat "$FAKE_ROUTES/$key.status" 2>/dev/null || printf 200; }
exit 0
EOF
chmod +x "$BIN/curl"
export FAKE_ROUTES="$ROUTES"

route() { # адрес код файл-тела|-строка
  local key; key="$(echo "${1#*://}" | tr -c 'A-Za-z0-9\n' '_')"
  printf '%s' "$2" > "$ROUTES/$key.status"
  if [ -f "$3" ]; then cp "$3" "$ROUTES/$key.body"; else printf '%s' "$3" > "$ROUTES/$key.body"; fi
}
reset_routes() { rm -f "$ROUTES"/*; }

GH="https://gh.test"; HF="https://hf.test"
REL="$GH/repos/own/repo/releases/tags/tag1"
PAGE() { echo "$GH/repos/own/repo/releases/77/assets?per_page=100&page=$1"; }
DL() { echo "https://github.com/own/repo/releases/download/tag1/$1.tar.bz2"; }
SHA_A=$(printf 'a%.0s' $(seq 64)); SHA_B=$(printf 'b%.0s' $(seq 64)); SHA_N=$(printf 'c%.0s' $(seq 64))

# Мини-копия VoiceTypes.swift той же формы: две модели, как в настоящем файле.
SWIFT="$W/VoiceTypes.swift"
cat > "$SWIFT" <<EOF
enum VoiceModel: String, CaseIterable, Identifiable {
    case alpha
    case beta

    var id: String { rawValue }

    var url: URL {
        URL(string: "https://github.com/own/repo/releases/download/tag1/\(folderName).tar.bz2")!
    }

    var sha256: String {
        switch self {
        case .alpha: return "$SHA_A"
        case .beta: return "$SHA_B"
        }
    }

    var sizeBytes: Int64 {
        switch self {
        case .alpha: return 1_000
        case .beta: return 2_000
        }
    }

    var folderName: String {
        switch self {
        case .alpha: return "folder-alpha"
        case .beta: return "folder-beta"
        }
    }

    var requiredFiles: [String] {
        switch self {
        case .alpha: return ["m.onnx", "tokens.txt"]
        case .beta: return ["m.onnx", "tokens.txt"]
        }
    }
}
EOF

asset() { # имя digest размер
  printf '{"name":"%s.tar.bz2","digest":"%s","size":%s,"updated_at":"2026-11-07T05:51:03Z","uploader":{"login":"authorX"},"browser_download_url":"https://github.com/own/repo/releases/download/tag1/%s.tar.bz2"}' "$1" "$2" "$3" "$1"
}
# База: релиз, одна страница с двумя совпадающими файлами и пустая вторая.
base() {
  reset_routes; : > "$ROUTES/calls.log"
  route "$REL" 200 '{"id":77}'
  route "$(PAGE 1)" 200 "[$(asset folder-alpha "sha256:$SHA_A" 1000),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  route "$(PAGE 2)" 200 '[]'
}

# run ЧТО-ИСПОЛНЯТЬ [аргументы]: вывод в $OUT, код в $RC.
OUT=""; RC=0; EVENTS_FILE="$W/events"
run() {
  local script="$1"; shift
  : > "$EVENTS_FILE"
  OUT="$(env -u GITHUB_TOKEN -u GH_TOKEN PATH="$BIN:$PATH" CHECK_MODELS_SWIFT="${SWIFT_UNDER_TEST:-$SWIFT}" \
    CHECK_MODELS_GH_API="$GH" CHECK_MODELS_HF_API="$HF" MODEL_WATCH_EVENTS="$EVENTS_FILE" /bin/bash "$script" "$@" 2>&1)"
  RC=$?
}
rc_is() { [ "$RC" = "$2" ] && pass "$1: код $2" || { fail "$1: ждал код $2, вышел $RC"; say "$OUT"; }; }
has() { case "$OUT" in *"$2"*) pass "$1" ;; *) fail "$1: в выводе нет «$2»"; say "$OUT" ;; esac; }
hasnt() { case "$OUT" in *"$2"*) fail "$1: в выводе есть «$2»"; say "$OUT" ;; *) pass "$1" ;; esac; }

make_archive() { # файл папка режим
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, sys, tarfile
path, folder, mode = sys.argv[1:4]
def add(t, name, data=b"x"):
    i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
with tarfile.open(path, "w:bz2") as t:
    add(t, folder + "/m.onnx", b"model-bytes")
    if mode != "no-tokens":
        add(t, folder + "/tokens.txt", b"a 1")
    if mode == "symlink":
        i = tarfile.TarInfo(folder + "/evil"); i.type = tarfile.SYMTYPE; i.linkname = "../../etc/passwd"; t.addfile(i)
    if mode == "dotdot":
        add(t, folder + "/../outside.txt")
    if mode == "absolute":
        add(t, "/tmp/abs.txt")
PY
}

suite() { # скрипт под проверкой
  local S="$1"

  base; run "$S"
  rc_is "совпало" 0; has "совпало: alpha ok" "ok  alpha"; has "совпало: beta ok" "ok  beta"
  hasnt "совпало: нет тревоги" "ИЗМЕНИЛОСЬ"
  [ ! -s "$EVENTS_FILE" ] && pass "совпало: событий нет" || fail "совпало: события записаны"

  # Сумма поменялась, размер тот же: ловит только сверка суммы.
  base; route "$(PAGE 1)" 200 "[$(asset folder-alpha "sha256:$SHA_N" 1000),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  run "$S"
  rc_is "сумма изменилась" 1
  has "сумма: заголовок" "ИЗМЕНИЛОСЬ  alpha"; has "сумма: старая" "sha256:$SHA_A"; has "сумма: новая" "sha256:$SHA_N"
  has "сумма: кто залил" "authorX"; has "сумма: когда" "2026-11-07T05:51:03Z"
  has "сумма: ссылка на файл" "$(DL folder-alpha)"; has "сумма: ссылка на релиз" "https://github.com/own/repo/releases/tag/tag1"
  has "сумма: соседняя модель ok" "ok  beta"
  [ "$(cat "$EVENTS_FILE")" = "$(printf 'changed\tfolder-alpha\tsha256:%s\t1000\tauthorX\t2026-11-07T05:51:03Z\tunverified' "$SHA_N")" ] && pass "сумма: событие для workflow" || fail "сумма: событие для workflow"

  # Размер поменялся, сумма та же.
  base; route "$(PAGE 1)" 200 "[$(asset folder-alpha "sha256:$SHA_A" 1001),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  run "$S"; rc_is "размер изменился" 1; has "размер: заголовок" "ИЗМЕНИЛОСЬ  alpha"; has "размер: новый" "1001 байт"

  # Файл пропал.
  base; route "$(PAGE 1)" 200 "[$(asset folder-beta "sha256:$SHA_B" 2000)]"
  run "$S"; rc_is "файл пропал" 1; has "пропал: текст" "ПРОПАЛ  alpha"; hasnt "пропал: не «изменилось»" "ИЗМЕНИЛОСЬ"
  [ "$(cat "$EVENTS_FILE")" = "$(printf 'missing\tfolder-alpha\t-')" ] && pass "пропал: событие для workflow" || fail "пропал: событие для workflow"

  # Релиз пропал (404).
  base; route "$REL" 404 '{"message":"Not Found"}'
  run "$S"; rc_is "релиз пропал" 1; has "релиз пропал: текст" "ПРОПАЛ  alpha"; has "релиз пропал: причина" "не найден"

  # Сбой сети и API: код 2 и ни слова «изменилось».
  base; FAKE_NET_DOWN=1 run "$S"
  [ "$RC" = 2 ] && pass "сеть недоступна: код 2" || fail "сеть недоступна: ждал код 2, вышел $RC"
  hasnt "сеть недоступна: не «изменилось»" "ИЗМЕНИЛОСЬ"; hasnt "сеть недоступна: не «пропал»" "ПРОПАЛ"; has "сеть недоступна: объяснено" "не значит, что файл изменился"
  base; route "$(PAGE 1)" 500 'oops'; run "$S"; rc_is "API 500 на странице" 2; hasnt "API 500: не «изменилось»" "ИЗМЕНИЛОСЬ"
  base; route "$REL" 403 '{"message":"API rate limit exceeded"}'; run "$S"; rc_is "лимит запросов 403" 2; hasnt "403: не «пропал»" "ПРОПАЛ"
  base; route "$(PAGE 2)" 200 'не json'; run "$S"; rc_is "мусор вместо JSON" 2
  base; route "$(PAGE 1)" 200 "[$(asset folder-alpha "" 1000),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  run "$S"; rc_is "digest не прислан" 2; hasnt "digest не прислан: не «изменилось»" "ИЗМЕНИЛОСЬ"

  # Файл на второй странице списка (в релизе больше 100, а в самом релизе список обрезан).
  base; route "$(PAGE 1)" 200 "[$(asset folder-beta "sha256:$SHA_B" 2000)]"; route "$(PAGE 2)" 200 "[$(asset folder-alpha "sha256:$SHA_A" 1000)]"; route "$(PAGE 3)" 200 '[]'
  run "$S"; rc_is "файл на странице 2" 0; has "страница 2: alpha ok" "ok  alpha"

  # Без --verify ничего не качается.
  base; route "$(PAGE 1)" 200 "[$(asset folder-alpha "sha256:$SHA_N" 1000),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  run "$S"
  /usr/bin/grep -q 'releases/download' "$ROUTES/calls.log" && fail "без --verify обращался за архивом" || pass "без --verify архив не запрашивается"
  /usr/bin/grep -q 'hf.test' "$ROUTES/calls.log" && fail "без --verify ходил на Hugging Face" || pass "без --verify Hugging Face не трогается"

  # --verify.
  local good="$W/good.tar.bz2" gsha onnx_sha
  make_archive "$good" folder-alpha ok
  gsha="sha256:$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$good")"
  onnx_sha="$(python3 -I -c 'import hashlib; print(hashlib.sha256(b"model-bytes").hexdigest())')"
  local gsize; gsize="$(wc -c < "$good" | tr -d ' ')"
  verify_base() { base; route "$(PAGE 1)" 200 "[$(asset folder-alpha "$gsha" "$gsize"),$(asset folder-beta "sha256:$SHA_B" 2000)]"; route "$(DL folder-alpha)" 200 "$1"; }
  tree() { printf '[{"type":"file","path":"m.onnx","lfs":{"oid":"%s"}},{"type":"file","path":"tokens.txt"}]' "$1"; }

  verify_base "$good"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 200 "$(tree "$onnx_sha")"
  run "$S" --verify
  rc_is "verify: совпало" 1; has "verify: digest скачанного" "Сверка с digest GitHub: совпала"; has "verify: итог" "совпало с Hugging Face"
  has "verify: размер" "Сверка размера: скачано $gsize байт, по данным GitHub $gsize байт: совпала"
  has "verify: состав годен" "Состав архива: годен"; has "verify: перечень файлов" "folder-alpha/m.onnx"
  [ "$(cat "$EVENTS_FILE")" = "$(printf 'changed\tfolder-alpha\t%s\t%s\tauthorX\t2026-11-07T05:51:03Z\tok' "$gsha" "$gsize")" ] && pass "verify: событие с итогом ok" || fail "verify: событие с итогом ok"
  verify_base "$good"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 404 '{"error":"not found"}'
  run "$S" --verify; has "verify: нет страницы" "другой копии нет"; rc_is "verify: нет страницы" 1
  case "$(cut -f7 "$EVENTS_FILE")" in fail) pass "verify: нет страницы, итог fail" ;; *) fail "verify: нет страницы, итог fail" ;; esac
  verify_base "$good"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 200 "$(tree "$SHA_N")"
  run "$S" --verify; has "verify: отличается" "НЕ СОВПАЛО"; hasnt "verify: не «совпало с Hugging Face»" "совпало с Hugging Face"
  case "$(cut -f7 "$EVENTS_FILE")" in fail) pass "verify: отличается, итог fail" ;; *) fail "verify: отличается, итог fail" ;; esac
  verify_base "$good"; route "$(PAGE 1)" 200 "[$(asset folder-alpha "sha256:$SHA_N" "$gsize"),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 200 "$(tree "$onnx_sha")"
  run "$S" --verify; has "verify: digest скачанного не тот" "НЕ СОВПАЛА"
  case "$(cut -f7 "$EVENTS_FILE")" in fail) pass "verify: чужой digest, итог fail даже при совпавшем Hugging Face" ;; *) fail "verify: чужой digest, итог fail" ;; esac
  verify_base "$good"; route "$(PAGE 1)" 200 "[$(asset folder-alpha "$gsha" $((gsize + 1))),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 200 "$(tree "$onnx_sha")"
  run "$S" --verify; has "verify: размер не тот" "Сверка размера"; has "verify: размер назван" "НЕ СОВПАЛА"
  case "$(cut -f7 "$EVENTS_FILE")" in fail) pass "verify: размер не тот, итог fail" ;; *) fail "verify: размер не тот, итог fail" ;; esac

  # Сбой сети при проверке: ни «изменилось», ни события, код 2.
  verify_base "$good"
  rm -f "$ROUTES/github_com_own_repo_releases_download_tag1_folder_alpha_tar_bz2.body"
  run "$S" --verify; rc_is "verify: архив не скачался" 2; has "verify: архив не скачался, назван сбой" "сбой сети"
  [ ! -s "$EVENTS_FILE" ] && pass "verify: архив не скачался, события нет" || fail "verify: архив не скачался, событие записано"
  verify_base "$good"; rm -f "$ROUTES/hf_test_api_models_csukuangfj_folder_alpha_tree_main.body"
  run "$S" --verify; rc_is "verify: Hugging Face не ответил" 2
  [ ! -s "$EVENTS_FILE" ] && pass "verify: Hugging Face не ответил, события нет" || fail "verify: Hugging Face не ответил, событие записано"
  verify_base "$good"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 503 'x'
  run "$S" --verify; rc_is "verify: Hugging Face 503" 2

  local mode
  for mode in symlink dotdot absolute no-tokens; do
    make_archive "$W/bad-$mode.tar.bz2" folder-alpha "$mode"
    verify_base "$W/bad-$mode.tar.bz2"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 404 'x'
    run "$S" --verify; has "verify: $mode — проблемы" "Состав архива: ПРОБЛЕМЫ"
  done
  make_archive "$W/bad-symlink.tar.bz2" folder-alpha symlink
  verify_base "$W/bad-symlink.tar.bz2"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 404 'x'
  run "$S" --verify; has "verify: символическая ссылка наружу названа" "символическая ссылка наружу"
  make_archive "$W/bad-dotdot.tar.bz2" folder-alpha dotdot
  verify_base "$W/bad-dotdot.tar.bz2"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 404 'x'
  run "$S" --verify; has "verify: путь с .. назван" "небезопасный путь"
  make_archive "$W/bad-no-tokens.tar.bz2" folder-alpha no-tokens
  verify_base "$W/bad-no-tokens.tar.bz2"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 404 'x'
  run "$S" --verify; has "verify: нет нужного файла назван" "нет нужного файла tokens.txt"

  # --apply: только сумма и размер нужной модели.
  local f="$W/apply.swift" keep="$W/apply.keep" want="$W/apply.want" bad
  cp "$SWIFT" "$f"
  SWIFT_UNDER_TEST="$f" run "$S" --apply folder-alpha "$SHA_N" 1234567
  rc_is "apply: alpha" 0
  sed -e "s/$SHA_A/$SHA_N/" -e 's/case \.alpha: return 1_000$/case .alpha: return 1_234_567/' "$SWIFT" > "$want"
  cmp -s "$f" "$want" && pass "apply: изменились ровно две строки alpha, beta и остальное нетронуты" || fail "apply: файл не такой, как ждали"
  [ "$(diff "$SWIFT" "$f" | /usr/bin/grep -c '^[<>]')" = 4 ] && pass "apply: в diff четыре строки (две старых, две новых)" || fail "apply: лишние строки в diff"
  cp "$f" "$keep"
  SWIFT_UNDER_TEST="$f" run "$S" --apply folder-alpha "$SHA_N" 1234567
  rc_is "apply: повтор" 0; has "apply: повтор назван" "уже применено"
  cmp -s "$f" "$keep" && pass "apply: повтор ничего не меняет" || fail "apply: повтор поменял файл"
  cp "$SWIFT" "$f"
  SWIFT_UNDER_TEST="$f" run "$S" --apply folder-beta "$SHA_N" 2000
  sed "s/$SHA_B/$SHA_N/" "$SWIFT" > "$want"
  rc_is "apply: только сумма" 0; cmp -s "$f" "$want" && pass "apply: размер тот же, поменялась одна строка beta" || fail "apply: только сумма — файл не такой"
  cp "$SWIFT" "$f"; cp "$SWIFT" "$keep"
  local rej_name rej_args
  while IFS='|' read -r rej_name bad; do
    [ -n "$rej_name" ] || continue
    # shellcheck disable=SC2086
    SWIFT_UNDER_TEST="$f" run "$S" --apply $bad
    [ "$RC" = 3 ] && pass "apply: отвергнуто — ${rej_name}" || fail "apply: «${rej_name}» не отвергнуто, код $RC"
    cmp -s "$f" "$keep" || { fail "apply: «${rej_name}» всё же изменило файл"; cp "$keep" "$f"; }
  done <<REJ
короткая сумма|folder-alpha ${SHA_N:0:63} 5
длинная сумма|folder-alpha ${SHA_N}c 5
сумма заглавными|folder-alpha $(echo "$SHA_N" | tr a-f A-F) 5
сумма с префиксом|folder-alpha sha256:$SHA_N 5
сумма не hex|folder-alpha ${SHA_N:0:60}zzzz 5
размер не число|folder-alpha $SHA_N abc
размер отрицательный|folder-alpha $SHA_N -5
размер нулевой|folder-alpha $SHA_N 0
размер с экспонентой|folder-alpha $SHA_N 1e3
размер слишком длинный|folder-alpha $SHA_N 1234567890123456
модели нет в списке|folder-gamma $SHA_N 5
префикс чужой папки|folder-alph $SHA_N 5
заглавные в имени|FOLDER-ALPHA $SHA_N 5
путь наружу|../folder-alpha $SHA_N 5
слэш в имени|folder-alpha/x $SHA_N 5
две точки|folder-alpha/.. $SHA_N 5
только две точки|.. $SHA_N 5
одна точка|. $SHA_N 5
REJ
  for bad in "folder alpha" "folder-alpha'" 'folder-alpha"' 'folder-alpha;ls' '$(id)' 'folder-alpha*' ''; do
    SWIFT_UNDER_TEST="$f" run "$S" --apply "$bad" "$SHA_N" 5
    [ "$RC" = 3 ] && pass "apply: имя «${bad}» отвергнуто" || fail "apply: имя «${bad}» не отвергнуто, код $RC"
  done
  cmp -s "$f" "$keep" && pass "apply: после всех отказов файл тот же" || fail "apply: отказы изменили файл"
  SWIFT_UNDER_TEST="$f" run "$S" --apply folder-alpha "$SHA_N"
  rc_is "apply: не хватает аргументов" 3
  SWIFT_UNDER_TEST="$W/нет-такого-файла.swift" run "$S" --apply folder-alpha "$SHA_N" 5
  rc_is "apply: нет файла" 3
  SWIFT_UNDER_TEST="$W/broken.swift" run "$S" --apply folder-alpha "$SHA_N" 5
  rc_is "apply: файл не разбирается" 3
}

# --- Ветка и задача: scripts/model-watch-publish.sh ---------------------------------------------------------------
# Настоящий git на временном «origin» (bare-репозиторий в папке теста), подставные gh и обёртка над git, которая пишет вызовы.
P="$W/pub"; PBIN="$P/bin"; PUB_LOG="$P/log"; mkdir -p "$PBIN"
cat > "$PBIN/git" <<'GITEOF'
#!/bin/bash
echo "$*" >> "$PUB_LOG/git.log"
exec /usr/bin/git "$@"
GITEOF
cat > "$PBIN/gh" <<'GHEOF'
#!/bin/bash
echo "$*" >> "$PUB_LOG/gh.log"
case "$1 $2" in
  "issue list") [ -n "${FAKE_GH_DOWN:-}" ] && exit 1; cat "$PUB_LOG/issues.json" ;;
  "issue create")
    title=""; body=""
    while [ $# -gt 0 ]; do case "$1" in --title) title="$2"; shift ;; --body-file) body="$2"; shift ;; esac; shift; done
    mkdir -p "$PUB_LOG/created"
    n=$(( $(ls "$PUB_LOG/created" | wc -l) / 2 + 1 ))
    printf '%s' "$title" > "$PUB_LOG/created/$n.title"; cp "$body" "$PUB_LOG/created/$n.body"
    jq --arg t "$title" '. + [{number: (length + 1), title: $t, state: "OPEN"}]' "$PUB_LOG/issues.json" > "$PUB_LOG/issues.tmp" && mv "$PUB_LOG/issues.tmp" "$PUB_LOG/issues.json" ;;
  *) exit 1 ;;
esac
GHEOF
chmod +x "$PBIN/git" "$PBIN/gh"
export PUB_LOG

NOW="2026-11-07T05:51:03Z"
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
pub_git() { /usr/bin/git -C "$P/work" "$@"; }
pub_setup() { # скрипт публикации под проверкой
  rm -rf "$P/origin.git" "$P/work" "$PUB_LOG" "$P/events.tsv" "$P/branches.tsv"; mkdir -p "$PUB_LOG"
  echo '[]' > "$PUB_LOG/issues.json"; : > "$PUB_LOG/git.log"; : > "$PUB_LOG/gh.log"
  /usr/bin/git init -q --bare "$P/origin.git"; /usr/bin/git -C "$P/origin.git" symbolic-ref HEAD refs/heads/main
  /usr/bin/git init -q "$P/work"; pub_git symbolic-ref HEAD refs/heads/main
  mkdir -p "$P/work/scripts" "$P/work/Sources/Modules/Voice/UI"
  cp "$SCRIPT" "$P/work/scripts/check-model-updates.sh"; cp "$1" "$P/work/scripts/model-watch-publish.sh"
  cp "$SWIFT" "$P/work/Sources/Modules/Voice/UI/VoiceTypes.swift"; chmod +x "$P/work/scripts/"*.sh
  pub_git add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t pub_git commit -q -m start
  pub_git remote add origin "$P/origin.git"; pub_git push -q origin main
  printf 'ok  beta: всё хорошо\nИЗМЕНИЛОСЬ  alpha (folder-alpha)\n  Было: sha256:%s, 1000 байт\n  Стало: sha256:%s, 1234567 байт\n  Сверка с digest GitHub: совпала\n  Сверка с Hugging Face: ИТОГ: совпало\n  - плохое имя: ``` @someone\nПРОПАЛ  zzz (folder-zzz)\n  чужое\n' "$SHA_A" "$SHA_N" > "$P/report.txt"
}
ev() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
pub_run() { # режим: вывод в $OUT, код в $RC
  OUT="$(cd "$P/work" && env PATH="$PBIN:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GITHUB_REPOSITORY=IvanSSpace/utilitumus \
    MW_DEFAULT_BRANCH=main MW_EVENTS="$P/events.tsv" MW_REPORT="$P/report.txt" MW_BRANCHES="$P/branches.tsv" MW_RUN_URL=https://github.com/IvanSSpace/utilitumus/actions/runs/1 \
    /bin/bash scripts/model-watch-publish.sh "$1" 2>&1)"
  RC=$?
}
created_n() { ls "$PUB_LOG/created" 2>/dev/null | wc -l | tr -d ' ' | awk '{ print $1 / 2 }'; }
push_n() { /usr/bin/grep -c '^push' "$PUB_LOG/git.log"; }
origin_rev() { /usr/bin/git -C "$P/origin.git" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1: ждал «$3», вышло «$2»"; }

psuite() { # скрипт публикации под проверкой
  local PS="$1" BR_A="model-update/folder-alpha-cccccccccccc" BR_D="model-update/folder-alpha-dddddddddddd" SHA_D main_rev br_rev t1 body want
  SHA_D=$(printf 'd%.0s' $(seq 64))
  want="$W/pub.want"; sed -e "s/$SHA_A/$SHA_N/" -e 's/case \.alpha: return 1_000$/case .alpha: return 1_234_567/' "$SWIFT" > "$want"

  # Новая: проверка прошла.
  pub_setup "$PS"; main_rev="$(origin_rev main)"
  ev changed folder-alpha "sha256:$SHA_N" 1234567 authorX "$NOW" ok > "$P/events.tsv"
  pub_run branch; rc_is "новая: ветка" 0
  [ -n "$(origin_rev "$BR_A")" ] && pass "новая: ветка $BR_A есть в origin" || fail "новая: ветки нет в origin"
  eq "новая: main в origin не сдвинулся" "$(origin_rev main)" "$main_rev"
  eq "новая: один коммит поверх main" "$(/usr/bin/git -C "$P/origin.git" rev-list --count "main..$BR_A")" 1
  eq "новая: автор коммита" "$(/usr/bin/git -C "$P/origin.git" log -1 --format='%an <%ae>' "$BR_A")" "github-actions[bot] <$BOT_EMAIL>"
  eq "новая: коммитер" "$(/usr/bin/git -C "$P/origin.git" log -1 --format='%cn <%ce>' "$BR_A")" "github-actions[bot] <$BOT_EMAIL>"
  /usr/bin/git -C "$P/origin.git" show "$BR_A:Sources/Modules/Voice/UI/VoiceTypes.swift" > "$W/pub.got"
  cmp -s "$W/pub.got" "$want" && pass "новая: в ветке изменены только сумма и размер alpha" || fail "новая: содержимое ветки не то"
  eq "новая: изменён один файл" "$(/usr/bin/git -C "$P/origin.git" diff --name-only "main..$BR_A")" "Sources/Modules/Voice/UI/VoiceTypes.swift"
  eq "новая: один push" "$(push_n)" 1
  /usr/bin/grep '^push' "$PUB_LOG/git.log" | /usr/bin/grep -Eq -- ' (-f|--force|--force-with-lease|--delete|--mirror|--all)( |$)' && fail "новая: push с опасным флагом" || pass "новая: push без --force"
  /usr/bin/grep '^push' "$PUB_LOG/git.log" | /usr/bin/grep -q "origin refs/heads/$BR_A:refs/heads/$BR_A\$" && pass "новая: push только своей ветки" || fail "новая: push не той ветки: $(/usr/bin/grep '^push' "$PUB_LOG/git.log")"
  eq "новая: результат" "$(cat "$P/branches.tsv")" "$(printf 'folder-alpha\tsha256:%s\t%s\tcreated' "$SHA_N" "$BR_A")"
  pub_run issue; rc_is "новая: задача" 0
  eq "новая: заведена одна задача" "$(created_n)" 1
  t1="$(cat "$PUB_LOG/created/1.title" 2>/dev/null)"; body="$(cat "$PUB_LOG/created/1.body" 2>/dev/null)"
  eq "новая: заголовок" "$t1" "Модель изменилась у авторов: folder-alpha (sha256:cccccccccccc)"
  case "$body" in *"https://github.com/IvanSSpace/utilitumus/compare/main...$BR_A?expand=1"*) pass "новая: ссылка compare" ;; *) fail "новая: нет ссылки compare" ;; esac
  case "$body" in *'scripts/fix.sh voice --note "'*) pass "новая: команда выпуска" ;; *) fail "новая: нет команды выпуска" ;; esac
  case "$body" in *authorX*"$NOW"*) pass "новая: кто и когда залил" ;; *) fail "новая: нет кто и когда" ;; esac
  case "$body" in *"sha256:$SHA_A"*"sha256:$SHA_N"*) pass "новая: что изменилось (было и стало)" ;; *) fail "новая: нет было и стало" ;; esac
  case "$body" in *"Все проверки прошли"*"совпал с digest GitHub"*"Состав архива безопасен"*".onnx совпали"*) pass "новая: итог каждой проверки" ;; *) fail "новая: нет итога проверок" ;; esac
  case "$body" in *"ПРОПАЛ  zzz"*|*чужое*) fail "новая: в задачу попал чужой кусок отчёта" ;; *) pass "новая: в отчёте только своя модель" ;; esac
  case "$body" in *@someone*) fail "новая: упоминание из отчёта прошло" ;; *) pass "новая: @ из отчёта обезврежен" ;; esac
  eq "новая: тройных кавычек ровно две (блок отчёта)" "$(printf '%s\n' "$body" | /usr/bin/grep -c '^```')" 2
  /usr/bin/grep -q 'pr ' "$PUB_LOG/gh.log" && fail "новая: вызывался gh pr" || pass "новая: запрос на слияние не создавался"

  # Повтор: ни ветки, ни коммита, ни задачи.
  br_rev="$(origin_rev "$BR_A")"
  pub_run branch; rc_is "повтор: ветка" 0
  eq "повтор: ветка не сдвинулась" "$(origin_rev "$BR_A")" "$br_rev"
  eq "повтор: нового push нет" "$(push_n)" 1
  eq "повтор: результат exists" "$(cut -f4 "$P/branches.tsv")" exists
  pub_run issue; rc_is "повтор: задача" 0
  eq "повтор: новых задач нет" "$(created_n)" 1
  eq "повтор: комментариев нет" "$(/usr/bin/grep -c 'comment' "$PUB_LOG/gh.log")" 0

  # Новая сумма, пока старая ветка не влита: новая ветка от main и новая задача.
  ev changed folder-alpha "sha256:$SHA_D" 1234999 authorX "$NOW" ok > "$P/events.tsv"
  pub_run branch; rc_is "поверх старой: ветка" 0
  [ -n "$(origin_rev "$BR_D")" ] && pass "поверх старой: новая ветка есть" || fail "поверх старой: новой ветки нет"
  eq "поверх старой: старая ветка на месте" "$(origin_rev "$BR_A")" "$br_rev"
  eq "поверх старой: один коммит поверх main" "$(/usr/bin/git -C "$P/origin.git" rev-list --count "main..$BR_D")" 1
  eq "поверх старой: изменены две строки" "$(/usr/bin/git -C "$P/origin.git" diff --numstat "main..$BR_D" | cut -f1,2)" "$(printf '2\t2')"
  pub_run issue; rc_is "поверх старой: задача" 0
  eq "поверх старой: заведена вторая задача" "$(created_n)" 2
  eq "поверх старой: заголовок" "$(cat "$PUB_LOG/created/2.title")" "Модель изменилась у авторов: folder-alpha (sha256:dddddddddddd)"

  # Закрытая задача с той же суммой: ни ветки, ни задачи.
  pub_setup "$PS"
  ev changed folder-alpha "sha256:$SHA_N" 1234567 authorX "$NOW" ok > "$P/events.tsv"
  echo '[{"number":5,"title":"Модель изменилась у авторов: folder-alpha (sha256:cccccccccccc)","state":"CLOSED"}]' > "$PUB_LOG/issues.json"
  pub_run branch; rc_is "закрытая: ветка" 0
  [ -z "$(origin_rev "$BR_A")" ] && pass "закрытая: ветку не возрождаю" || fail "закрытая: ветка создана"
  eq "закрытая: push нет" "$(push_n)" 0
  pub_run issue; rc_is "закрытая: задача" 0
  eq "закрытая: новой задачи нет" "$(created_n)" 0

  # Проверка не прошла: ветки нет, задача-предупреждение.
  pub_setup "$PS"; main_rev="$(origin_rev main)"
  ev changed folder-alpha "sha256:$SHA_N" 1234567 authorX "$NOW" fail > "$P/events.tsv"
  pub_run branch; rc_is "не прошла: ветка" 0
  eq "не прошла: веток в origin только main" "$(/usr/bin/git -C "$P/origin.git" for-each-ref --format='%(refname)' refs/heads)" "refs/heads/main"
  eq "не прошла: push нет" "$(push_n)" 0
  pub_run issue; rc_is "не прошла: задача" 0
  eq "не прошла: одна задача" "$(created_n)" 1
  eq "не прошла: заголовок" "$(cat "$PUB_LOG/created/1.title")" "Похоже на подмену модели у авторов, не принимать: folder-alpha (sha256:cccccccccccc)"
  body="$(cat "$PUB_LOG/created/1.body")"
  case "$body" in *"НЕ ПРИНИМАТЬ"*) pass "не прошла: предупреждение" ;; *) fail "не прошла: нет предупреждения" ;; esac
  case "$body" in *"/compare/"*|*"fix.sh"*) fail "не прошла: в задаче есть ссылка на слияние или команда выпуска" ;; *) pass "не прошла: ни ссылки на слияние, ни команды выпуска" ;; esac
  case "$body" in *"Сверка с Hugging Face: ИТОГ"*) pass "не прошла: детали отчёта приложены" ;; *) fail "не прошла: нет деталей" ;; esac
  pub_run issue; eq "не прошла: повтор без дубля" "$(created_n)" 1

  # Файл пропал.
  pub_setup "$PS"
  printf 'missing\tfolder-alpha\t-\n' > "$P/events.tsv"
  printf 'ПРОПАЛ  alpha (folder-alpha)\n  В релизе нет файла\n' > "$P/report.txt"
  pub_run branch; rc_is "пропал: ветка" 0; eq "пропал: push нет" "$(push_n)" 0
  pub_run issue; rc_is "пропал: задача" 0
  eq "пропал: заголовок" "$(cat "$PUB_LOG/created/1.title")" "Модель пропала у авторов: folder-alpha"
  pub_run issue; eq "пропал: повтор без дубля" "$(created_n)" 1

  # Кривые события: ни ветки, ни задачи.
  local evil
  for evil in '../x' 'folder-alpha/..' 'a b' "a'b" 'a"b' 'a;b' '$(id)' 'a..b' '-rf' 'folder-zzz'; do
    pub_setup "$PS"
    ev changed "$evil" "sha256:$SHA_N" 1234567 authorX "$NOW" ok > "$P/events.tsv"
    pub_run branch
    [ "$RC" != 0 ] && [ "$(push_n)" = 0 ] && [ -z "$(/usr/bin/git -C "$P/origin.git" for-each-ref refs/heads/model-update)" ] \
      && pass "кривая папка «${evil}»: отвергнута, ничего не пушилось" || fail "кривая папка «${evil}»: код $RC, push $(push_n)"
    pub_run issue; [ "$(created_n)" = 0 ] && pass "кривая папка «${evil}»: задачи нет" || fail "кривая папка «${evil}»: задача заведена"
  done
  for evil in "sha256:${SHA_N:0:63}" "sha256:$(echo "$SHA_N" | tr a-f A-F)" "$SHA_N" "sha256:${SHA_N}c" 'sha256:zz'; do
    pub_setup "$PS"
    ev changed folder-alpha "$evil" 1234567 authorX "$NOW" ok > "$P/events.tsv"
    pub_run branch
    [ "$RC" != 0 ] && [ "$(push_n)" = 0 ] && pass "кривая сумма «${evil:0:20}»: отвергнута" || fail "кривая сумма «${evil:0:20}»: код $RC"
  done
  pub_setup "$PS"; ev changed folder-alpha "sha256:$SHA_N" 12x authorX "$NOW" ok > "$P/events.tsv"
  pub_run branch; [ "$RC" != 0 ] && [ "$(push_n)" = 0 ] && pass "кривой размер: отвергнут" || fail "кривой размер: код $RC"
  # Кривой «залил» не ломает коммит и задачу, а заменяется на «?».
  pub_setup "$PS"; ev changed folder-alpha "sha256:$SHA_N" 1234567 'evil @x `y' "$NOW" ok > "$P/events.tsv"
  pub_run branch; rc_is "кривой автор: ветка" 0
  eq "кривой автор: в коммите «?»" "$(/usr/bin/git -C "$P/origin.git" log -1 --format=%B "$BR_A" | /usr/bin/grep -c 'Залил: ?, ')" 1

  # Задача для ok без ветки (шаг ветки упал): не заводим, код 1.
  pub_setup "$PS"; ev changed folder-alpha "sha256:$SHA_N" 1234567 authorX "$NOW" ok > "$P/events.tsv"; : > "$P/branches.tsv"
  pub_run issue; rc_is "без ветки: задача не заводится" 1; eq "без ветки: задач нет" "$(created_n)" 0

  # Сбои API и сети: код 2, ничего не создано.
  pub_setup "$PS"; ev changed folder-alpha "sha256:$SHA_N" 1234567 authorX "$NOW" ok > "$P/events.tsv"
  FAKE_GH_DOWN=1 pub_run branch; rc_is "gh недоступен" 2; eq "gh недоступен: push нет" "$(push_n)" 0
  pub_setup "$PS"; ev changed folder-alpha "sha256:$SHA_N" 1234567 authorX "$NOW" ok > "$P/events.tsv"
  pub_git remote set-url origin "$P/нет-такого.git"
  pub_run branch; rc_is "origin недоступен" 2; eq "origin недоступен: push нет" "$(push_n)" 0
}

# --- Разбор VoiceTypes.swift -----------------------------------------------------------------------------------
echo "== разбор настоящего VoiceTypes.swift"
SWIFT_UNDER_TEST="$REAL_SWIFT"
OUT="$(CHECK_MODELS_SWIFT="$REAL_SWIFT" /bin/bash "$SCRIPT" --parse 2>&1)"; RC=$?
rc_is "разбор настоящего файла" 0
for m in gigaam parakeet; do
  # Независимая выборка из исходника: значение в строке «case .<m>: return …» нужного свойства.
  want_sha="$(awk -v m="$m" '/var sha256/ {p=1} p && $0 ~ "case \\."m":" {gsub(/.*return "|".*/,""); print; exit}' "$REAL_SWIFT")"
  want_folder="$(awk -v m="$m" '/var folderName/ {p=1} p && $0 ~ "case \\."m":" {gsub(/.*return "|".*/,""); print; exit}' "$REAL_SWIFT")"
  want_size="$(awk -v m="$m" '/var sizeBytes/ {p=1} p && $0 ~ "case \\."m":" {gsub(/.*return |_/,""); print; exit}' "$REAL_SWIFT")"
  case "$want_sha" in [0-9a-f]*) ;; *) fail "не смог выбрать эталон для $m"; continue ;; esac
  has "$m: строка модели" "MODEL	$m	$want_folder	$want_sha	$want_size	"
done
has "адрес: владелец, репо, тег" "SOURCE	k2-fsa	sherpa-onnx	asr-models	.tar.bz2"
has "требуемые файлы parakeet" "encoder.int8.onnx,decoder.int8.onnx,joiner.int8.onnx,tokens.txt"
unset SWIFT_UNDER_TEST

echo "== разбор: поломанный файл не молчит"
sed "s/$SHA_A/${SHA_A:0:63}/" "$SWIFT" > "$W/broken.swift"
OUT="$(CHECK_MODELS_SWIFT="$W/broken.swift" /bin/bash "$SCRIPT" 2>&1)"; RC=$?
rc_is "короткая сумма" 3
sed '/case .beta: return "folder-beta"/d' "$SWIFT" > "$W/broken2.swift"
OUT="$(CHECK_MODELS_SWIFT="$W/broken2.swift" /bin/bash "$SCRIPT" 2>&1)"; RC=$?
rc_is "у модели нет папки" 3
sed 's#github.com/own/repo/releases/download/tag1#example.com/x#' "$SWIFT" > "$W/broken3.swift"
OUT="$(CHECK_MODELS_SWIFT="$W/broken3.swift" /bin/bash "$SCRIPT" 2>&1)"; RC=$?
rc_is "чужой адрес" 3

PUBSCRIPT="$PWD/scripts/model-watch-publish.sh"
echo "== сценарии"
suite "$SCRIPT"
echo "== ветка и задача"
psuite "$PUBSCRIPT"
REAL_FAILS=$FAILS

# --- Поломки: проверка обязана покраснеть -----------------------------------------------------------------------
mutant() { # имя sed-выражение исходник набор
  local copy="$W/mutant.sh" src="$3" runner="$4"
  sed "$2" "$src" > "$copy"
  if cmp -s "$src" "$copy"; then fail "поломка «$1» не применилась (изменился текст скрипта?)"; return; fi
  local before=$FAILS
  QUIET=1; "$runner" "$copy" 2>/dev/null; QUIET=0
  if [ "$FAILS" -gt "$before" ]; then
    FAILS=$before
    pass "поломка «$1»: проверка покраснела"
  else
    fail "поломка «$1»: проверка осталась зелёной, она ничего не ловит"
  fi
}
echo "== поломки"
mutant "сумма не сверяется" 's/\[ "\$digest" = "sha256:\$sha" \] && //' "$SCRIPT" suite
mutant "сбой сети считается изменением" 's/^RC_NET=2/RC_NET=1/' "$SCRIPT" suite
mutant "ссылка наружу пропускается" 's/if t.startswith("\/") or not inside(res):/if False:/' "$SCRIPT" suite
mutant "apply не проверяет сумму (ни до правки, ни после)" 's/if not re.fullmatch(r"\[0-9a-f\]{64}", sha): die/if False: die/; s/if not re.fullmatch(r"\[0-9a-f\]{64}", s): die/if False: die/' "$SCRIPT" suite
mutant "apply не проверяет размер" 's/if not re.fullmatch(r"\[1-9\]\[0-9\]{0,14}", size): die/if False: die/' "$SCRIPT" suite
mutant "apply меняет сумму у всех моделей" 's/(case \\\.%s:\[ \\t\]\*return )\\"\[0-9a-f\]{64}\\"" % re.escape(name)/(case \\.\\w+:[ \\t]*return )\\"[0-9a-f]{64}\\"" % ()/' "$SCRIPT" suite
mutant "проверка вердикта: итог всегда ok" 's/^  case "\$VERDICT" in ok|fail|net) ;; \*) VERDICT=fail ;; esac/  VERDICT=ok/' "$SCRIPT" suite
mutant "push в main" 's#origin "refs/heads/\$branch:refs/heads/\$branch"#origin "HEAD:refs/heads/main"#' "$PUBSCRIPT" psuite
mutant "ветка не проверяется на повтор" 's/if \[ "\$lr" = 0 \]; then/if false; then/' "$PUBSCRIPT" psuite
mutant "закрытая задача не учитывается" 's/if issue_exists "\$title" \&\& ! issue_open "\$title"; then/if false; then/' "$PUBSCRIPT" psuite
mutant "задача не ищется среди прежних" "s/'any(.\[\]; .title == \\\$t)'/'any(.[]; false)'/" "$PUBSCRIPT" psuite
mutant "проверка не прошла, а ветка создаётся" 's/\[ "\$kind" = changed \] \&\& \[ "\$verdict" = ok \] || continue/[ "$kind" = changed ] || continue/' "$PUBSCRIPT" psuite

echo
if [ "$REAL_FAILS" -eq 0 ] && [ "$FAILS" -eq 0 ]; then echo "model-watch: всё зелёное"; exit 0; fi
echo "model-watch: провалов $FAILS"; exit 1
