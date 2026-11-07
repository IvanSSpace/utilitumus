#!/bin/bash
# Общий выпуск: подставные репозиторий с локальным origin, gh, codesign и сборка. Первая часть — --dry-run и отказы, там gh при
# вызове проваливает проверку. Вторая — параллельность и --publish с подставным gh и git поверх локального origin.
# Ничего не пушится в настоящий репозиторий, настоящий каталог не трогается.
# Папка: RELEASE_ALL_CHECK_DIR, иначе $TMPDIR/release-all-check.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${RELEASE_ALL_CHECK_DIR:-${TMPDIR:-/tmp}/release-all-check}"
rm -rf "$OUT"
mkdir -p "$OUT/bin"
FX="$OUT/repo"
GH_LOG="$OUT/gh.log"
: > "$GH_LOG"

fails=0
pass() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else bad "$what"; fi; }
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

printf '#!/bin/bash\necho "gh $*" >> "%s"\nexit 99\n' "$GH_LOG" > "$OUT/bin/gh"
# Подпись подставная: настоящей проверки без сертификата не будет, важно, что скрипт её вызывает и слушается отказа.
printf '#!/bin/bash\necho "codesign $*" >> "%s/codesign.log"\n[ -z "${FAKE_BAD_SIGN:-}" ]\n' "$OUT" > "$OUT/bin/codesign"
chmod +x "$OUT/bin/gh" "$OUT/bin/codesign"

# Подставная сборка: бандл с версией, меткой выпуска и помощниками из манифеста.
mkdir -p "$FX/scripts" "$FX/Sources/Kit" "$FX/Resources" "$FX/Catalog" "$FX/Sources/Apps/Awake" "$FX/Sources/Apps/Fans" "$FX/Sources/Apps/Load" "$FX/Sources/Apps/Mouse"
cp scripts/release-all.sh scripts/check-no-seam.sh "$FX/scripts/"
cp Sources/Kit/KitSigning.swift "$FX/Sources/Kit/"
cp Info.plist "$FX/Info.plist"
HUB="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
EPOCH="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
printf '[{"version":"%s","items":[{"icon":"x","text":"Проверка"}]}]\n' "$HUB" > "$FX/Resources/WhatsNew.json"
printf '{"schema":1,"apps":[]}\n' > "$FX/Catalog/catalog.json"
for name in Awake Fans Load Mouse; do
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.0" -c "Add :UtilitumusSecurityEpoch string $EPOCH" \
    "$FX/Sources/Apps/$name/Info.plist" >/dev/null 2>&1 || {
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0.0</string></dict></plist>' > "$FX/Sources/Apps/$name/Info.plist"
  }
done
for name in Awake Load Mouse; do printf '{}\n' > "$FX/Sources/Apps/$name/manifest.json"; done
printf '{"helpers":[{"kind":"swift-tool","path":"Contents/MacOS/utilitumus-fan","identifier":"local.utilitumus.fan"}]}\n' > "$FX/Sources/Apps/Fans/manifest.json"
cat > "$FX/scripts/build-app.sh" <<'FAKE'
#!/bin/bash
set -euo pipefail
id="$1"; name="$2"; version="$3"; app="$4/$name.app"
if [ -n "${FAKE_DIR:-}" ]; then
  . "$FAKE_DIR/lib.sh"
  event "build-start $id"
  event "build-env $id unlocked=${UTILITUMUS_SIGNING_UNLOCKED:-} swift=${UTILITUMUS_SWIFT_JOBS:-}"
  echo "лог сборки $id"
  if [ -n "${FAKE_BUILD_BARRIER:-}" ]; then barrier build "$FAKE_BUILD_BARRIER"; fi
  if [ -n "${FAKE_BUILD_SLEEP:-}" ]; then sleep "$FAKE_BUILD_SLEEP"; fi
  if [ "${FAKE_RED_BUILD:-}" = "$id" ]; then echo "красная сборка $id"; exit 1; fi
fi
mkdir -p "$app/Contents/MacOS"
# Как у настоящей сборки: архив не повторяется от запуска к запуску.
echo "$$ $RANDOM $RANDOM" > "$app/Contents/MacOS/stamp"
epoch="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -z "${FAKE_NO_EPOCH:-}" ] || epoch=""
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>UtilitumusSecurityEpoch</key><string>$epoch</string>
</dict></plist>
PLIST
[ -n "${FAKE_NO_HELPER:-}" ] || touch "$app/Contents/MacOS/utilitumus-fan"
if [ -n "${FAKE_DIR:-}" ]; then event "build-end $id"; fi
FAKE
chmod +x "$FX/scripts/build-app.sh" "$FX/scripts/release-all.sh"
printf '#!/bin/bash\nif [ -n "${FAKE_DIR:-}" ]; then echo "hub-release $*" >> "$FAKE_DIR/events.log"; [ -z "${FAKE_HUB_RED:-}" ] && exit 0 || exit 1; fi\necho "release.sh $*" >> "%s"\nexit 99\n' "$GH_LOG" > "$FX/scripts/release.sh"
printf '#!/bin/bash\necho "$*" >> "%s/unlock.log"\nif [ -n "${FAKE_DIR:-}" ]; then echo unlock >> "$FAKE_DIR/events.log"; fi\n' "$OUT" > "$FX/scripts/unlock-signing.sh"
chmod +x "$FX/scripts/release.sh" "$FX/scripts/unlock-signing.sh"

