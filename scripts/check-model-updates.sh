#!/bin/bash
# Следит за файлами моделей Голоса у авторов: не переиздали ли архив, на который указывает VoiceTypes.swift.
# Сумму в продукт сама не принимает: проверка (--verify) только готовит ветку с правкой (--apply), слияние и выпуск
# делает человек, иначе подмена у авторов дошла бы до пользователей без него.
#
# Источник правды — Sources/Modules/Voice/UI/VoiceTypes.swift: адрес, folderName, sha256, sizeBytes, requiredFiles.
# Для каждой модели через GitHub API читаются digest, size, updated_at, uploader и сравниваются с вшитым.
#
# Использование: scripts/check-model-updates.sh [--verify] [--parse] [--apply ПАПКА СУММА РАЗМЕР]
#   --verify  при расхождении скачать архив во временную папку, сверить digest и размер, проверить состав и пути,
#             сравнить *.onnx с Hugging Face (csukuangfj/<folderName>). Без флага большое не качается.
#   --parse   только показать, что разобрано из VoiceTypes.swift.
#   --apply   без сети: заменить в VoiceTypes.swift сумму (64 знака, строчные) и размер (число) одной модели из списка
#             по имени её папки. Больше ничего не меняется, это проверяется разбором до и после. Повтор ничего не меняет.
#
# Коды выхода: 0 — всё совпало; 1 — файл изменился или пропал; 2 — сбой сети или API (это не «изменилось»);
#              3 — не удалось разобрать VoiceTypes.swift, неверные аргументы, --apply отказал.
#              При --verify сбой скачивания или Hugging Face даёт код 2: проверка не состоялась, это не «подмена».
# Окружение: GITHUB_TOKEN или GH_TOKEN (необязательно, только поднимает лимит запросов, уходит лишь на api.github.com);
#            MODEL_WATCH_EVENTS — файл для workflow, строки через табуляцию:
#              changed папка sha256:сумма размер залил обновлено итог(ok|fail|unverified)
#              missing папка -
# Для проверок подменяются CHECK_MODELS_SWIFT, CHECK_MODELS_GH_API, CHECK_MODELS_HF_API.
# bash 3.2 (системный macOS), python3 -I, curl.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SWIFT="${CHECK_MODELS_SWIFT:-$HERE/../Sources/Modules/Voice/UI/VoiceTypes.swift}"
GH_API="${CHECK_MODELS_GH_API:-https://api.github.com}"
HF_API="${CHECK_MODELS_HF_API:-https://huggingface.co}"
HF_OWNER="csukuangfj"
EVENTS="${MODEL_WATCH_EVENTS:-}"
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

RC_CHANGED=1
RC_NET=2
RC_USAGE=3

