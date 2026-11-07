#!/bin/bash
# Две вещи, ради которых разработка идёт быстро, и обе опасны тем, что могут задеть настоящее или подсунуть старое:
#   1. scripts/dev.sh --alone <id>: копия отдельна от настоящей утилиты, в выпуск не годится, окно за экраном открывается той
#      командой, которую печатает dev.sh, настоящие настройки и службы не меняются. Настоящие утилиты могут работать рядом.
#   2. готовый бандл стенда (UTILITUMUS_BUILD_CACHE): любой изменённый вход пересобирает, чужой и испорченный бандл не берётся.
#      На подставном репозитории с крошечной утилитой: правки настоящих исходников проверка не делает.
# Папка: DEV_ALONE_CHECK_DIR, иначе $TMPDIR/dev-alone-check.noindex; кэш дев-копий живёт в ней между запусками (dev/).
# Какие утилиты собирать: DEV_ALONE_CHECK_IDS, пусто — только часть 2. Окна только за экраном, снимки в png/. Нужен сертификат «Utilitumus Signing» (часть 2).
source "$(dirname "$0")/lib/check-limit.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. Tests/lib/incremental.sh
source Tests/stand-snapshot.sh

OUT="${DEV_ALONE_CHECK_DIR:-${TMPDIR:-/tmp}/dev-alone-check.noindex}"
RUN="$OUT/run"
DEV="$OUT/dev"
IDS="${DEV_ALONE_CHECK_IDS-mouse fans voice browser}"
failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$3», получили «$2»"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: нет «$3» в: $2"; fi; }