git init -q --bare "$OUT/origin.git"
git -C "$FX" init -q -b main
git -C "$FX" remote add origin "$OUT/origin.git"
git -C "$FX" add -A
git -C "$FX" -c user.name=t -c user.email=t@t commit -q -m fixture
git -C "$FX" push -q origin main
BEFORE="$(git -C "$FX" rev-parse HEAD)"

run() { (cd "$FX" && PATH="$OUT/bin:$PATH" TMPDIR="$OUT" "$@" scripts/release-all.sh "${ARGS[@]}" </dev/null 2>&1) || return $?; }
ARGS=(--only awake,fans --note awake="Первая" --note fans="Вторая")
status=0; run env > "$OUT/dry.out" || status=$?
check "dry-run по умолчанию проходит" test "$status" -eq 0
check "в выводе таблица версий и план" has "$OUT/dry.out" "== План выкладки"
check "в плане теги и релизы утилит без Latest" has "$OUT/dry.out" "--latest=false"
check "в плане нет gh для центра с Latest: центр идёт через release.sh" has "$OUT/dry.out" "+ scripts/release.sh $HUB"
last_step="$(grep '^+ ' "$OUT/dry.out" | tail -1)"
check "центр последним шагом" test "$last_step" = "+ scripts/release.sh $HUB"
line_of() { grep -nF -- "$1" "$OUT/dry.out" | head -1 | LC_ALL=C awk -F: '{print $1}'; }
tag_line="$(line_of 'git tag awake-v1.0.0')"
cat_line="$(line_of 'git commit')"
hub_line="$(line_of '+ scripts/release.sh')"
check "порядок: утилиты, каталог, центр" test "$tag_line" -lt "$cat_line" -a "$cat_line" -lt "$hub_line"
check "предупреждение о службе вентиляторов v5" has "$OUT/dry.out" "v5 должна выйти вместе с этим центром"
check "gh не вызывался" test ! -s "$GH_LOG"
check "тегов нет ни у копии, ни в origin" test -z "$(git -C "$FX" tag)$(git --git-dir="$OUT/origin.git" tag)"
check "HEAD и origin не сдвинулись" test "$(git -C "$FX" rev-parse HEAD)" = "$BEFORE" -a "$(git --git-dir="$OUT/origin.git" rev-parse main)" = "$BEFORE"
check "настоящий каталог не изменён" has "$FX/Catalog/catalog.json" '"apps":[]'
work="$(grep -F 'рабочая папка: ' "$OUT/dry.out" | head -1)"; work="${work#*: }"
check "каталог в рабочей папке с заметкой" has "$work/catalog.json" "Первая"
check "у записи minHub и сумма" has "$work/catalog.json" '"sha256"'
check "проверка подписи вызвана" has "$OUT/codesign.log" "certificate leaf"
check "--only: Mouse и Load не в плане и не в каталоге" lacks "$OUT/dry.out" "mouse-v"
check "--only: Load не в плане" lacks "$OUT/dry.out" "load-v"
check "--only: в каталоге рабочей папки только выбранные" test "$(grep -c '"id"' "$work/catalog.json")" -eq 2