VERIFY=0
PARSE_ONLY=0
APPLY=0
A_FOLDER=""; A_SHA=""; A_SIZE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verify) VERIFY=1 ;;
    --parse) PARSE_ONLY=1 ;;
    --apply)
      [ $# -ge 4 ] || { echo "--apply требует три аргумента: ПАПКА СУММА РАЗМЕР" >&2; exit "$RC_USAGE"; }
      APPLY=1; A_FOLDER="$2"; A_SHA="$3"; A_SIZE="$4"; shift 3 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit "$RC_USAGE" ;;
  esac
  shift
done

T="$(mktemp -d "${TMPDIR:-/tmp}/model-watch.XXXXXX")" || exit "$RC_NET"
trap 'rm -rf "$T"' EXIT

# --- Разбор и правка VoiceTypes.swift -----------------------------------------------------------------------------
# Одна программа на python для двух режимов: parse — разбор, apply — замена суммы и размера одной модели.
# Разбор: строка SOURCE (владелец, репозиторий, тег, суффикс) и по строке MODEL на каждый case enum'а.
cat > "$T/models.py" <<'PY'
import os, re, shutil, sys, tempfile

def die(msg, code=3):
    sys.stderr.write("VoiceTypes.swift: " + msg + "\n"); sys.exit(code)

def block_span(text, prop):
    m = re.search(r"\n    var " + prop + r": [^\n{]*\{", text)
    if not m: die("нет свойства " + prop)
    depth, i = 1, m.end()
    while depth and i < len(text):
        depth += {"{": 1, "}": -1}.get(text[i], 0); i += 1
    return m.end(), i

def parse(text):
    head = re.search(r"enum VoiceModel\b[^{]*\{(.*?)\n    var id", text, re.S)
    if not head: die("не нашёл enum VoiceModel")
    cases = re.findall(r"^\s*case (\w+)\s*$", head.group(1), re.M)
    if not cases: die("в enum нет ни одного case")

    def per_case(prop):
        a, b = block_span(text, prop)
        out = {}
        for name, rest in re.findall(r"case \.(\w+):\s*return (.+)", text[a:b]):
            out[name] = rest.strip()
        for c in cases:
            if c not in out: die("у свойства %s нет значения для %s" % (prop, c))
        return out

    def one_string(v, what):
        m = re.fullmatch(r"\"([^\"\\]*)\"", v)
        if not m: die("не строка в %s: %s" % (what, v))
        return m.group(1)

    a, b = block_span(text, "url")
    url = re.search(r"URL\(string: \"https://github\.com/([\w.-]+)/([\w.-]+)/releases/download/([\w.-]+)/\\\(folderName\)([\w.]+)\"\)", text[a:b])
    if not url: die("адрес архива не похож на github.com/<владелец>/<репо>/releases/download/<тег>/\\(folderName)<суффикс>")

    sha, size, folder, req = per_case("sha256"), per_case("sizeBytes"), per_case("folderName"), per_case("requiredFiles")
    models = []
    for c in cases:
        s = one_string(sha[c], "sha256 " + c)
        if not re.fullmatch(r"[0-9a-f]{64}", s): die("sha256 %s не 64 шестнадцатеричных знака" % c)
        if not re.fullmatch(r"[0-9_]+", size[c]): die("sizeBytes %s не число" % c)
        f = one_string(folder[c], "folderName " + c)
        if not re.fullmatch(r"[A-Za-z0-9._-]+", f) or f in (".", ".."): die("folderName %s с недопустимыми знаками" % c)
        files = re.findall(r"\"([^\"]+)\"", req[c])
        if not files or any(not re.fullmatch(r"[A-Za-z0-9._-]+", x) for x in files): die("requiredFiles %s пусты или с недопустимыми именами" % c)
        models.append((c, f, s, int(size[c].replace("_", "")), ",".join(files)))
    return url.groups(), models

def do_parse(path):
    text = open(path, encoding="utf-8", newline="").read()
    source, models = parse(text)
    print("\t".join(("SOURCE",) + source))
    for c, f, s, n, files in models:
        print("\t".join(("MODEL", c, f, s, str(n), files)))

def do_apply(path, folder, sha, size):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", folder) or ".." in folder or folder in (".", ".."): die("--apply: недопустимое имя папки")
    if not re.fullmatch(r"[0-9a-f]{64}", sha): die("--apply: сумма должна быть 64 строчными шестнадцатеричными знаками")
    if not re.fullmatch(r"[1-9][0-9]{0,14}", size): die("--apply: размер должен быть положительным числом")
    new_size = int(size)
    text = open(path, encoding="utf-8", newline="").read()
    source, models = parse(text)
    hit = [m for m in models if m[1] == folder]
    if len(hit) != 1: die("--apply: модели с папкой %s нет в списке VoiceTypes.swift" % folder)
    name, _, old_sha, old_size, _ = hit[0]
    if old_sha == sha and old_size == new_size:
        print("уже применено: %s, sha256 %s…, %d байт, файл не менялся" % (folder, sha[:12], new_size)); return

    def swap(src, prop, pattern, repl):
        a, b = block_span(src, prop)
        chunk, n = re.subn(pattern, repl, src[a:b])
        if n != 1: die("--apply: в свойстве %s строку модели %s нашёл %d раз, ждал один" % (prop, name, n))
        return src[:a] + chunk + src[b:]

    new = text
    if old_sha != sha:
        new = swap(new, "sha256", r"(case \.%s:[ \t]*return )\"[0-9a-f]{64}\"" % re.escape(name), lambda m: m.group(1) + '"' + sha + '"')
    if old_size != new_size:
        grouped = "{:,}".format(new_size).replace(",", "_")
        new = swap(new, "sizeBytes", r"(case \.%s:[ \t]*return )[0-9_]+(?=[ \t]*(\r?\n))" % re.escape(name), lambda m: m.group(1) + grouped)

    # Проверка разбором: изменилась только сумма и размер этой модели, и ровно столько строк, сколько значений поменялось.
    source2, models2 = parse(new)
    if source2 != source or len(models2) != len(models): die("--apply: после правки изменился адрес или список моделей")
    for before, after in zip(models, models2):
        want = (before[0], before[1], sha if before[1] == folder else before[2], new_size if before[1] == folder else before[3], before[4])
        if after != want: die("--apply: после правки изменилось лишнее у модели %s" % before[0])
    a, b = text.split("\n"), new.split("\n")
    diff = [i for i in range(len(a)) if a[i] != b[i]] if len(a) == len(b) else None
    expected = (old_sha != sha) + (old_size != new_size)
    if diff is None or len(diff) != expected or any(("case .%s:" % name) not in a[i] for i in diff):
        die("--apply: изменились не те строки")

    fd, tmp = tempfile.mkstemp(prefix=".VoiceModels.", dir=os.path.dirname(os.path.abspath(path)))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f: f.write(new)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp): os.unlink(tmp)
        raise
    print("применено: %s, sha256 %s… (было %s…), %d байт (было %d), изменено строк: %d" % (folder, sha[:12], old_sha[:12], new_size, old_size, expected))