PIDS=()
SUITES=()
HOMES=()
cleanup() {
  local pid suite home
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  for suite in ${SUITES[@]+"${SUITES[@]}"}; do
    defaults delete "$suite" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$suite.plist"
  done
  # Только подставные дома: dev.sh кладёт их во временную папку.
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    case "$home" in "${TMPDIR:-/tmp}"*/utilitumus-dev-alone/*/home) rm -rf -- "$home" ;; esac
  done
  return 0
}
trap 'exit 1' HUP INT TERM
trap cleanup EXIT

rm -rf "$RUN"
mkdir -p "$RUN/png" "$DEV"
RUN="$(cd "$RUN" && pwd -P)"
DEV="$(cd "$DEV" && pwd -P)"
export UTILITUMUS_DEV_DIR="$DEV"
# Настройки, которые дев-копия не должна менять. Только чтение. Настоящие утилиты могут менять их сами: см. проверку ниже.
real_defaults() { defaults export local.utilitumus - 2>/dev/null | shasum -a 256; }
real_labels() { launchctl list 2>/dev/null | awk '$3 ~ /^local\.utilitumus\.app\.|^local\.utilitumus$/ { print $1, $3 }' | LC_ALL=C sort; }

echo "== dev.sh --alone: отказы"
scripts/dev.sh --alone > "$RUN/refuse.log" 2>&1 && bad "без id сборка пошла" || ok "без id: отказ"
scripts/dev.sh --alone mouse fans > "$RUN/refuse.log" 2>&1 && bad "два id: сборка пошла" || ok "два id: отказ"
scripts/dev.sh --alone nosuch > "$RUN/refuse.log" 2>&1 && bad "неизвестный id: сборка пошла" || ok "неизвестный id: отказ"

stand_snapshot_take "$RUN/before.txt"
DEFAULTS_BEFORE="$(real_defaults)"
LABELS_BEFORE="$(real_labels)"

for id in $IDS; do
  echo "== $id"
  name="$(printf '%s' "${id:0:1}" | tr '[:lower:]' '[:upper:]')${id:1}"
  scripts/dev.sh --alone "$id" > "$RUN/$id.out" 2>&1 || { sed 's/^/     /' "$RUN/$id.out"; bad "$id: dev.sh --alone упал"; continue; }
  line="$(sed -n 's/^  \(env .*\)$/\1/p' "$RUN/$id.out")"
  [ -n "$line" ] || { bad "$id: dev.sh не напечатал команду запуска"; continue; }
  suite="$(sed -n 's/.*KIT_TEST_SUITE=\([^ ]*\).*/\1/p' <<<"$line")"
  home="$(sed -n 's/.*CFFIXED_USER_HOME=\([^ ]*\).*/\1/p' <<<"$line")"
  exe="${line##* }"
  app="${exe%/Contents/MacOS/*}"
  SUITES+=("$suite"); HOMES+=("$home")
  plist="$app/Contents/Info.plist"
  same "свой идентификатор в Info.plist" "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" "local.utilitumus.app.$id.dev"
  same "метка выпуска стенда" "$(plutil -extract UtilitumusSecurityEpoch raw -o - "$plist")" "test.1"
  same "отметка сборки для разработки" "$(plutil -extract UtilitumusDevBuild raw -o - "$plist")" "true"
  signature="$(codesign -dvv "$app" 2>&1)"
  has "подпись ad-hoc, сертификата автора нет" "$signature" "Signature=adhoc"
  has "identifier подписи свой" "$signature" "Identifier=local.utilitumus.app.$id.dev"
  same "помощников в бандле нет" "$(find "$app/Contents/MacOS" -type f | wc -l | tr -d ' ')/$(find "$app/Contents" -type d -name Helpers | wc -l | tr -d ' ')" "1/0"
  # Шов и отметка, каждое по отдельности: снятие одного не должно открыть выпуск.
  if nogo="$(scripts/check-no-seam.sh "$app" 2>&1)"; then bad "check-no-seam пропустил дев-копию"; else
    has "check-no-seam: отказ из-за отметки" "$nogo" "сборка для разработки"
    has "check-no-seam: отказ из-за следов шва" "$nogo" "Contents/MacOS/$name"
  fi
  case "$suite" in local.utilitumus.test.dev.*) ok "свой домен настроек: $suite" ;; *) bad "домен настроек: $suite" ;; esac
  case "$home" in /Users/* | /Applications/* | /Library/*) bad "подставной дом не во временной папке: $home" ;; *) ok "дом во временной папке" ;; esac

  # Окно за экраном, снимок той же командой, что видит человек.
  defaults write "$suite" Test.PNGPath "$RUN/png/$id.png"
  log="$RUN/$id.log"
  ( exec env KIT_DEV_ALONE_OFFSCREEN=1 ${line#env } ) > "$log" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  for _ in $(seq 1 300); do grep -q "окно показано" "$log" && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  shown="$(grep "окно показано" "$log" | head -1)"
  case "$shown" in *"x=-10000"*) ok "окно открылось само, за экраном: $shown" ;; *) bad "$id: окна нет: $(tail -3 "$log")" ;; esac
  # Первая отрисовка идёт после показа.
  sleep 1
  kill -USR2 "$pid" 2>/dev/null
  for _ in $(seq 1 50); do [ -s "$RUN/png/$id.png" ] && break; sleep 0.1; done
  size="$(/usr/bin/stat -f %z "$RUN/png/$id.png" 2>/dev/null || echo 0)"
  # Пустое окно такого размера занимает единицы килобайт.
  if [ "$size" -gt 10000 ]; then ok "экран нарисован: снимок $size байт"; else bad "$id: снимок $size байт"; fi
  same "модуль работает на своём домене" "$(defaults read "$suite" "App.$id.dev.Enabled" 2>/dev/null)" "1"
  if defaults read local.utilitumus "App.$id.dev.Enabled" > /dev/null 2>&1; then bad "ключ дев-копии в настоящих настройках"; else ok "в настоящих настройках ключа дев-копии нет"; fi
  if launchctl list 2>/dev/null | grep -qE "local\.utilitumus\.[a-z.]*$id\.dev"; then bad "у дев-копии служба launchd"; else ok "служб launchd у копии нет"; fi
  # До службы дело и не доходит: подставной установщик говорит «нет службы», поэтому такт ничего не шлёт (FanHelperInstaller).
  # Вторая защита — отказ в самом клиенте, он есть только в сборке со швом: здесь видно, что шов в бинарнике.
  if [ "$id" = fans ]; then
    kill -USR1 "$pid" 2>/dev/null
    sleep 1
    if LC_ALL=C grep -qaF "XPC настоящей службы вентиляторов" "$exe"; then ok "Вентиляторы: клиент службы отказывает"; else bad "Вентиляторы: нет отказа в клиенте службы"; fi
  fi
  if kill -0 "$pid" 2>/dev/null; then ok "копия жива до конца проверки"; else bad "$id: копия упала: $(tail -3 "$log")"; fi
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
done

first="${IDS%% *}"
if [ -n "$first" ]; then
  echo "== запуск мимо команды dev.sh"
  line="$(sed -n 's/^  \(env .*\)$/\1/p' "$RUN/$first.out")"
  exe="${line##* }"
  # Без подставного дома копия выходит раньше окна и раньше работы модуля.
  env -u KIT_TEST_SUITE -u CFFIXED_USER_HOME "$exe" > "$RUN/bare.log" 2>&1; same "без переменных: код 2" "$?" "2"
  has "без переменных: объяснение" "$(cat "$RUN/bare.log")" "scripts/dev.sh --alone"
  env KIT_TEST_SUITE=local.utilitumus.test.kit CFFIXED_USER_HOME="$RUN/h" HOME="$RUN/h" "$exe" > /dev/null 2>&1; same "общий домен стендов: код 2" "$?" "2"
  env KIT_TEST_SUITE=local.utilitumus.test.dev.x CFFIXED_USER_HOME="$HOME" "$exe" > /dev/null 2>&1; same "настоящий дом: код 2" "$?" "2"

  echo "== инкрементальность"
  copy="$(sed -n 's#.*/alone/\([^/]*\)/app/.*#\1#p' <<<"$line")"
  objects_before="$(find "$DEV/alone/$copy/cache/$first" -name '*.o' -exec /usr/bin/stat -f '%N %m' {} + | shasum)"
  scripts/dev.sh --alone "$first" > "$RUN/again.out" 2>&1 || bad "повторная сборка упала"
  same "пустая пересборка не трогает объекты" "$(find "$DEV/alone/$copy/cache/$first" -name '*.o' -exec /usr/bin/stat -f '%N %m' {} + | shasum)" "$objects_before"
  echo "     $(head -1 "$RUN/again.out")"
  codesign --verify --deep --strict "${exe%/Contents/MacOS/*}" 2>/dev/null && ok "бандл после пересборки цел" || bad "подпись бандла после пересборки"
  same "повторная сборка: те же домен и команда" "$(sed -n 's/^  \(env .*\)$/\1/p' "$RUN/again.out")" "$line"