expect_refused() { # описание, шаблон в выводе, переменные окружения...; ARGS заданы заранее
  local what="$1" pattern="$2" output st=0
  shift 2
  output="$(run env "$@")" || st=$?
  if [ "$st" -ne 0 ] && grep -qF -- "$pattern" <<<"$output"; then pass "$what"; else bad "$what (код $st): $output"; fi
}
ARGS=(--only awake,fans --note awake="Первая")
expect_refused "нет заметки: отказ" "Нет заметок для fans"
ARGS=(--only awake,fans --note awake="Первая" --note fans="Вторая")
expect_refused "помощник не собран: отказ" "нет помощника" FAKE_NO_HELPER=1
expect_refused "нет метки выпуска: отказ" "UtilitumusSecurityEpoch" FAKE_NO_EPOCH=1
expect_refused "подпись не та: отказ" "подпись не" FAKE_BAD_SIGN=1
ARGS=(--note nosuch="Вторая")
expect_refused "заметка к несуществующей утилите: отказ" "такой утилиты нет"
ARGS=(--only awake,fans --publish --note awake="Первая" --note fans="Вторая")
expect_refused "--publish без терминала: отказ, ничего не выложено" "нужен терминал"
ARGS=(--only awake,fans --publish --dry-run --note awake="Первая" --note fans="Вторая")
expect_refused "--publish вместе с --dry-run: отказ" "вместе нельзя"
ARGS=(--typo)
expect_refused "незнакомый флаг: отказ" "Неизвестный аргумент"
ARGS=(--only awake,fans --note awake="Первая" --note fans="Вторая")
echo dirty > "$FX/dirty.txt"
expect_refused "грязное дерево: отказ" "незакоммиченные"
rm "$FX/dirty.txt"
# Поэтапный выпуск: три утилиты, теги, каталог, потом центр. Каталог уже с чужой записью: она остаётся.
printf '{"schema":1,"apps":[{"id":"stash","version":"1.0.0","minHub":"0.6.0","url":"u","sha256":"s","sizeMB":1,"notes":["x"]}]}\n' > "$FX/Catalog/catalog.json"
git -C "$FX" -c user.name=t -c user.email=t@t commit -q -am "catalog"
git -C "$FX" push -q origin main
BEFORE="$(git -C "$FX" rev-parse HEAD)"
ARGS=(--only awake,fans,load --note awake="Первая" --note fans="Вторая" --note load="Третья")
status=0; run env > "$OUT/three.out" || status=$?
check "--only с тремя утилитами проходит" test "$status" -eq 0
tags="$(grep -oE '^\+ git tag [a-z]+-v[0-9.]+' "$OUT/three.out" | sed 's/+ git tag //' | tr '\n' ' ')"
check "в плане ровно три тега по порядку: $tags" test "$tags" = "awake-v1.0.0 fans-v1.0.0 load-v1.0.0 "
check "в плане нет Mouse" lacks "$OUT/three.out" "mouse"
check "в каталоге после выпуска: чужая запись и три новые" has "$OUT/three.out" "== Каталог после выпуска (в нём: stash 1.0.0, awake 1.0.0, fans 1.0.0, load 1.0.0)"
check "последний шаг центр" test "$(grep '^+ ' "$OUT/three.out" | tail -1)" = "+ scripts/release.sh $HUB"
ARGS=(--only awake,nosuch --note awake="Первая")
expect_refused "--only с неизвестной утилитой: отказ" "нет в Sources/Apps"
ARGS=(--only awake,fans)
expect_refused "--only: заметка нужна каждой выбранной" "Нет заметок для awake"
ARGS=(--only --note awake="Первая")
expect_refused "--only без списка: отказ" "После --only нужен список"
# После scripts/fix.sh каталог новее Info.plist утилиты, а старый тег уже есть: это не повод для отказа и не новый выпуск.
KEEP_CATALOG="$(cat "$FX/Catalog/catalog.json")"
printf '{"schema":1,"apps":[{"id":"awake","version":"1.0.1","minHub":"0.6.0","url":"u","sha256":"s","sizeMB":1,"notes":["x"]}]}\n' > "$FX/Catalog/catalog.json"
git -C "$FX" tag awake-v1.0.0
git -C "$FX" -c user.name=t -c user.email=t@t commit -q -am "после fix.sh"
git -C "$FX" push -q origin main
ARGS=(--only awake,fans --note fans="Вторая")
status=0; run env > "$OUT/after-fix.out" || status=$?
check "каталог новее Info.plist: выпуск идёт" test "$status" -eq 0
check "каталог новее Info.plist: утилита уже в каталоге" has "$OUT/after-fix.out" "уже в каталоге"
check "каталог новее Info.plist: старая версия не выпускается" lacks "$OUT/after-fix.out" "git tag awake-v"
git -C "$FX" tag -d awake-v1.0.0 >/dev/null
printf '%s\n' "$KEEP_CATALOG" > "$FX/Catalog/catalog.json"
git -C "$FX" -c user.name=t -c user.email=t@t commit -q -am "назад"
git -C "$FX" push -q origin main
BEFORE="$(git -C "$FX" rev-parse HEAD)"
ARGS=(--only awake,fans --note awake="Первая" --note fans="Вторая")
git -C "$FX" -c user.name=t -c user.email=t@t commit -q --allow-empty -m ahead
expect_refused "HEAD не совпадает с origin/main: отказ" "не совпадает с GitHub"
git -C "$FX" reset -q --hard "$BEFORE"
printf '[]\n' > "$FX/Resources/WhatsNew.json"
git -C "$FX" -c user.name=t -c user.email=t@t commit -q -am "no notes"
git -C "$FX" push -q origin main
expect_refused "нет записи WhatsNew для центра: отказ" "WhatsNew"
check "gh не вызывался и после отказов" test ! -s "$GH_LOG"

