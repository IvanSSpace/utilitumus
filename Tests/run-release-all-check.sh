#!/bin/bash
# Общий выпуск, только --dry-run и отказы: подставные репозиторий с локальным origin, gh, codesign и сборка.
# gh при вызове проваливает проверку, ничего не пушится в настоящий репозиторий, настоящий каталог не трогается.
# Папка: RELEASE_ALL_CHECK_DIR, иначе $TMPDIR/release-all-check.
CHECK_LIMIT=3600 source "$(dirname "$0")/lib/check-limit.sh"
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
name="$2"; version="$3"; app="$4/$name.app"
mkdir -p "$app/Contents/MacOS"
epoch="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -z "${FAKE_NO_EPOCH:-}" ] || epoch=""
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>UtilitumusSecurityEpoch</key><string>$epoch</string>
</dict></plist>
PLIST
[ -n "${FAKE_NO_HELPER:-}" ] || touch "$app/Contents/MacOS/utilitumus-fan"
FAKE
chmod +x "$FX/scripts/build-app.sh" "$FX/scripts/release-all.sh"
printf '#!/bin/bash\necho "release.sh $*" >> "%s"\nexit 99\n' "$GH_LOG" > "$FX/scripts/release.sh"
chmod +x "$FX/scripts/release.sh"

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

[ "$fails" -eq 0 ] && echo "Все проверки прошли" || { echo "Провалов: $fails"; exit 1; }