fi

# Кэш живёт по времени файлов: правка экрана обязана дойти до бинарника, иначе человек смотрит на старый экран.
if [ -n "$first" ]; then
  echo "== правка экрана в копии проекта"
  EDIT="$RUN/edit-copy"
  mkdir -p "$EDIT"
  tar cf - Sources scripts Info.plist | (cd "$EDIT" && tar xf -)
  ( cd "$EDIT" && scripts/dev.sh --alone mouse ) > "$RUN/edit1.out" 2>&1 || bad "копия: первая сборка"
  edit_line="$(sed -n 's/^  \(env .*\)$/\1/p' "$RUN/edit1.out")"
  edit_exe="${edit_line##* }"
  if LC_ALL=C grep -qaF "dev-alone-probe-edit" "$edit_exe"; then bad "метка правки уже в бинарнике"; else ok "до правки метки нет"; fi
  echo 'let devAloneProbeEdit = "dev-alone-probe-edit"' >> "$EDIT/Sources/Modules/Mouse/UI/MouseView.swift"
  ( cd "$EDIT" && scripts/dev.sh --alone mouse ) > "$RUN/edit2.out" 2>&1 || bad "копия: сборка после правки"
  if LC_ALL=C grep -qaF "dev-alone-probe-edit" "$edit_exe"; then ok "правка дошла: $(head -1 "$RUN/edit2.out" | cut -d, -f1)"; else bad "правка файла экрана не дошла до бинарника"; fi
  edit_suite="$(sed -n 's/.*KIT_TEST_SUITE=\([^ ]*\).*/\1/p' <<<"$edit_line")"
  [ "$edit_suite" != "${suite:-}" ] && ok "у другой копии проекта свой домен настроек" || bad "домен настроек общий у копий проекта"
fi

echo "== настоящее"
stand_snapshot_compare "$RUN/before.txt" || failures=$((failures + 1))
if [ "$(real_defaults)" = "$DEFAULTS_BEFORE" ]; then ok "настройки local.utilitumus те же"
elif stand_real_app_running; then echo "ПРИМЕЧАНИЕ: настройки local.utilitumus изменились, настоящие утилиты запущены и пишут их сами; дев-копия пишет только в свой домен, см. выше"
else bad "настройки local.utilitumus изменились, а настоящих утилит нет"; fi
same "настоящие службы и их процессы те же" "$(real_labels)" "$LABELS_BEFORE"
for found in "$HOME"/Library/Preferences/local.utilitumus.app.*.dev.plist; do
  [ ! -e "$found" ] || bad "домен дев-копии в настоящем доме: $found"