# --- Вторая часть: параллельность, порядок выкладки, повторный запуск, --utilities-only.
REAL_GIT="$(command -v git)"
FAKE="$OUT/fake"
mkdir -p "$FAKE"
cat > "$FAKE/lib.sh" <<'LIB'
event() { echo "$*" >> "$FAKE_DIR/events.log"; }
# Участник ждёт, пока подойдут все: при запуске по очереди никто не дождётся, и в журнале будет timeout.
barrier() { # имя, сколько участников
  local d="$FAKE_DIR/barrier-$1" n=0
  mkdir -p "$d"; : > "$d/$$"
  while [ "$(/bin/ls "$d" | wc -l)" -lt "$2" ]; do
    n=$((n + 1))
    if [ "$n" -ge 40 ]; then event "barrier-timeout $1"; return 0; fi
    sleep 0.1
  done
  event "barrier-met $1"
}
LIB
# Релизы подставного gh лежат файлами: <тег>.state в формате --jq из release-all.sh и <тег>.zip.
cat > "$OUT/bin/gh" <<'GH'
#!/bin/bash
. "$FAKE_DIR/lib.sh"
R="$FAKE_DIR/releases"
mkdir -p "$R"
event "gh $*"
if [ "$1" != auth ] && [ "${GH_TOKEN:-}" != fake-token ]; then event "gh-no-token $*"; fi
case "$1 ${2:-}" in
  "auth token") echo fake-token ;;
  "release view")
    if [ -n "${FAKE_GH_DOWN:-}" ]; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
    if [ ! -e "$R/$3.state" ]; then echo "release not found" >&2; exit 1; fi
    cat "$R/$3.state"
    ;;
  "release download")
    tag="$3"; shift 3
    while [ $# -gt 0 ]; do
      case "$1" in -p) asset="$2"; shift 2 ;; -D) dir="$2"; shift 2 ;; *) shift ;; esac
    done
    cp "$R/$tag.zip" "$dir/$asset"
    ;;
  "release create")
    tag="$3"; zip="$4"
    if [[ "$*" != *"--latest=false --verify-tag"* ]]; then event "create-bad-flags $tag"; exit 1; fi
    if [ -e "$R/$tag.state" ]; then event "create-dup $tag"; exit 1; fi
    if [ "${FAKE_GH_RED:-}" = "$tag" ]; then event "create-red $tag"; echo "HTTP 500" >&2; exit 1; fi
    "$FAKE_REAL_GIT" --git-dir="$FAKE_ORIGIN" rev-parse -q --verify "refs/tags/$tag" >/dev/null || { event "create-no-tag $tag"; exit 1; }
    event "create-start $tag"
    if [ -n "${FAKE_GH_BARRIER:-}" ]; then barrier create "$FAKE_GH_BARRIER"; fi
    cp "$zip" "$R/$tag.zip"
    echo "false $(basename "$zip")" > "$R/$tag.state"
    event "create-end $tag"
    ;;
  *) event "gh-unexpected $*"; exit 99 ;;
esac
GH
# Настоящий git поверх локального origin, журнал и барьер на пуше тегов.
cat > "$OUT/bin/git" <<'GIT'
#!/bin/bash
. "$FAKE_DIR/lib.sh"
case "$*" in
  "tag "*) event "git-tag $2" ;;
  "push -q origin HEAD:main") event "git-push-main" ;;
  "push -q origin "*)
    event "git-push-tag $4"
    if [ -n "${FAKE_PUSH_BARRIER:-}" ]; then barrier push "$FAKE_PUSH_BARRIER"; fi
    ;;
  "commit "*) event "git-commit $*" ;;
esac
exec "$FAKE_REAL_GIT" "$@"
GIT
chmod +x "$OUT/bin/gh" "$OUT/bin/git"

printf '[{"version":"%s","items":[{"icon":"x","text":"Проверка"}]}]\n' "$HUB" > "$FX/Resources/WhatsNew.json"
printf '{"schema":1,"apps":[]}\n' > "$FX/Catalog/catalog.json"
git -C "$FX" -c user.name=t -c user.email=t@t commit -q -am "вторая часть"
git -C "$FX" push -q origin main
git -C "$FX" config user.name t
git -C "$FX" config user.email t@t
BASE="$(git -C "$FX" rev-parse HEAD)"
ORIGIN="$OUT/origin.git"
ALL_NOTES=(--note awake="Первая" --note fans="Вторая" --note load="Третья" --note mouse="Четвёртая")