if __name__ == "__main__":
    if sys.argv[1] == "parse": do_parse(sys.argv[2])
    elif sys.argv[1] == "apply": do_apply(*sys.argv[2:6])
PY

if [ "$APPLY" = 1 ]; then
  python3 -I "$T/models.py" apply "$SWIFT" "$A_FOLDER" "$A_SHA" "$A_SIZE" || exit "$RC_USAGE"
  exit 0
fi

PARSED="$(python3 -I "$T/models.py" parse "$SWIFT")" || exit "$RC_USAGE"
if [ "$PARSE_ONLY" = 1 ]; then echo "$PARSED"; exit 0; fi

# --- Сеть -----------------------------------------------------------------------------------------------------
HTTP=""
# fetch URL ФАЙЛ СТОРОНА ТАЙМАУТ [-L]: HTTP-код в $HTTP; возврат 1 — сбой сети (кода нет).
# Токен уходит только на GitHub API (сторона 1) и не попадает в список процессов: заголовок передан через -K.
fetch() {
  local url="$1" out="$2" gh="$3" max="$4" follow="${5:-}" code rc
  if [ "$gh" = 1 ] && [ -n "$TOKEN" ]; then
    code="$(curl -sS ${follow:+"$follow"} --max-time "$max" --retry 2 --retry-delay 2 -o "$out" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") "$url" 2>/dev/null)"
  elif [ "$gh" = 1 ]; then
    code="$(curl -sS ${follow:+"$follow"} --max-time "$max" --retry 2 --retry-delay 2 -o "$out" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)"
  else
    code="$(curl -sS ${follow:+"$follow"} --max-time "$max" --retry 2 --retry-delay 2 -o "$out" -w '%{http_code}' "$url" 2>/dev/null)"
  fi
  rc=$?
  HTTP="$code"
  [ "$rc" = 0 ] && [ -n "$code" ]
}

net_fail() {
  echo "СБОЙ СЕТИ ИЛИ API: $1" >&2
  echo "Это не значит, что файл изменился: проверка не состоялась. Код 2." >&2
  exit "$RC_NET"
}

# event ВИД ПАПКА ПОЛЕ...: строка через табуляцию в файл для workflow; табуляции и переводы строк в значениях заменяются.
event() {
  [ -n "$EVENTS" ] || return 0
  local line="" v tab
  tab="$(printf '\t')"
  for v in "$@"; do line="$line${line:+$tab}$(printf '%s' "$v" | tr '\t\r\n' '   ')"; done
  printf '%s\n' "$line" >> "$EVENTS"
}

