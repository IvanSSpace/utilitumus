#!/bin/bash
# Проверка scripts/check-model-updates.sh без сети: вместо настоящего curl подставной, ответы из файлов-фикстур.
# Сценарии: совпало, изменилась сумма, изменился размер, файл пропал, релиз пропал, сбой сети и API (код 2, не «изменилось»),
# страницы списка файлов, разбор настоящего VoiceModels.swift, --verify (состав архива, опасные пути, сверка с Hugging Face).
# Потом три поломки скрипта: сумма не сверяется, сбой сети считается изменением, ссылка наружу пропускается.
# Каждая поломка обязана покраснеть, иначе проверка ничего не стоит.
# Настоящая сеть, настоящие модели и настроек не затрагиваются: всё во временной папке.
# Tests/lib/check-limit.sh в этой ветке нет, поэтому лимит времени здесь не подключён.
set -u
cd "$(dirname "$0")/.."

SCRIPT="$PWD/scripts/check-model-updates.sh"
REAL_SWIFT="$PWD/Sources/Modules/Voice/VoiceModels.swift"
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

# Мини-копия VoiceModels.swift той же формы: две модели, как в настоящем файле.
SWIFT="$W/VoiceModels.swift"
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
rc_is() { [ "$RC" = "$2" ] && pass "$1: код $2" || fail "$1: ждал код $2, вышел $RC"; }
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
  [ "$(cat "$EVENTS_FILE")" = "$(printf 'changed\tfolder-alpha\tsha256:%s' "$SHA_N")" ] && pass "сумма: событие для workflow" || fail "сумма: событие для workflow"

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
  verify_base() { base; route "$(PAGE 1)" 200 "[$(asset folder-alpha "$gsha" 1000),$(asset folder-beta "sha256:$SHA_B" 2000)]"; route "$(DL folder-alpha)" 200 "$1"; }
  tree() { printf '[{"type":"file","path":"m.onnx","lfs":{"oid":"%s"}},{"type":"file","path":"tokens.txt"}]' "$1"; }

  verify_base "$good"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 200 "$(tree "$onnx_sha")"
  run "$S" --verify
  rc_is "verify: совпало" 1; has "verify: digest скачанного" "Сверка с digest GitHub: совпала"; has "verify: итог" "совпало с Hugging Face"
  has "verify: состав годен" "Состав архива: годен"; has "verify: перечень файлов" "folder-alpha/m.onnx"
  verify_base "$good"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 404 '{"error":"not found"}'
  run "$S" --verify; has "verify: нет страницы" "другой копии нет"
  verify_base "$good"; route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 200 "$(tree "$SHA_N")"
  run "$S" --verify; has "verify: отличается" "НЕ СОВПАЛО"; hasnt "verify: не «совпало с Hugging Face»" "совпало с Hugging Face"
  verify_base "$good"; route "$(PAGE 1)" 200 "[$(asset folder-alpha "sha256:$SHA_N" 1000),$(asset folder-beta "sha256:$SHA_B" 2000)]"
  route "$HF/api/models/csukuangfj/folder-alpha/tree/main" 404 'x'
  run "$S" --verify; has "verify: digest скачанного не тот" "НЕ СОВПАЛА"

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
}

# --- Разбор VoiceModels.swift -----------------------------------------------------------------------------------
echo "== разбор настоящего VoiceModels.swift"
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

echo "== сценарии"
suite "$SCRIPT"
REAL_FAILS=$FAILS

# --- Поломки: проверка обязана покраснеть -----------------------------------------------------------------------
mutant() { # имя sed-выражение
  local copy="$W/mutant.sh"
  cp "$SCRIPT" "$copy"
  sed "$2" "$SCRIPT" > "$copy"
  if cmp -s "$SCRIPT" "$copy"; then fail "поломка «$1» не применилась (изменился текст скрипта?)"; return; fi
  local before=$FAILS
  QUIET=1; suite "$copy"; QUIET=0
  if [ "$FAILS" -gt "$before" ]; then
    FAILS=$before
    pass "поломка «$1»: проверка покраснела"
  else
    fail "поломка «$1»: проверка осталась зелёной, она ничего не ловит"
  fi
}
echo "== поломки"
mutant "сумма не сверяется" 's/\[ "\$digest" = "sha256:\$sha" \] && //'
mutant "сбой сети считается изменением" 's/^RC_NET=2/RC_NET=1/'
mutant "ссылка наружу пропускается" 's/if t.startswith("\/") or not inside(res):/if False:/'

echo
if [ "$REAL_FAILS" -eq 0 ] && [ "$FAILS" -eq 0 ]; then echo "model-watch: всё зелёное"; exit 0; fi
echo "model-watch: провалов $FAILS"; exit 1