fresh() { # чистое начало: без тегов, релизов и журнала, HEAD на базе
  local t
  rm -rf "$FAKE/events.log" "$FAKE"/barrier-* "$FAKE/releases"
  : > "$FAKE/events.log"
  for t in $(git -C "$FX" tag); do git -C "$FX" tag -d "$t" >/dev/null; done
  for t in $(git --git-dir="$ORIGIN" tag); do git --git-dir="$ORIGIN" update-ref -d "refs/tags/$t"; done
  git -C "$FX" reset -q --hard "$BASE"
  git -C "$FX" push -q -f origin main
}
ev() { grep -cE -- "$1" "$FAKE/events.log" || true; }
first_ev() { grep -nE -- "$1" "$FAKE/events.log" | head -1 | cut -d: -f1; }
last_ev() { grep -nE -- "$1" "$FAKE/events.log" | tail -1 | cut -d: -f1; }
fake_env=(FAKE_DIR="$FAKE" FAKE_REAL_GIT="$REAL_GIT" FAKE_ORIGIN="$ORIGIN" GH_TOKEN=)
# --dry-run, без терминала. Вывод в файл $1.
dry() { # файл, переменные...
  local f="$1"; shift
  LAST=0
  (cd "$FX" && PATH="$OUT/bin:$PATH" TMPDIR="$OUT" env "${fake_env[@]}" "$@" scripts/release-all.sh "${ARGS[@]}" </dev/null >"$f" 2>&1) || LAST=$?
}
# --publish с настоящим терминалом: версия уходит, когда скрипт её спросил. Набранное заранее пропало бы при сборке.
cat > "$FAKE/pty-run.py" <<'PTY'
import os, pty, sys
typed, out, *cmd = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
seen, sent = b"", False
with open(out, "wb") as f:
    while True:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        f.write(data)
        f.flush()
        if not sent:
            seen += data
            if "Напиши".encode() in seen and seen.endswith(b": "):
                os.write(fd, (typed + "\n").encode())
                sent = True
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PTY
publish() { # файл, что напечатать, переменные...
  local f="$1" typed="$2"; shift 2
  LAST=0
  (cd "$FX" && PATH="$OUT/bin:$PATH" TMPDIR="$OUT" /usr/bin/python3 -I "$FAKE/pty-run.py" "$typed" "$f" \
    env "${fake_env[@]}" "$@" scripts/release-all.sh --publish "${ARGS[@]}") || LAST=$?
}
# Сумма в каталоге совпадает с архивом на подставном релизе: повторный запуск не должен записать сумму своей пересборки.
catalog_matches_assets() {
  git -C "$FX" show HEAD:Catalog/catalog.json | python3 -I -c '
import hashlib, json, sys
apps = json.load(sys.stdin)["apps"]
if not apps: sys.exit(1)
for a in apps:
    tag = "%s-v%s" % (a["id"], a["version"])
    if hashlib.sha256(open(sys.argv[1] + "/" + tag + ".zip", "rb").read()).hexdigest() != a["sha256"]:
        sys.exit("сумма %s не совпала" % tag)' "$FAKE/releases"
}
commits_since_base() { git -C "$FX" rev-list --count "$BASE..HEAD"; }

# Сборки разом
fresh
ARGS=(--only awake,fans,load,mouse "${ALL_NOTES[@]}")
dry "$OUT/par.out" FAKE_BUILD_BARRIER=4
check "параллельный --dry-run проходит" test "$LAST" -eq 0
check "все 4 сборки шли одновременно" test "$(ev 'barrier-met build')" -eq 4
check "ни одна сборка не ждала впустую" test "$(ev 'barrier-timeout')" -eq 0
check "unlock-signing вызван один раз" test "$(ev '^unlock$')" -eq 1
check "unlock-signing раньше первой сборки" test "$(first_ev '^unlock$')" -lt "$(first_ev 'build-start')"
check "сборка не открывает связку сама и ограничена по -j" test "$(ev 'build-env .* unlocked=1 swift=[1-9]')" -eq 4
par_work="$(grep -F 'рабочая папка: ' "$OUT/par.out" | head -1)"; par_work="${par_work#*: }"
check "лог каждой сборки отдельно" has "$par_work/logs/fans.log" "лог сборки fans"
check "в чужом логе чужой сборки нет" lacks "$par_work/logs/fans.log" "лог сборки awake"
check "в каталоге порядок утилит, а не порядок окончания" has "$OUT/par.out" "(в нём: awake 1.0.0, fans 1.0.0, load 1.0.0, mouse 1.0.0)"

# Предел одновременных сборок
fresh
dry "$OUT/limit.out" RELEASE_ALL_JOBS=2 FAKE_BUILD_SLEEP=0.5
peak="$(LC_ALL=C awk '/^build-start/{n++; if(n>m)m=n} /^build-end/{n--} END{print m+0}' "$FAKE/events.log")"
check "предел RELEASE_ALL_JOBS=2 держится и заполняется (пик $peak)" test "$peak" -eq 2
fresh
dry "$OUT/badjobs.out" RELEASE_ALL_JOBS=abc
check "RELEASE_ALL_JOBS не число: отказ" test "$LAST" -ne 0 -a "$(ev build-start)" -eq 0

# Красная сборка или проверка: ничего не выложено, начатые доходят, новые не начинаются
fresh
ARGS=(--only awake,fans,load,mouse "${ALL_NOTES[@]}")
publish "$OUT/red.out" "$HUB" RELEASE_ALL_JOBS=1 FAKE_RED_BUILD=fans
check "красная сборка: код не ноль" test "$LAST" = 1
check "красная сборка: виден лог и причина" has "$OUT/red.out" "красная сборка fans"
check "красная сборка: новые не начинаются" test "$(ev 'build-start load')" -eq 0
check "красная сборка: ни тега, ни релиза, ни каталога" test "$(ev 'create-start|git-|hub-release')" -eq 0
fresh
publish "$OUT/red2.out" "$HUB" FAKE_BAD_SIGN=1
check "неверная подпись при параллельной сборке: ни тега, ни релиза" test "$LAST" = 1 -a "$(ev 'create-start|git-|hub-release')" -eq 0
check "неверная подпись: видна причина" has "$OUT/red2.out" "подпись не"
fresh
publish "$OUT/wrong.out" "9.9.9"
check "версия не та: ничего не выложено" test "$LAST" = 1 -a "$(ev 'create-start|git-|hub-release')" -eq 0