SOURCE_LINE="$(echo "$PARSED" | grep '^SOURCE')"
OWNER="$(echo "$SOURCE_LINE" | cut -f2)"
REPO="$(echo "$SOURCE_LINE" | cut -f3)"
TAG="$(echo "$SOURCE_LINE" | cut -f4)"
EXT="$(echo "$SOURCE_LINE" | cut -f5)"
RELEASE_PAGE="https://github.com/$OWNER/$REPO/releases/tag/$TAG"

# Релиз. Список assets внутри релиза обрезан (на 500 штук, а их больше), поэтому читаем /releases/<id>/assets постранично.
RELEASE_GONE=0
fetch "$GH_API/repos/$OWNER/$REPO/releases/tags/$TAG" "$T/release.json" 1 60 || net_fail "нет ответа от $GH_API (релиз $TAG)"
case "$HTTP" in
  200) ;;
  404) RELEASE_GONE=1 ;;
  *) net_fail "GitHub API ответил $HTTP на запрос релиза $TAG" ;;
esac

mkdir -p "$T/assets"
if [ "$RELEASE_GONE" = 0 ]; then
  REL_ID="$(python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["id"]))' "$T/release.json" 2>/dev/null)" \
    || net_fail "ответ GitHub по релизу $TAG не похож на JSON с id"
  page=1
  while [ "$page" -le 40 ]; do
    fetch "$GH_API/repos/$OWNER/$REPO/releases/$REL_ID/assets?per_page=100&page=$page" "$T/assets/p$page.json" 1 60 \
      || net_fail "нет ответа от $GH_API (страница $page списка файлов)"
    [ "$HTTP" = 200 ] || net_fail "GitHub API ответил $HTTP на страницу $page списка файлов"
    count="$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/assets/p$page.json" 2>/dev/null)" \
      || net_fail "страница $page списка файлов не похожа на JSON"
    [ "$count" -gt 0 ] || break
    page=$((page + 1))
  done
fi

# find_asset ИМЯ: «digest size updated_at uploader url» через табуляцию, пусто — файла нет; «-» — поле не прислано.
find_asset() {
  python3 -I -c '
import glob, json, sys
for path in sorted(glob.glob(sys.argv[1] + "/p*.json")):
    for a in json.load(open(path)):
        if a.get("name") == sys.argv[2]:
            up = a.get("uploader") or {}
            f = lambda v: "-" if v in (None, "") else str(v)
            print("\t".join(f(v) for v in (a.get("digest"), a.get("size"), a.get("updated_at"), up.get("login"), a.get("browser_download_url"))))
            sys.exit(0)
' "$T/assets" "$1"
}

# --- Уточнение: --verify ----------------------------------------------------------------------------------------
# verify_model ПАПКА ФАЙЛЫ АДРЕС ДИГЕСТ_GITHUB РАЗМЕР_GITHUB: итог в $VERDICT — ok (всё сошлось), fail (не сошлось),
# net (проверка не состоялась из-за сбоя сети: это не «подмена»).
VERDICT=""
verify_model() {
  local folder="$1" required="$2" url="$3" want="$4" api_size="$5" dir hf
  dir="$T/verify-$folder"
  mkdir -p "$dir"
  VERDICT=net
  echo "  Уточнение (--verify): качаю архив во временную папку, в настоящие модели ничего не пишется."
  if ! fetch "$url" "$dir/archive.tar.bz2" 0 1800 -L || [ "$HTTP" != 200 ]; then
    echo "  Уточнить не удалось: архив не скачался (код ${HTTP:-нет ответа}). Это сбой сети, а не подмена."
    return 0
  fi
  if fetch "$HF_API/api/models/$HF_OWNER/$folder/tree/main" "$dir/hf.json" 0 60; then
    case "$HTTP" in
      200) hf="$dir/hf.json" ;;
      404) hf="none" ;;
      *) hf="unknown" ;;
    esac
  else
    hf="unknown"
  fi
  python3 -I - "$dir/archive.tar.bz2" "$folder" "$required" "$hf" "$want" "$HF_OWNER" "$api_size" "$dir/verdict" <<'PY' | sed 's/^/  /'
import hashlib, json, os, posixpath, re, sys, tarfile
archive, folder, required, hf, want, hf_owner, api_size, verdict_path = sys.argv[1:9]
required = [r for r in required.split(",") if r]
def safe(s):
    return re.sub(r"[^A-Za-z0-9._/+-]", "?", s)

