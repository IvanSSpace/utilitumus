#!/bin/bash
# Общий выпуск, только --dry-run и отказы: подставные репозиторий с локальным origin, gh, codesign и сборка.
# gh при вызове проваливает проверку, ничего не пушится в настоящий репозиторий, настоящий каталог не трогается.
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
mkdir -p "$FX/scripts" "$FX/Sources/Kit" "$FX/Resources" "$FX/Catalog" "$FX/Sources/Apps/Awake" "$FX/Sources/Apps/Fans"
cp scripts/release-all.sh "$FX/scripts/"
cp Sources/Kit/KitSigning.swift "$FX/Sources/Kit/"
cp Info.plist "$FX/Info.plist"
HUB="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
EPOCH="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
printf '[{"version":"%s","items":[{"icon":"x","text":"Проверка"}]}]\n' "$HUB" > "$FX/Resources/WhatsNew.json"
printf '{"schema":1,"apps":[]}\n' > "$FX/Catalog/catalog.json"
for name in Awake Fans; do
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.0" -c "Add :UtilitumusSecurityEpoch string $EPOCH" \
    "$FX/Sources/Apps/$name/Info.plist" >/dev/null 2>&1 || {
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0.0</string></dict></plist>' > "$FX/Sources/Apps/$name/Info.plist"
  }
done
printf '{}\n' > "$FX/Sources/Apps/Awake/manifest.json"
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
ARGS=(--note awake="Первая" --note fans="Вторая")
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

expect_refused() { # описание, шаблон в выводе, переменные окружения...; ARGS заданы заранее
  local what="$1" pattern="$2" output st=0
  shift 2
  output="$(run env "$@")" || st=$?
  if [ "$st" -ne 0 ] && grep -qF -- "$pattern" <<<"$output"; then pass "$what"; else bad "$what (код $st): $output"; fi
}
ARGS=(--note awake="Первая")
expect_refused "нет заметки: отказ" "Нет заметок для fans"
ARGS=(--note awake="Первая" --note fans="Вторая")
expect_refused "помощник не собран: отказ" "нет помощника" FAKE_NO_HELPER=1
expect_refused "нет метки выпуска: отказ" "UtilitumusSecurityEpoch" FAKE_NO_EPOCH=1
expect_refused "подпись не та: отказ" "подпись не" FAKE_BAD_SIGN=1
ARGS=(--note nosuch="Вторая")
expect_refused "заметка к несуществующей утилите: отказ" "такой утилиты нет"
ARGS=(--publish --note awake="Первая" --note fans="Вторая")
expect_refused "--publish без терминала: отказ, ничего не выложено" "нужен терминал"
ARGS=(--publish --dry-run --note awake="Первая" --note fans="Вторая")
expect_refused "--publish вместе с --dry-run: отказ" "вместе нельзя"
ARGS=(--typo)
expect_refused "незнакомый флаг: отказ" "Неизвестный аргумент"
ARGS=(--note awake="Первая" --note fans="Вторая")
echo dirty > "$FX/dirty.txt"
expect_refused "грязное дерево: отказ" "незакоммиченные"
rm "$FX/dirty.txt"
git -C "$FX" -c user.name=t -c user.email=t@t commit -q --allow-empty -m ahead
expect_refused "HEAD не совпадает с origin/main: отказ" "не совпадает с GitHub"
git -C "$FX" reset -q --hard "$BEFORE"
printf '[]\n' > "$FX/Resources/WhatsNew.json"
git -C "$FX" -c user.name=t -c user.email=t@t commit -q -am "no notes"
git -C "$FX" push -q origin main
expect_refused "нет записи WhatsNew для центра: отказ" "WhatsNew"
check "gh не вызывался и после отказов" test ! -s "$GH_LOG"

[ "$fails" -eq 0 ] && echo "Все проверки прошли" || { echo "Провалов: $fails"; exit 1; }