# Полный выпуск: релизы и теги разом, каталог после всех, центр последним
fresh
ARGS=(--only awake,fans,load,mouse "${ALL_NOTES[@]}")
publish "$OUT/pub.out" "$HUB" FAKE_GH_BARRIER=4 FAKE_PUSH_BARRIER=4
check "выпуск дошёл" test "$LAST" = 0
check "все 4 релиза шли одновременно" test "$(ev 'barrier-met create')" -eq 4
check "все 4 пуша тегов шли одновременно" test "$(ev 'barrier-met push')" -eq 4
check "никто не ждал впустую" test "$(ev 'barrier-timeout')" -eq 0
check "каталог после всех релизов" test "$(last_ev 'create-end')" -lt "$(first_ev 'git-commit')"
check "пуш каталога после его коммита" test "$(first_ev 'git-commit')" -lt "$(first_ev 'git-push-main')"
check "центр последним" test "$(first_ev 'hub-release')" -gt "$(first_ev 'git-push-main')" -a "$(last_ev '.')" -eq "$(first_ev 'hub-release')"
check "один коммит каталога" test "$(commits_since_base)" -eq 1 -a "$(ev 'git-commit')" -eq 1
check "теги в origin" test "$(git --git-dir="$ORIGIN" tag | wc -l)" -eq 4
check "суммы в каталоге от выложенных архивов" catalog_matches_assets

# Сбой одного релиза: каталога нет, центра нет, понятно, что дальше
fresh
publish "$OUT/one.out" "$HUB" FAKE_GH_RED=fans-v1.0.0
check "сбой релиза: код не ноль" test "$LAST" = 1
check "сбой релиза: каталога нет" test "$(ev 'git-commit|git-push-main')" -eq 0 -a "$(git --git-dir="$ORIGIN" rev-parse main)" = "$BASE"
check "сбой релиза: центра нет" test "$(ev 'hub-release')" -eq 0
check "сбой релиза: дерево чистое" test -z "$(git -C "$FX" status --porcelain)"
check "сбой релиза: напечатано сорвавшееся" has "$OUT/one.out" "сорвалось: fans-v1.0.0"
check "сбой релиза: напечатано выложенное" has "$OUT/one.out" "выложено: awake-v1.0.0"
check "сбой релиза: напечатана команда" has "$OUT/one.out" "--publish --only awake,fans,load,mouse"

# Повтор той же командой: готовое не повторяется, сумма от выложенного архива, а не от пересборки
: > "$FAKE/events.log"
publish "$OUT/again.out" "$HUB"
check "повтор дошёл" test "$LAST" = 0
check "повтор: выложенное не собирается заново" test "$(ev 'build-start')" -eq 1 -a "$(ev 'build-start fans')" -eq 1
check "повтор: архивы выложенных скачаны" test "$(ev 'gh release download')" -eq 3
check "повтор: дублей релизов нет" test "$(ev 'create-dup')" -eq 0 -a "$(ev 'create-start')" -eq 1
check "повтор: теги не создаются заново" test "$(ev 'git-tag')" -eq 0
check "повтор: тег не пушится заново" test "$(ev 'git-push-tag')" -eq 0
check "повтор: один коммит каталога и центр" test "$(commits_since_base)" -eq 1 -a "$(ev 'hub-release')" -eq 1
check "повтор: суммы в каталоге от выложенных архивов" catalog_matches_assets
check "повтор: gh всегда с токеном выпуска, и на чтении" test "$(ev 'gh-no-token')" -eq 0

# Сбой между тегом и пушем: тег только здесь, он не создаётся заново, а пушится
fresh
git -C "$FX" tag awake-v1.0.0
publish "$OUT/localtag.out" "$HUB"
check "тег только локально: выпуск дошёл" test "$LAST" = 0
check "тег только локально: не создаётся заново" test "$(ev 'git-tag awake')" -eq 0 -a "$(ev 'git-push-tag awake')" -eq 1

# Проверки идут и по архиву с релиза: ненастоящий не попадёт в каталог
fresh
publish "$OUT/one.out" "$HUB" FAKE_GH_RED=fans-v1.0.0
: > "$FAKE/events.log"
publish "$OUT/badasset.out" "$HUB" FAKE_BAD_SIGN=1
check "архив с релиза с неверной подписью: стоп до каталога" test "$LAST" = 1 -a "$(ev 'git-commit')" -eq 0 -a "$(commits_since_base)" -eq 0