h = hashlib.sha256()
with open(archive, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
got = "sha256:" + h.hexdigest()
print("Скачанный архив: %s" % got)
digest_ok = got == want
print("Сверка с digest GitHub: %s" % ("совпала" if digest_ok else "НЕ СОВПАЛА (GitHub отдаёт не то, что показывает в digest)"))
real_size = os.path.getsize(archive)
size_ok = str(real_size) == api_size
print("Сверка размера: скачано %d байт, по данным GitHub %s байт: %s" % (real_size, api_size, "совпала" if size_ok else "НЕ СОВПАЛА"))

problems, files, onnx = [], {}, {}
def inside(path):
    return path == folder or path.startswith(folder + "/")
try:
    with tarfile.open(archive, "r|bz2") as tar:
        for m in tar:
            name = m.name
            if name.startswith("/") or ".." in name.split("/"):
                problems.append("небезопасный путь: %s" % safe(name)); continue
            n = posixpath.normpath(name)
            if not inside(n):
                problems.append("путь вне папки %s: %s" % (folder, safe(name)))
            if m.issym():
                t = m.linkname
                res = posixpath.normpath(posixpath.join(posixpath.dirname(n), t))
                if t.startswith("/") or not inside(res):
                    problems.append("символическая ссылка наружу: %s -> %s" % (safe(name), safe(t)))
            elif m.islnk():
                t = m.linkname
                if t.startswith("/") or ".." in t.split("/") or not inside(posixpath.normpath(t)):
                    problems.append("жёсткая ссылка наружу: %s -> %s" % (safe(name), safe(t)))
            elif m.isfile():
                files[n] = m.size
                if n.endswith(".onnx"):
                    fh, src = hashlib.sha256(), tar.extractfile(m)
                    for chunk in iter(lambda: src.read(1 << 20), b""):
                        fh.update(chunk)
                    onnx[posixpath.basename(n)] = fh.hexdigest()
            elif not m.isdir():
                problems.append("особый тип файла: %s" % safe(name))
except (tarfile.TarError, OSError, EOFError) as e:
    problems.append("архив не читается: %s" % safe(str(e)))

print("Файлов в архиве: %d" % len(files))
for p in sorted(files)[:40]:
    print("  %s  %d" % (safe(p), files[p]))
if len(files) > 40:
    print("  … и ещё %d" % (len(files) - 40))
for r in required:
    if folder + "/" + r not in files:
        problems.append("нет нужного файла %s" % r)
if problems:
    print("Состав архива: ПРОБЛЕМЫ")
    for p in problems:
        print("  - " + p)
else:
    print("Состав архива: годен (все нужные файлы на месте, опасных путей и ссылок нет)")
verdict = "ok" if (digest_ok and size_ok and not problems) else "fail"

page = "%s/%s" % (hf_owner, folder)
if hf == "none":
    print("Сверка с Hugging Face: страницы %s нет. ИТОГ: другой копии нет, сверить не с чем." % page)
    verdict = "fail"
elif hf == "unknown":
    print("Сверка с Hugging Face: страница %s не ответила. ИТОГ: сверить не удалось (сбой сети, не подмена)." % page)
    if verdict == "ok": verdict = "net"
else:
    lfs = {}
    for item in json.load(open(hf)):
        sha = (item.get("lfs") or {}).get("oid")
        if sha:
            lfs[item["path"]] = sha
    same = [f for f in sorted(onnx) if lfs.get(f) == onnx[f]]
    diff = [f for f in sorted(onnx) if f in lfs and lfs[f] != onnx[f]]
    absent = [f for f in sorted(onnx) if f not in lfs]
    if not onnx:
        print("Сверка с Hugging Face: в архиве нет .onnx, сравнивать нечего. ИТОГ: сверить не удалось.")
        verdict = "fail"
    elif diff or absent:
        print("Сверка с Hugging Face (%s): ИТОГ: НЕ СОВПАЛО. Отличаются: %s. Нет на Hugging Face: %s." % (page, ", ".join(safe(x) for x in diff) or "-", ", ".join(safe(x) for x in absent) or "-"))
        verdict = "fail"
    else:
        print("Сверка с Hugging Face (%s): ИТОГ: совпало с Hugging Face (%d файлов .onnx: %s)." % (page, len(same), ", ".join(safe(x) for x in same)))
open(verdict_path, "w").write(verdict)
PY
  VERDICT="$(cat "$dir/verdict" 2>/dev/null)"
  case "$VERDICT" in ok|fail|net) ;; *) VERDICT=fail ;; esac
}