done
for place in /Applications/Utilitumus*; do
  [ ! -e "$place" ] || case "$(/usr/bin/stat -f %N "$place")" in *.dev*) bad "дев-копия в /Applications: $place" ;; esac
done

# ------------------------------------------------------------------------------------------------------------------------------
echo "== готовый бандл: подставной репозиторий"
unset INCREMENTAL_OFF
export INCREMENTAL_ROOT="$RUN/inc"
SIGN_NAME="Utilitumus Signing"
scripts/unlock-signing.sh
security find-identity -p codesigning | grep -q "\"$SIGN_NAME\"" || { echo "ПРОВАЛ: нет сертификата «${SIGN_NAME}»"; exit 1; }
FX="$RUN/repo"
B="$RUN/built"
mkdir -p "$FX/scripts" "$FX/Sources/Kit" "$FX/Sources/Apps/Probe" "$FX/Sources/Modules/Probe" "$FX/Tests/lib" "$FX/Sources/Helper" "$RUN/shim" "$B"
cp scripts/build-app.sh scripts/unlock-signing.sh scripts/check-no-seam.sh "$FX/scripts/"
cp Info.plist "$FX/"
cp Sources/Kit/KitSigning.swift "$FX/Sources/Kit/"
cp Tests/lib/incremental.sh "$FX/Tests/lib/"
echo 'print("one")' > "$FX/Sources/Apps/Probe/main.swift"
echo '{}' > "$FX/Sources/Apps/Probe/manifest.json"
echo 'print("helper")' > "$FX/Sources/Helper/main.swift"
cat > "$FX/Sources/Apps/Probe/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>UtilitumusSecurityEpoch</key><string>1</string>
</dict></plist>
EOF
PROBE="$B/Probe.app/Contents/MacOS/Probe"
CACHE="$(cd "$FX" && incremental_cache utility-test.probe --test-seam)"

# Код последней сборки в BUILD_RC, её вывод в BUILD_LOG.
build() { # [версия] [PATH]
  BUILD_LOG="$RUN/build.log"
  ( cd "$FX" && PATH="${2:-$PATH}" build_seam_utility test.probe Probe "${1:-1.2.3}" "$B" --test-seam ) > "$BUILD_LOG" 2>&1
  BUILD_RC=$?
}
from_cache() { [ "$BUILD_RC" = 0 ] && grep -q "компиляции не было" "$BUILD_LOG"; }
expect_hit() { build "${2:-}" "${3:-}"; if from_cache; then ok "$1: взят готовый"; else bad "$1: ждали готовый (код $BUILD_RC): $(tail -2 "$BUILD_LOG")"; fi; }
expect_build() { build "${2:-}" "${3:-}"; if [ "$BUILD_RC" = 0 ] && ! from_cache; then ok "$1: пересборка"; else bad "$1: ждали пересборку (код $BUILD_RC): $(tail -2 "$BUILD_LOG")"; fi; }
# Правка, пересборка, снова готовый: кэш обновился, а не сломался.
changed() { expect_build "$1"; expect_hit "$1, повтор"; }
verified() { codesign --verify --deep --strict "$B/Probe.app" 2>/dev/null; }

expect_build "первая сборка"
expect_hit "те же входы"
same "из кэша та программа" "$("$PROBE")" "one"
verified && ok "из кэша подпись верна" || bad "из кэша подпись не сходится"