# Сбой на центре: повтор той же командой идёт сразу к центру, заметки его не останавливают
fresh
publish "$OUT/hubred.out" "$HUB" FAKE_HUB_RED=1
check "сбой центра: каталог уже вышел" test "$LAST" = 1 -a "$(git --git-dir="$ORIGIN" rev-parse main)" = "$(git -C "$FX" rev-parse HEAD)" -a "$(commits_since_base)" -eq 1
check "сбой центра: напечатан упавший шаг" has "$OUT/hubred.out" "ОСТАНОВЛЕНО на шаге: scripts/release.sh"
: > "$FAKE/events.log"
publish "$OUT/hubagain.out" "$HUB"
check "повтор после центра: дошёл только центр" test "$LAST" = 0 -a "$(ev 'hub-release')" -eq 1 -a "$(ev 'build-start|create-start|git-commit')" -eq 0
ARGS=(--only awake,fans,load,mouse --note awake="Другая" --note fans="Вторая" --note load="Третья" --note mouse="Четвёртая")
expect_refused_fake() { # описание, шаблон
  dry "$OUT/ref.out"
  if [ "$LAST" -ne 0 ] && grep -qF -- "$2" "$OUT/ref.out"; then pass "$1"; else bad "$1 (код $LAST): $(cat "$OUT/ref.out")"; fi
}
expect_refused_fake "другая заметка к утилите из каталога: отказ, как раньше" "такой утилиты нет"
ARGS=(--only awake,fans,load,mouse "${ALL_NOTES[@]}")

# Отказы по состоянию GitHub и тегов
fresh
git -C "$FX" tag awake-v1.0.0 "$BASE"
git -C "$FX" push -q origin awake-v1.0.0
FAKE_GH_DOWN_ENV=FAKE_GH_DOWN=1
dry "$OUT/down.out" "$FAKE_GH_DOWN_ENV"
check "gh не ответил про существующий тег: стоп, а не «релиза нет»" test "$LAST" -ne 0 -a "$(ev 'build-start')" -eq 0
check "gh не ответил: видна причина" has "$OUT/down.out" "gh не ответил"
mkdir -p "$FAKE/releases"
echo "true Awake.zip" > "$FAKE/releases/awake-v1.0.0.state"
expect_refused_fake "черновик релиза: отказ с подсказкой" "черновик"
echo "false " > "$FAKE/releases/awake-v1.0.0.state"
expect_refused_fake "релиз без архива: отказ с подсказкой" "gh release delete awake-v1.0.0"
check "после отказов ничего не собиралось" test "$(ev 'build-start')" -eq 0
fresh
git -C "$FX" commit -q --allow-empty -m "раньше тега"
git -C "$FX" tag awake-v1.0.0
git -C "$FX" commit -q --allow-empty -m "позже тега"
git -C "$FX" push -q origin main
expect_refused_fake "тег на другом коммите: разобраться вручную" "разберись вручную"
fresh
git -C "$FX" tag "v$HUB" "$BASE"
git -C "$FX" push -q origin "v$HUB"
mkdir -p "$FAKE/releases"
echo "false Utilitumus.zip" > "$FAKE/releases/v$HUB.state"
expect_refused_fake "центр уже выпущен: отказ и подсказка" "--utilities-only"
rm "$FAKE/releases/v$HUB.state"
: > "$FAKE/events.log"
dry "$OUT/hubtag.out"
check "тег центра без релиза: release.sh продолжит" test "$LAST" -eq 0 -a "$(grep -c '^+ scripts/release.sh' "$OUT/hubtag.out")" -eq 1

# --utilities-only: тег центра уже есть, каталог один, центр не трогаем
ARGS=(--utilities-only "${ALL_NOTES[@]}")
: > "$FAKE/events.log"
dry "$OUT/uo-dry.out" FAKE_BUILD_BARRIER=4
check "--utilities-only: --dry-run при выпущенном центре" test "$LAST" -eq 0 -a "$(ev 'barrier-met build')" -eq 4
check "--utilities-only: в плане нет центра" lacks "$OUT/uo-dry.out" "scripts/release.sh"
check "--utilities-only: план заканчивается пушем каталога" test "$(grep '^+ ' "$OUT/uo-dry.out" | tail -1)" = "+ git push -q origin HEAD:main"
rm -f "$FAKE/releases/v$HUB.state"
# Версии разные и сравниваются как версии: 1.10.0 больше 1.9.0.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.10.0" "$FX/Sources/Apps/Fans/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.9.0" "$FX/Sources/Apps/Mouse/Info.plist"
git -C "$FX" commit -q -am "разные версии"
git -C "$FX" push -q origin main
git -C "$FX" tag -f "v$HUB" >/dev/null
git -C "$FX" push -q -f origin "v$HUB"
: > "$FAKE/events.log"
publish "$OUT/uo-wrong.out" "$HUB"
check "--utilities-only: версия центра по привычке не проходит" test "$LAST" = 1 -a "$(ev 'create-start|git-commit')" -eq 0
publish "$OUT/uo-wrong2.out" "1.9.0"
check "--utilities-only: меньшая версия не проходит" test "$LAST" = 1 -a "$(ev 'create-start|git-commit')" -eq 0
: > "$FAKE/events.log"
before_uo="$(git -C "$FX" rev-parse HEAD)"
publish "$OUT/uo.out" "1.10.0" FAKE_GH_BARRIER=4
check "--utilities-only: выпуск дошёл" test "$LAST" = 0
check "--utilities-only: релизы разом" test "$(ev 'barrier-met create')" -eq 4
check "--utilities-only: центр не трогали" test "$(ev 'hub-release')" -eq 0
check "--utilities-only: один коммит каталога после всех релизов" test "$(git -C "$FX" rev-list --count "$before_uo..HEAD")" -eq 1 -a "$(last_ev 'create-end')" -lt "$(first_ev 'git-commit')"
check "--utilities-only: каталог в origin" test "$(git --git-dir="$ORIGIN" rev-parse main)" = "$(git -C "$FX" rev-parse HEAD)"
check "--utilities-only: суммы от выложенных архивов" catalog_matches_assets
dry "$OUT/uo-none.out"
check "--utilities-only: нечего выпускать — выход без сборок" test "$LAST" -eq 0 -a "$(grep -c 'Нечего выпускать' "$OUT/uo-none.out")" -eq 1