# --- Проверка по моделям ----------------------------------------------------------------------------------------
ANY_CHANGED=0
ANY_ERROR=0
while IFS="$(printf '\t')" read -r kind name folder sha size required; do
  [ "$kind" = MODEL ] || continue
  asset_name="$folder$EXT"
  url="https://github.com/$OWNER/$REPO/releases/download/$TAG/$asset_name"
  line=""
  [ "$RELEASE_GONE" = 1 ] || line="$(find_asset "$asset_name")"

  if [ -z "$line" ]; then
    ANY_CHANGED=1
    event missing "$folder" "-"
    echo "ПРОПАЛ  $name ($folder)"
    if [ "$RELEASE_GONE" = 1 ]; then
      echo "  Релиз $TAG у авторов не найден (GitHub ответил 404): $RELEASE_PAGE"
    else
      echo "  В релизе $TAG нет файла $asset_name: авторы удалили или переименовали архив."
    fi
    echo "  У пользователей скачивание этой модели сейчас не работает. Вшитый адрес: $url"
    continue
  fi

  IFS="$(printf '\t')" read -r digest api_size updated uploader dl_url <<EOF
$line
EOF
  if [ "$digest" = "-" ] || [ "$api_size" = "-" ]; then
    ANY_ERROR=1
    echo "СБОЙ API  $name ($folder): GitHub не прислал digest или size, проверить нельзя (это не «изменилось»)." >&2
    continue
  fi
  digest="$(echo "$digest" | tr 'A-F' 'a-f')"
  case "$api_size" in *[!0-9]*)
    ANY_ERROR=1
    echo "СБОЙ API  $name ($folder): GitHub прислал странный размер, проверить нельзя (это не «изменилось»)." >&2
    continue ;;
  esac
  if ! echo "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    ANY_ERROR=1
    echo "СБОЙ API  $name ($folder): GitHub прислал digest в неожиданном виде, проверить нельзя (это не «изменилось»)." >&2
    continue
  fi

  if [ "$digest" = "sha256:$sha" ] && [ "$api_size" = "$size" ]; then
    echo "ok  $name: sha256 ${sha:0:12}…, $size байт (залил $uploader, обновлено $updated)"
    continue
  fi

  echo "ИЗМЕНИЛОСЬ  $name ($folder)"
  echo "  Было (вшито в VoiceTypes.swift): sha256:$sha, $size байт"
  echo "  Стало (по данным GitHub):         $digest, $api_size байт"
  echo "  Залил: $uploader, обновлено: $updated"
  echo "  Файл:  $dl_url"
  echo "  Релиз: $RELEASE_PAGE"
  echo "  Hugging Face: https://huggingface.co/$HF_OWNER/$folder"
  echo "  Новую сумму в продукт сам скрипт не принимает: слияние и выпуск за человеком."
  verdict=unverified
  if [ "$VERIFY" = 1 ]; then
    verify_model "$folder" "$required" "$dl_url" "$digest" "$api_size"
    verdict="$VERDICT"
    if [ "$verdict" = net ]; then
      ANY_ERROR=1
      echo "  Проверка не состоялась из-за сбоя сети: ни ветки, ни задачи не будет, повтор при следующем запуске (код 2)." >&2
      continue
    fi
  else
    echo "  Для уточнения: scripts/check-model-updates.sh --verify"
  fi
  ANY_CHANGED=1
  [[ "$uploader" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] || uploader="?"
  [[ "$updated" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$ ]] || updated="?"
  event changed "$folder" "$digest" "$api_size" "$uploader" "$updated" "$verdict"
done <<EOF
$PARSED
EOF

[ "$ANY_CHANGED" = 1 ] && exit "$RC_CHANGED"
[ "$ANY_ERROR" = 1 ] && exit "$RC_NET"
exit 0