echo 'print("two")' > "$FX/Sources/Apps/Probe/main.swift"
changed "правка исходника утилиты"
same "после правки новая программа" "$("$PROBE")" "two"
echo '// правка' >> "$FX/Sources/Kit/KitSigning.swift"; changed "правка Kit"
echo 'let added = 1' > "$FX/Sources/Kit/Added.swift"; changed "новый файл в Kit"
rm "$FX/Sources/Kit/Added.swift"; changed "файл удалён"
mkdir -p "$FX/Sources/Extra"; echo 'let extra = 1' > "$FX/Sources/Extra/extra.swift"
echo '{"sources":["Sources/Extra"]}' > "$FX/Sources/Apps/Probe/manifest.json"; changed "манифест"
echo 'let extra = 2' > "$FX/Sources/Extra/extra.swift"; changed "дополнительный исходник из манифеста"
plutil -replace NSHumanReadableCopyright -string x "$FX/Sources/Apps/Probe/Info.plist"; changed "Info.plist утилиты"
plutil -replace NSHumanReadableCopyright -string x "$FX/Info.plist"; changed "Info.plist центра"
echo '# правка' >> "$FX/scripts/build-app.sh"; changed "скрипт сборки"
expect_build "другая версия" 1.2.4
expect_build "другая версия обратно"
cat > "$FX/Sources/Apps/Probe/manifest.json" <<EOF
{"helpers":[{"kind":"swift-tool","path":"Contents/MacOS/helper","identifier":"local.utilitumus.helper","sources":["Sources/Helper/main.swift"]}]}
EOF
changed "помощник в манифесте"
echo 'print("helper 2")' > "$FX/Sources/Helper/main.swift"; changed "исходник помощника"
same "после правки новый помощник" "$("$B/Probe.app/Contents/MacOS/helper")" "helper 2"
echo '{"entitlements":"Sources/Apps/Probe/E.entitlements"}' > "$FX/Sources/Apps/Probe/manifest.json"
plutil -create xml1 "$FX/Sources/Apps/Probe/E.entitlements"
changed "разрешения в манифесте"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>\n' > "$FX/Sources/Apps/Probe/E.entitlements"
changed "файл разрешений"

# type -P: swiftc здесь ещё и функция из Tests/lib/incremental.sh, а подставной должен звать настоящий файл, не себя.
REAL_SWIFTC="$(type -P swiftc)"
printf '#!/bin/bash\nif [ "${1:-}" = --version ]; then echo "другой компилятор"; exit 0; fi\nexec "%s" "$@"\n' "$REAL_SWIFTC" > "$RUN/shim/swiftc"
chmod +x "$RUN/shim/swiftc"
expect_build "другой компилятор" "" "$RUN/shim:$PATH"
expect_build "компилятор обратно"
rm "$RUN/shim/swiftc"

# Другой сертификат в списке: готовый не берётся. Подпись настоящая, поэтому и свежая сборка честно не сходится с ним.
REAL_SECURITY="$(type -P security)"
printf '#!/bin/bash\n"%s" "$@" | sed -E "s/[0-9A-F]{40}/0000000000000000000000000000000000000000/"\n' "$REAL_SECURITY" > "$RUN/shim/security"
chmod +x "$RUN/shim/security"
build "" "$RUN/shim:$PATH"
if from_cache; then bad "другой сертификат: взят готовый"; else ok "другой сертификат: готовый не взят"; fi
# Сертификата нет вовсе: ad-hoc и никакого кэша, проверять нечем.
printf '#!/bin/bash\nexit 0\n' > "$RUN/shim/security"
expect_build "нет сертификата" "" "$RUN/shim:$PATH"
expect_build "нет сертификата, повтор" "" "$RUN/shim:$PATH"
rm "$RUN/shim/security"
# Сборки выше кэш не трогали: без сертификата кэша нет, а с другим подпись не сошлась раньше записи.
expect_hit "сертификат снова есть"
verified && ok "подпись снова авторская" || bad "подпись после возврата сертификата"

echo "== чужой и испорченный бандл"
printf 'x' >> "$CACHE/Probe.app/Contents/MacOS/Probe"
expect_build "испорченный в кэше"
has "о нём сказано" "$(cat "$BUILD_LOG")" "не прошёл проверку подписи"
verified && ok "после отказа подпись верна" || bad "после отказа подпись не сходится"
expect_hit "кэш снова живой"

# Настоящая подпись и те же id и метка, но другая программа: например, сборка другой ветки попала в этот кэш.
FOREIGN="$RUN/foreign"
cp -R "$FX" "$FOREIGN"
echo 'print("foreign")' > "$FOREIGN/Sources/Apps/Probe/main.swift"
( cd "$FOREIGN" && scripts/build-app.sh test.probe Probe 1.2.3 "$RUN/foreign-built" --test-seam ) > /dev/null 2>&1
rm -rf "$CACHE/Probe.app"; cp -R "$RUN/foreign-built/Probe.app" "$CACHE/Probe.app"
expect_build "чужой с верной подписью"
[ "$("$PROBE")" != foreign ] && ok "чужая программа не запущена" || bad "взята чужая программа"
expect_hit "кэш снова живой"