# Отмена: начатые задания снимаются, а не доходят в фоне
fresh
ARGS=(--only awake,fans,load,mouse "${ALL_NOTES[@]}")
(cd "$FX" && exec env PATH="$OUT/bin:$PATH" TMPDIR="$OUT" "${fake_env[@]}" FAKE_BUILD_SLEEP=87 scripts/release-all.sh "${ARGS[@]}" </dev/null >"$OUT/int.out" 2>&1) &
int_pid=$!
n=0
while [ "$(ev build-start)" -lt 4 ] && [ "$n" -lt 100 ]; do n=$((n + 1)); sleep 0.1; done
kill -TERM "$int_pid"
int_rc=0; wait "$int_pid" || int_rc=$?
sleep 0.3
check "отмена: код 130" test "$int_rc" -eq 130
check "отмена: подставных сборок не осталось" test -z "$(pgrep -f 'sleep 87' || true)"
check "отмена: напечатано, как продолжить" has "$OUT/int.out" "Продолжить:"

# Настоящий scripts/build-app.sh: что он делает с переменными общего выпуска. swiftc, codesign и security подставные.
BA="$OUT/ba"
mkdir -p "$BA/scripts" "$BA/Sources/Kit" "$BA/Sources/Apps/Awake" "$BA/Sources/Modules/Awake" "$OUT/ba-bin"
cp scripts/build-app.sh scripts/check-no-seam.sh "$BA/scripts/"
cp install.sh Info.plist "$BA/"
cp Sources/Kit/KitSigning.swift "$BA/Sources/Kit/"
cp "$FX/Sources/Apps/Awake/Info.plist" "$BA/Sources/Apps/Awake/Info.plist"
printf '{}\n' > "$BA/Sources/Apps/Awake/manifest.json"
printf '#!/bin/bash\necho unlock >> "%s/ba.log"\n' "$OUT" > "$BA/scripts/unlock-signing.sh"
printf '#!/bin/bash\necho "swiftc $*" >> "%s/ba.log"\n' "$OUT" > "$OUT/ba-bin/swiftc"
printf '#!/bin/bash\nexit 0\n' > "$OUT/ba-bin/codesign"
printf '#!/bin/bash\nexit 0\n' > "$OUT/ba-bin/security"
chmod +x "$BA/scripts/"*.sh "$OUT/ba-bin/"*
ba_run() { (cd "$BA" && env PATH="$OUT/ba-bin:$PATH" "$@" scripts/build-app.sh awake Awake 1.0.0 "$OUT/ba-out" >"$OUT/ba.out" 2>&1); }
: > "$OUT/ba.log"
check "build-app без переменных проходит" ba_run env
check "build-app сам открывает связку" test "$(grep -c '^unlock$' "$OUT/ba.log")" -eq 1
check "build-app без переменной: -j нет, флаги прежние" test "$(grep -c -e ' -j[0-9]' "$OUT/ba.log")" -eq 0
: > "$OUT/ba.log"
check "build-app в общем выпуске проходит" ba_run env UTILITUMUS_SIGNING_UNLOCKED=1 UTILITUMUS_SWIFT_JOBS=2
check "build-app в общем выпуске: связку не трогает" test "$(grep -c '^unlock$' "$OUT/ba.log")" -eq 0
check "build-app в общем выпуске: -O и -j2" has "$OUT/ba.log" "swiftc -O -j2 "
if ba_run env UTILITUMUS_SWIFT_JOBS=x; then bad "UTILITUMUS_SWIFT_JOBS не число: отказ"; else pass "UTILITUMUS_SWIFT_JOBS не число: отказ"; fi

[ "$fails" -eq 0 ] && echo "Все проверки прошли" || { echo "Провалов: $fails"; exit 1; }