# Ad-hoc с поддельной записью о себе: требование подписи всё равно не сойдётся.
codesign --force --sign - --identifier local.utilitumus.app.test.probe "$CACHE/Probe.app" 2>/dev/null
FORGED="$(codesign -dvvv "$CACHE/Probe.app" 2>&1 | sed -n 's/^CDHash=//p')"
printf '%s\n%s\n' "$(sed -n 1p "$CACHE/key")" "$FORGED" > "$CACHE/key"
expect_build "ad-hoc с подделанной записью"
expect_hit "кэш снова живой"

# Проверка вправе менять свой бандл: кэш от этого не портится.
plutil -replace NSHumanReadableCopyright -string tampered "$B/Probe.app/Contents/Info.plist"
verified && bad "испорченный бандл проходит подпись" || ok "проверка испортила свой бандл"
expect_hit "после порчи своего"
verified && ok "готовый бандл снова цел" || bad "готовый бандл испорчен"

echo "== выключение и границы"
( cd "$FX" && INCREMENTAL_OFF=1 build_seam_utility test.probe Probe 1.2.3 "$B" --test-seam ) > "$RUN/off.log" 2>&1
BUILD_RC=$?; BUILD_LOG="$RUN/off.log"
if [ "$BUILD_RC" = 0 ] && ! from_cache; then ok "INCREMENTAL_OFF=1: пересборка"; else bad "INCREMENTAL_OFF=1 (код $BUILD_RC)"; fi

# Своя папка у каждой копии проекта, и в самом отпечатке путь копии.
SECOND="$RUN/second-copy"
cp -R "$FX" "$SECOND"
same "у другой копии проекта другой кэш" "$([ "$(cd "$SECOND" && incremental_cache utility-test.probe --test-seam)" != "$CACHE" ] && echo разный)" разный
same "у другого флага другой кэш" "$([ "$(cd "$FX" && incremental_cache utility-test.probe --test-seam-real-id)" != "$CACHE" ] && echo разный)" разный
mv "$CACHE" "$CACHE.kept"
mkdir -p "$(cd "$SECOND" && dirname "$(incremental_cache utility-test.probe --test-seam)")"
cp -R "$CACHE.kept" "$(cd "$SECOND" && incremental_cache utility-test.probe --test-seam)"
mv "$CACHE.kept" "$CACHE"
( cd "$SECOND" && build_seam_utility test.probe Probe 1.2.3 "$B" --test-seam ) > "$RUN/second.log" 2>&1
BUILD_RC=$?; BUILD_LOG="$RUN/second.log"
if [ "$BUILD_RC" = 0 ] && ! from_cache; then ok "кэш другой копии, подложенный в свой: пересборка"; else bad "кэш другой копии взят (код $BUILD_RC)"; fi

# Выпуск и сборка для разработки готовое не берут. Настоящий build-app.sh, подставной репозиторий.
( cd "$FX" && UTILITUMUS_BUILD_CACHE="$CACHE" scripts/build-app.sh test.probe Probe 1.2.3 "$B" ) > "$RUN/refuse.log" 2>&1
same "боевая сборка с кэшем: отказ" "$?" 1
has "почему отказ" "$(cat "$RUN/refuse.log")" "только для сборок со швом"
( cd "$FX" && UTILITUMUS_DEV_CACHE="$RUN/devc" UTILITUMUS_BUILD_CACHE="$CACHE" scripts/build-app.sh test.probe Probe 1.2.3 "$B" --test-seam ) > /dev/null 2>&1
same "режим разработки с кэшем: отказ" "$?" 1
( cd "$FX" && UTILITUMUS_BUILD_CACHE=relative scripts/build-app.sh test.probe Probe 1.2.3 "$B" --test-seam ) > /dev/null 2>&1
same "относительный путь кэша: отказ" "$?" 1
( cd "$FX" && UTILITUMUS_DEV_CACHE="$RUN/devc" scripts/build-app.sh test.probe Probe 1.2.3 "$B" --dev-alone ) > /dev/null 2>&1
same "--dev-alone с настоящим id: отказ" "$?" 1
( cd "$FX" && scripts/build-app.sh test.probe.dev Probe 1.2.3 "$B" --dev-alone ) > /dev/null 2>&1
same "--dev-alone без режима разработки: отказ" "$?" 1

if [ "$failures" -eq 0 ]; then echo "ДЕВ-КОПИЯ И ГОТОВЫЙ БАНДЛ: ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
