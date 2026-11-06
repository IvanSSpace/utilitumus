#!/bin/bash
# Помощник вентиляторов: чистая логика, текст и поведение скриптов установки, затем подписанные
# бинарники под launchd в домене пользователя. Настоящий SMC не трогается: роли собраны со швом
# FAN_TEST_FAKE_SMC, в такой сборке нет ни SMC.swift, ни IOKit. Пароль не спрашивается.
# Папка стенда (удаляется до и после): FAN_HELPER_CHECK_DIR, иначе $TMPDIR/fan-helper-check. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${FAN_HELPER_CHECK_DIR:-${TMPDIR:-/tmp}/fan-helper-check}"
DOMAIN="gui/$(id -u)"
LABEL="local.utilitumus.test.fan"
SERVICE="local.utilitumus.test.fan.xpc"
SIGN_NAME="Utilitumus Signing"
PLIST="$OUT/$LABEL.plist"

cleanup() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  # Подписанные нашим сертификатом бинарники с боевыми identifier не оставляем.
  rm -rf "$OUT"
}
trap 'exit 1' HUP INT TERM
trap cleanup EXIT

fail() { echo "ПРОВАЛ: $1"; exit 1; }
ok() { echo "ok   $1"; }

rm -rf "$OUT"
mkdir -p "$OUT/src"
cp Tests/FanHelperCheck.swift "$OUT/src/main.swift"

CHECK_SOURCES="$OUT/src/main.swift Sources/Shared/FanLink.swift Sources/Kit/KitSigning.swift Sources/Kit/KitDefaults.swift Sources/Kit/Link/LinkProtocol.swift Sources/Modules/Fans/FanGate.swift Sources/Modules/Fans/FanHelperClient.swift Sources/Modules/Fans/FanHelperInstaller.swift Sources/Modules/Fans/LegacyFanHelper.swift"
# Метка выпуска: без бандла Info.plist лежит в самом бинарнике.
MARKED=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfo.plist)
HELPER_SOURCES="Sources/Shared/FanLink.swift Sources/Kit/KitSigning.swift Sources/FanHelper/main.swift"

swiftc -O -target "$TARGET" -module-name FanCheckPure -o "$OUT/pure" $CHECK_SOURCES -framework AppKit
swiftc -O -target "$TARGET" -D FAN_TEST_FAKE_SMC -module-name FanCheckClient -o "$OUT/client-build" $CHECK_SOURCES -framework AppKit "${MARKED[@]}"
# Как старый выпуск: тот же код, но в подписи нет метки.
swiftc -O -target "$TARGET" -D FAN_TEST_FAKE_SMC -module-name FanCheckClient -o "$OUT/client-unmarked" $CHECK_SOURCES -framework AppKit
perl -0777 -pe 's#(<key>UtilitumusSecurityEpoch</key><string>)1#${1}0#' "$OUT/client-build" > "$OUT/client-epoch0"
chmod +x "$OUT/client-epoch0"
if cmp -s "$OUT/client-build" "$OUT/client-epoch0"; then fail "метка эпохи не подменилась"; fi
# Подмена: дёргается при запуске через `auto`, на `version` отвечает прежней версией.
cat > "$OUT/src/stub.c" <<'STUB'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "version") == 0) { puts("3"); return 0; }
  if (getenv("FAN_TEST_STUB_SLOW")) sleep(3);
  char path[2048];
  snprintf(path, sizeof path, "%s/legacy.log", getenv("FAN_TEST_DIR"));
  FILE *log = fopen(path, "a");
  if (!log) return 1;
  for (int i = 1; i < argc; i++) fprintf(log, i + 1 < argc ? "%s " : "%s\n", argv[i]);
  fclose(log);
  return 0;
}
STUB
clang -target "$TARGET" -o "$OUT/stub-build" "$OUT/src/stub.c"
# Внедряется через DYLD_INSERT_LIBRARIES и оставляет след: так ли загрузился код в чужой процесс.
cat > "$OUT/src/inject.c" <<'INJECT'
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void mark(void) {
  char path[2048];
  snprintf(path, sizeof path, "%s/injected.log", getenv("FAN_TEST_DIR"));
  FILE *log = fopen(path, "a");
  if (log) { fputs("x\n", log); fclose(log); }
}
INJECT
clang -target "$TARGET" -dynamiclib -o "$OUT/inject.dylib" "$OUT/src/inject.c"
swiftc -O -target "$TARGET" -D FAN_TEST_FAKE_SMC -module-name FanHelperFake -o "$OUT/daemon-build" $HELPER_SOURCES
# Как в build.sh: без шва, с настоящим SMC. Запускается только `version` и отказ без launchd.
swiftc -O -wmo -target "$TARGET" -module-name FanHelperProd -o "$OUT/prod" Sources/Shared/SMC.swift $HELPER_SOURCES -framework IOKit

echo "== без шва"
"$OUT/pure"

echo "== сборка без шва чиста"
if nm "$OUT/prod" | grep -iE 'fake|fan_test'; then fail "символы шва в боевой сборке"; fi
ok "nm: нет символов поддельного SMC"
if strings -a "$OUT/prod" | grep -E 'FAN_TEST|local\.utilitumus\.test|smc-writes'; then fail "строки шва в боевой сборке"; fi
ok "strings: нет имён шва"
if ! strings -a "$OUT/prod" | grep -q '^local\.utilitumus\.fan\.xpc$'; then fail "в боевой сборке нет имени службы"; fi
ok "strings: боевое имя службы на месте"
# Только фреймворк: оверлей libswiftIOKit Swift подвязывает сам, вызовов SMC в нём нет.
if otool -L "$OUT/daemon-build" | grep -q 'IOKit.framework'; then fail "сборка со швом связана с IOKit"; fi
if nm -u "$OUT/daemon-build" | grep -qE 'IOService|IOConnect'; then fail "сборка со швом зовёт IOKit"; fi
if ! nm -u "$OUT/prod" | grep -q 'IOConnectCallStructMethod'; then fail "проверка IOKit слепа: в боевой сборке нет вызова SMC"; fi
ok "сборка со швом не может дойти до настоящего SMC"
if nm -a "$OUT/prod" | grep -q 'SwiftUI'; then fail "SwiftUI в root-процессе"; fi
if otool -L "$OUT/prod" | grep -qE 'SwiftUI|AppKit'; then fail "SwiftUI/AppKit в root-процессе"; fi
ok "в root-процессе нет SwiftUI и AppKit"
if grep -n 'FAN_TEST_FAKE_SMC' build.sh; then fail "шов в build.sh"; fi
ok "в build.sh нет шва"

# Дочерний процесс наследует разрешения приложения: непроверенный бинарник запускать нельзя.
# Статус и команды идут по XPC, копию проверяет root-скрипт установки. Исключение одно: прежний
# setuid-помощник, и только после проверки подписи. Убрать вместе с поддержкой setuid.
LEGACY=Sources/Modules/Fans/LegacyFanHelper.swift
if grep -nE 'Process\(\)|NSTask|posix_spawn' Sources/Modules/Fans/*.swift | grep -v "^$LEGACY:"; then fail "модуль Вентиляторы запускает процесс"; fi
ok "модуль Вентиляторы не запускает процессов, кроме прежнего setuid-помощника"
[ "$(grep -cE 'Process\(\)' "$LEGACY")" = 1 ] || fail "в $LEGACY ждём один запуск"
verify_line="$(grep -n 'KitSigning.verifySignature' "$LEGACY" | cut -d: -f1)"
process_line="$(grep -n 'Process()' "$LEGACY" | cut -d: -f1)"
[ -n "$verify_line" ] && [ "$verify_line" -lt "$process_line" ] || fail "проверка подписи не раньше запуска"
grep -q 'identifier: "local.utilitumus.fan"' "$LEGACY" || fail "проверка не того identifier"
ok "прежний помощник: сначала подпись, потом запуск"
# Без hardened runtime метка ничего не значила бы: в такой бинарник внедряют код.
grep -q 'codesign --force --options runtime --entitlements Utilitumus.entitlements' build.sh || fail "центр без hardened runtime"
grep -q 'codesign --force --options runtime --sign "$SIGN_ID" --identifier "local.utilitumus.app.$ID"' scripts/build-app.sh || fail "утилита без hardened runtime"
ok "метка ставится только на hardened-сборки"
if [ "$(grep -c 'bundledPath' Sources/Modules/Fans/FanHelperInstaller.swift)" != 2 ]; then fail "копия из бандла используется не только как источник установки"; fi
ok "копия из бандла нужна только скрипту установки"

# Подпись как в build.sh.
KC_PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KC="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
if [ -f "$KC_PASSWORD_FILE" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$KC_PASSWORD_FILE")" "$KC"
fi
if ! security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  fail "нет сертификата «$SIGN_NAME»"
fi

# signed <откуда> <куда> <подпись> <identifier>
signed() {
  cp "$OUT/$1" "$OUT/$2"
  codesign --force --options runtime --sign "$3" --identifier "$4" "$OUT/$2" 2>/dev/null
}
signed daemon-build daemon          "$SIGN_NAME" local.utilitumus.fan
signed daemon-build spoof-adhoc     -            local.utilitumus.fan
signed daemon-build spoof-foreign   "$SIGN_NAME" local.utilitumus.fan.evil
signed client-build hub             "$SIGN_NAME" local.utilitumus
signed client-build fans-app        "$SIGN_NAME" local.utilitumus.app.fans
signed client-build rogue-adhoc     -            local.utilitumus
signed client-build rogue-adhoc-fan -            local.utilitumus.app.fans
signed client-build rogue-foreign   "$SIGN_NAME" local.utilitumus.rogue
signed client-build rogue-prefix    "$SIGN_NAME" local.utilitumus.app.fans.evil
signed client-build rogue-satellite "$SIGN_NAME" local.utilitumus.app.awake
signed prod         prod-signed     "$SIGN_NAME" local.utilitumus.fan
signed client-unmarked rogue-unmarked      "$SIGN_NAME" local.utilitumus
signed client-unmarked rogue-unmarked-fans "$SIGN_NAME" local.utilitumus.app.fans
signed client-epoch0   rogue-epoch0        "$SIGN_NAME" local.utilitumus
signed stub-build   stub-old        "$SIGN_NAME" local.utilitumus.fan
signed stub-build   stub-adhoc      -            local.utilitumus.fan
signed stub-build   stub-foreign    "$SIGN_NAME" local.utilitumus.fan.evil
# Как выпуски v0.2.0–v0.4.4: наш сертификат, боевой identifier, без метки и без hardened runtime.
cp "$OUT/client-unmarked" "$OUT/old-release"
codesign --force --sign "$SIGN_NAME" --identifier local.utilitumus "$OUT/old-release" 2>/dev/null

echo "== запуск без launchd"
LOG="$OUT/smc-writes.log"
export FAN_TEST_DIR="$OUT"
: > "$LOG"
for args in "" "auto 0" "set 0 2000" "--service x" "version extra"; do
  status=0
  # shellcheck disable=SC2086
  "$OUT/daemon" $args >/dev/null 2>&1 || status=$?
  [ "$status" = 64 ] || fail "без launchd «$args»: код $status"
done
[ ! -s "$LOG" ] || fail "запуск без launchd записал в SMC"
ok "без launchd отказ с кодом 64, записи нет"
[ "$("$OUT/daemon" version)" = 6 ] || fail "version сборки со швом"
[ ! -s "$LOG" ] || fail "version записал в SMC"
ok "version печатает версию без SMC"

[ "$("$OUT/prod-signed" version)" = 6 ] || fail "version боевой сборки"
ok "боевая сборка: version"
for value in "" "$LABEL" "0"; do
  status=0
  env XPC_SERVICE_NAME="$value" "$OUT/prod-signed" >/dev/null 2>&1 || status=$?
  [ "$status" = 64 ] || fail "боевая сборка с XPC_SERVICE_NAME=«$value»: код $status"
done
ok "боевая сборка: тестовая метка из окружения её не перенаправляет"

echo "== скрипт установки на подставных путях"
# Настоящие cp, mv, chmod, mktemp, codesign; chown и launchctl заменены записью в журнал, пути в стенде.
# Стенд не под /Library, поэтому остаток настоящего пути виден по grep ниже.
SB="$OUT/sb"
# Со старшим разрядом: один %Lp показал бы у setuid-файла те же 755.
mode() { stat -f '%Mp%Lp' "$1"; }
make_stub() {
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n%s\n' "$1" "$SB" "${2:-exit 0}" > "$SB/$1"
  chmod +x "$SB/$1"
}
sandbox_script() {
  sed -e "s#/Library/PrivilegedHelperTools#$SB/tools#g" \
      -e "s#/Library/LaunchDaemons#$SB/daemons#g" \
      -e "s#/bin/launchctl#$SB/launchctl#g" \
      -e "s#/usr/sbin/chown#$SB/chown#g"
}
reset_sandbox() {
  rm -rf "$SB"
  mkdir -p "$SB/tools" "$SB/daemons"
  make_stub chown
  make_stub launchctl
  : > "$SB/calls.log"
  echo старый > "$SB/tools/local.utilitumus.fan"
  chmod 4755 "$SB/tools/local.utilitumus.fan"
  ln "$SB/tools/local.utilitumus.fan" "$SB/hardlink"
}
run_install() {
  local text
  text="$("$OUT/pure" print-install "$OUT/$1" | sandbox_script)"
  case "$text" in *"/Library/"*|*"/bin/launchctl"*|*"/usr/sbin/chown"*) fail "в скрипте остался настоящий путь" ;; esac
  /bin/sh -c "$text" >/dev/null 2>"$OUT/install.err"
}

xattr -w com.utilitumus.test 1 "$OUT/prod-signed"
reset_sandbox
run_install prod-signed || { cat "$OUT/install.err"; fail "установка верно подписанного бинарника"; }
cmp -s "$OUT/prod-signed" "$SB/tools/local.utilitumus.fan" || fail "установлен не тот файл"
[ "$(mode "$SB/tools/local.utilitumus.fan")" = 0755 ] || fail "права бинарника не 755"
# Только наш атрибут: com.apple.provenance система ставит сама.
if xattr "$SB/tools/local.utilitumus.fan" | grep -q com.utilitumus.test; then fail "расширенные атрибуты дошли до копии"; fi
[ "$(mode "$SB/hardlink")" = 0755 ] || fail "жёсткая ссылка на старый файл осталась с setuid"
[ "$(mode "$SB/daemons/local.utilitumus.fan.plist")" = 0644 ] || fail "права плиста не 644"
plutil -lint "$SB/daemons/local.utilitumus.fan.plist" >/dev/null || fail "плист не разбирается"
grep -q "launchctl bootout system/local.utilitumus.fan" "$SB/calls.log" || fail "нет bootout"
grep -q "launchctl bootstrap system $SB/daemons/local.utilitumus.fan.plist" "$SB/calls.log" || fail "нет bootstrap"
grep -q "chown root:wheel .*/helper" "$SB/calls.log" || fail "нет chown бинарника"
grep -q "chown root:wheel .*/plist" "$SB/calls.log" || fail "нет chown плиста"
[ -z "$(find "$SB/tools" -name '.install.*')" ] || fail "временный каталог остался"
ok "установка: бинарник 755 на месте старого setuid, плист 644, служба снята и поставлена"

for bad in spoof-adhoc spoof-foreign rogue-foreign stub-old; do
  reset_sandbox
  if run_install "$bad"; then fail "установка $bad прошла"; fi
  [ "$(cat "$SB/tools/local.utilitumus.fan")" = старый ] || fail "$bad заменил бинарник"
  [ "$(mode "$SB/tools/local.utilitumus.fan")" = 4755 ] || fail "$bad поменял права до проверки"
  [ ! -e "$SB/daemons/local.utilitumus.fan.plist" ] || fail "$bad поставил плист"
  if grep -q launchctl "$SB/calls.log"; then fail "$bad дошёл до launchctl"; fi
  [ -z "$(find "$SB/tools" -name '.install.*')" ] || fail "временный каталог остался после отказа"
done
ok "чужая подпись и прежняя версия с нашей подписью: остановка до mv, файлы не тронуты, launchctl не вызван"

echo "== прежний setuid-помощник"
: > "$OUT/legacy.log"
"$OUT/pure" legacy "$OUT/stub-old" 0 1 || fail "помощник с верной подписью не запустился"
[ "$(sort "$OUT/legacy.log")" = "auto 0
auto 1" ] || fail "прежний помощник получил не то: $(cat "$OUT/legacy.log")"
ok "верная подпись: auto каждому вентилятору"
: > "$OUT/legacy.log"
env FAN_TEST_STUB_SLOW=1 "$OUT/pure" legacy-bounded "$OUT/stub-old"
sleep 3
[ "$(sort "$OUT/legacy.log")" = "auto 0
auto 1" ] || fail "клиент вышел, прежний помощник не доделал: $(cat "$OUT/legacy.log")"
ok "помощник завис на 3 с: выход не ждёт, запущенные доделывают обоим вентиляторам"
for bad in stub-adhoc stub-foreign; do
  : > "$OUT/legacy.log"
  if "$OUT/pure" legacy "$OUT/$bad" 0 1 > /dev/null; then fail "$bad принят"; fi
  [ ! -s "$OUT/legacy.log" ] || fail "$bad запущен без проверки"
done
ok "чужая подпись: файл не запускается"

# bootout падает, служба не загружена: установка идёт дальше. bootstrap не сразу отпускает метку.
reset_sandbox
cat > "$SB/launchctl" <<STUB
#!/bin/sh
echo "launchctl \$*" >> "$SB/calls.log"
[ "\$1" = bootout ] && exit 3
[ "\$(grep -c 'launchctl bootstrap' "$SB/calls.log")" -ge 3 ]
STUB
run_install prod-signed || fail "установка с ошибкой bootout и двумя отказами bootstrap"
ok "ошибка bootout не важна, bootstrap повторяется"

reset_sandbox
make_stub launchctl 'exit 5'
if run_install prod-signed; then fail "установка скрыла постоянный отказ bootstrap"; fi
ok "постоянный отказ bootstrap виден как ошибка"

reset_sandbox
echo плист > "$SB/daemons/local.utilitumus.fan.plist"
make_stub launchctl 'exit 3'
text="$("$OUT/pure" print-uninstall | sandbox_script)"
case "$text" in *"/Library/"*|*"/bin/launchctl"*) fail "в скрипте удаления остался настоящий путь" ;; esac
/bin/sh -c "$text" || fail "удаление при незагруженной службе"
grep -q "launchctl bootout system/local.utilitumus.fan" "$SB/calls.log" || fail "удаление не сняло службу"
[ ! -e "$SB/daemons/local.utilitumus.fan.plist" ] || fail "удаление оставило плист"
[ ! -e "$SB/tools/local.utilitumus.fan" ] || fail "удаление оставило бинарник"
[ "$(mode "$SB/hardlink")" = 0755 ] || fail "удаление: жёсткая ссылка осталась с setuid"
ok "удаление снимает службу, плист и бинарник, жёсткая ссылка без setuid"

echo "== отравленное окружение оболочки"
printf '/usr/bin/touch "%s/pwn-env"\n' "$OUT" > "$OUT/poison.sh"
chmod +x "$OUT/poison.sh"
clean_pwn() { rm -f "$OUT"/pwn-* "$OUT/ran"; }
# Контроль: без защиты отрава срабатывает. Иначе проверка ниже ничего бы не значила.
clean_pwn
"$OUT/pure" poison raw "$OUT"
[ -e "$OUT/pwn-func" ] || fail "контроль: BASH_FUNC_ не сработал, проверка слепа"
[ -e "$OUT/pwn-ps4" ] || fail "контроль: PS4 не сработал, проверка слепа"
ok "контроль: без защиты отрава исполняется (функция и PS4)"
# Одного env -i мало: внешняя оболочка читает окружение раньше него.
clean_pwn
"$OUT/pure" poison env-only "$OUT"
[ -e "$OUT/pwn-ps4" ] || fail "контроль: PS4 не сработал во внешней оболочке"
ok "контроль: при одном env -i PS4 срабатывает во внешней оболочке, поэтому окружение чистится и в процессе"
clean_pwn
"$OUT/pure" poison full "$OUT"
[ -e "$OUT/ran" ] || fail "скрипт-пустышка не выполнился"
for pwn in pwn-func pwn-ps4 pwn-env; do
  [ ! -e "$OUT/$pwn" ] || fail "отрава сработала: $pwn"
done
ok "чистка окружения и env -i: скрипт выполнен, отрава нет"

# agent <программа> [переменная окружения]: снимает прошлый агент, ставит этот, журнал с нуля.
agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  : > "$LOG"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    echo "<key>Label</key><string>$LABEL</string>"
    echo "<key>ProgramArguments</key><array><string>$OUT/$1</string></array>"
    echo "<key>MachServices</key><dict><key>$SERVICE</key><true/></dict>"
    echo "<key>ThrottleInterval</key><integer>0</integer>"
    echo "<key>EnvironmentVariables</key><dict><key>FAN_TEST_DIR</key><string>$OUT</string>"
    for name in ${2:-}; do echo "<key>$name</key><string>1</string>"; done
    echo '</dict>'
    # Как в боевом плисте (FanHelperInstaller.plistXML): перезапуск только после сбоя.
    if [ -n "${AGENT_KEEPALIVE:-}" ]; then echo '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>'; fi
    echo "<key>StandardErrorPath</key><string>$OUT/agent.log</string>"
    echo '</dict></plist>'
  } > "$PLIST"
  # launchd отпускает метку не сразу после bootout.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && return 0
    sleep 0.3
  done
  fail "launchctl bootstrap $LABEL"
}
state() { launchctl print "$DOMAIN/$LABEL" | grep -m1 'state = ' | sed 's/.*state = //'; }
expect_state() { [ "$(state)" = "$1" ] || fail "$2: состояние «$(state)», ждали «$1»"; ok "$2"; }
# shellcheck disable=SC2086
role() { echo "== $1 $2"; "$OUT/$1" $2; }

agent daemon
expect_state "not running" "служба не запущена до первого подключения"
role hub hub
role fans-app hub
for rogue in rogue-adhoc rogue-adhoc-fan rogue-foreign rogue-prefix rogue-satellite; do
  role "$rogue" rogue
done
[ ! -s "$LOG" ] || fail "чужие клиенты изменили поддельный SMC"

echo "== метка выпуска"
# Боевой identifier и наш сертификат, но без метки или с другой эпохой: отказ.
for rogue in rogue-unmarked rogue-unmarked-fans rogue-epoch0 old-release; do
  role "$rogue" rogue
done
[ ! -s "$LOG" ] || fail "клиент без метки изменил поддельный SMC"
# Сама атака: код внедрён в старый выпуск и работает, а слушатель всё равно отказывает.
rm -f "$OUT/injected.log"
env DYLD_INSERT_LIBRARIES="$OUT/inject.dylib" "$OUT/old-release" rogue
[ -s "$OUT/injected.log" ] || fail "код не внедрился в старый выпуск: проверка слепа"
[ ! -s "$LOG" ] || fail "внедрённый код изменил поддельный SMC"
ok "код внедрён в старый выпуск, слушатель отказал"
# В сборку с меткой код внедрить нельзя: hardened runtime.
rm -f "$OUT/injected.log"
env DYLD_INSERT_LIBRARIES="$OUT/inject.dylib" "$OUT/hub" hub > /dev/null 2>&1 || fail "сборка с меткой не работает"
[ ! -e "$OUT/injected.log" ] || fail "код внедрился в сборку с меткой"
ok "в сборку с меткой код не внедряется"
echo "== настоящий клиент после чужих"
role hub hub

for spoof in spoof-adhoc spoof-foreign; do
  agent "$spoof"
  role hub spoofed
  [ ! -s "$LOG" ] || fail "$spoof получил запись"
done

agent daemon FAN_TEST_SILENT
role hub silent
[ ! -s "$LOG" ] || fail "молчащая служба получила запись"

agent daemon "FAN_TEST_SMC_STUCK FAN_TEST_NO_START_RELEASE"
role hub stuck

echo "== статус не поднимает службу без нужды"
runs() { launchctl print "$DOMAIN/$LABEL" | grep -m1 'runs = ' | sed 's/.*runs = //'; }
agent daemon
role hub refresh-off
expect_state "not running" "модуль выключен: refresh не поднял службу"
[ "$(runs)" = 0 ] || fail "модуль выключен: launchd запускал службу, runs = $(runs)"
ok "модуль выключен: launchd не запускал службу ни разу"
role hub refresh-on
[ "$(runs)" = 1 ] || fail "модуль включён: runs = $(runs)"
ok "модуль включён: refresh поднял службу один раз"

echo "== общий срок при выходе"
agent daemon
role hub "quit ok"
agent daemon FAN_TEST_SILENT
role hub "quit silent"
agent daemon "FAN_TEST_SMC_STUCK FAN_TEST_NO_START_RELEASE"
role hub "quit stuck"
sleep 6
[ "$(cat "$LOG")" = "F0Md=0
F1Md=0" ] || fail "клиент вышел, служба не доделала команды: $(cat "$LOG")"
ok "клиент вышел, служба доделала команды обоим вентиляторам"
agent daemon
role hub "quit busy"
agent daemon FAN_TEST_SLOW_HELLO
role hub cancel-after-handshake

echo "== выход без подключений"
agent daemon
role hub hub >/dev/null
sleep 3
expect_state "not running" "после закрытия соединения служба вышла за 2 с"
[ "$("$OUT/hub" hub | tail -1)" = "ВСЁ ОК" ] || fail "после выхода служба не поднялась снова"
ok "следующее подключение поднимает службу снова"

agent daemon
"$OUT/rogue-foreign" rogue >/dev/null
sleep 3
expect_state "not running" "чужой поднял службу, она вышла сама"

agent daemon
"$OUT/hub" hold 4 >/dev/null &
HOLD=$!
sleep 3
expect_state "running" "с открытым соединением служба не выходит"
wait "$HOLD"
sleep 3
expect_state "not running" "соединение закрыто: служба вышла"

agent daemon
"$OUT/hub" hold 30 >/dev/null &
HOLD=$!
sleep 1
expect_state "running" "соединение открыто"
kill -9 "$HOLD"
wait "$HOLD" 2>/dev/null || true
sleep 3
expect_state "not running" "клиент убит: служба вышла"

echo "== сторож удержания: ручной режим не переживает клиента"
# Срок сторожа в сборке со швом 3 с, выход без подключений 2 с.
agent daemon
"$OUT/hub" hold-manual 30 >/dev/null &
HOLD=$!
sleep 1.5
expect_state "running" "клиент держит вентилятор в ручном режиме"
grep -q 'F0Md=1' "$LOG" || fail "вентилятор не взят в ручной режим: $(cat "$LOG")"
kill -9 "$HOLD"
wait "$HOLD" 2>/dev/null || true
sleep 4
grep -q 'F0Md=0' "$LOG" || fail "клиент убит (SIGKILL), вентилятор остался в ручном режиме: $(cat "$LOG")"
[ "$(tail -1 "$LOG")" = "F0Md=0" ] || fail "после возврата в Авто записи продолжились: $(cat "$LOG")"
expect_state "not running" "клиент убит: вентилятор в Авто, служба вышла"
ok "SIGKILL клиента: служба сама вернула вентилятор 0 в Авто"

# Соединение живое, команд нет: сторож срабатывает по времени, а не по закрытию соединения.
agent daemon
"$OUT/hub" hold-manual 12 >/dev/null &
HOLD=$!
sleep 6
grep -q 'F0Md=0' "$LOG" || fail "соединение открыто, команд нет: вентилятор остался в ручном режиме: $(cat "$LOG")"
expect_state "running" "соединение ещё открыто, а вентилятор уже в Авто"
ok "тишина 3 с при открытом соединении: вентилятор в Авто"
kill -9 "$HOLD" 2>/dev/null || true
wait "$HOLD" 2>/dev/null || true
sleep 3

# Клиент жив и повторяет удержание: сторож ничего не трогает.
agent daemon
"$OUT/hub" keepalive 7 | tail -1 | grep -q "ВСЁ ОК" || fail "удержание: роль не прошла"
if grep -q 'F0Md=0' "$LOG"; then fail "клиент повторял удержание, а вентилятор отдан: $(cat "$LOG")"; fi
ok "удержание раз в секунду 7 с (сторож 3 с): вентилятор не отдан"
sleep 5
grep -q 'F0Md=0' "$LOG" || fail "после последней команды вентилятор не отдан"
ok "команды кончились: вентилятор отдан через срок"

echo "== перегрев: служба сама возвращает «Авто» и не берёт удержание"
# Пороги те же, что у клиента: служба берёт их из FanLink, клиент тоже.
/usr/bin/grep -q 'safetyTrip = FanLink.thermalTrip' Sources/Modules/Fans/FanController.swift || fail "клиент не берёт порог из FanLink"
/usr/bin/grep -q 'safetyRelease = FanLink.thermalRelease' Sources/Modules/Fans/FanController.swift || fail "клиент не берёт порог возврата из FanLink"
rm -f "$OUT/temp-cpu" "$OUT/temp-gpu"
agent daemon
echo 50 > "$OUT/temp-cpu"
"$OUT/hub" hold-manual 8 >/dev/null &
HOLD=$!
sleep 0.5
grep -q 'F0Md=1' "$LOG" || fail "перегрев: вентилятор не взят: $(cat "$LOG")"
echo 96 > "$OUT/temp-gpu"
sleep 2
grep -q 'F0Md=0' "$LOG" || fail "датчик графики 96 °C при живом клиенте: служба не вернула «Авто»: $(cat "$LOG")"
ok "горячий датчик (графика) при живом клиенте: служба вернула «Авто» сама, до срока сторожа"
kill -9 "$HOLD" 2>/dev/null || true
wait "$HOLD" 2>/dev/null || true
"$OUT/hub" thermal-set refused | tail -1 | grep -q "ВСЁ ОК" || fail "перегрев: удержание принято"
echo 90 > "$OUT/temp-gpu"; sleep 1.2
"$OUT/hub" thermal-set refused | tail -1 | grep -q "ВСЁ ОК" || fail "90 °C после перегрева: гистерезис не держится"
echo 70 > "$OUT/temp-gpu"; sleep 1.2
"$OUT/hub" thermal-set ok | tail -1 | grep -q "ВСЁ ОК" || fail "остыл до 70 °C: удержание не принято"
ok "перегрев: отказ, гистерезис на 90 °C, после остывания удержание снова принимается"
rm -f "$OUT/temp-cpu" "$OUT/temp-gpu"; sleep 3.5
"$OUT/hub" thermal-set ok | tail -1 | grep -q "ВСЁ ОК" || fail "датчики не читаются: удержание не принято"
echo 99 > "$OUT/temp-cpu"; sleep 1.2
"$OUT/hub" thermal-set refused | tail -1 | grep -q "ВСЁ ОК" || fail "процессор 99 °C: удержание принято"
rm -f "$OUT/temp-cpu"; sleep 1.2
"$OUT/hub" thermal-set ok | tail -1 | grep -q "ВСЁ ОК" || fail "датчики пропали при перегреве: служба осталась заблокированной"
ok "датчики не читаются: не перегрев, обычная работа не блокируется"
sleep 4

# Зависшая запись: сторож пробует не бесконечно, но служба не уходит молча, пока вентилятор ручной.
rm -f "$OUT/agent.log"
agent daemon "FAN_TEST_SMC_STUCK FAN_TEST_NO_START_RELEASE"
"$OUT/hub" hold-manual 1 >/dev/null || true
for _ in $(seq 1 45); do [ "$(state)" = "not running" ] && break; sleep 1; done
expect_state "not running" "SMC не принимает «Авто»: попытки конечны, служба вышла"
grep -q 'выход отложен' "$OUT/agent.log" || fail "простой с ручным вентилятором: выход не откладывался: $(cat "$OUT/agent.log")"
grep -q 'выход с вентилятором в ручном режиме' "$OUT/agent.log" || fail "после попыток нет записи в журнале: $(cat "$OUT/agent.log")"
launchctl print "$DOMAIN/$LABEL" | grep -q 'last exit code = 1' || fail "выход с ручным вентилятором не с кодом 1"
ok "вентилятор ручной: выход отложен, попытки записаны в журнал, конец с кодом 1"

echo "== перезапуск после сбоя: вентилятор, оставшийся ручным, возвращается без клиента"
# Клиент не нужен, подпись тоже: служба стартует сама из-за KeepAlive. В поддельном SMC вентиляторы ручные при каждом запуске.
pid_of() { launchctl print "$DOMAIN/$LABEL" | grep -m1 'pid = ' | sed 's/.*pid = //'; }
AGENT_KEEPALIVE=1 agent daemon FAN_TEST_SMC_MANUAL
PID=""
for _ in $(seq 1 30); do PID="$(pid_of || true)"; [ -n "$PID" ] && break; sleep 0.1; done
[ -n "$PID" ] || fail "с KeepAlive служба не запустилась"
# Сразу после spawn процесс ещё не стал нашим: kill отказывает, пока не дойдёт exec.
sleep 0.4
LINES0="$(wc -l < "$LOG")"
KILLED=""
for _ in $(seq 1 20); do kill -9 "$PID" 2>/dev/null && { KILLED=1; break; }; sleep 0.05; done
[ -n "$KILLED" ] || fail "служба не убита: $PID"
RUNS=1
for _ in $(seq 1 30); do RUNS="$(runs)"; [ "$RUNS" -ge 2 ] && break; sleep 0.1; done
[ "$RUNS" -ge 2 ] || fail "после SIGKILL launchd не поднял службу: runs = $RUNS"
# Выход по простою через 2 с тоже возвращает «Авто», поэтому смотрим раньше: это запись именно при запуске.
sleep 0.7
LINES1="$(wc -l < "$LOG")"
[ "$LINES1" -ge $((LINES0 + 2)) ] || fail "при запуске ручные вентиляторы не возвращены в Авто: было $LINES0, стало $LINES1: $(cat "$LOG")"
expect_state "running" "после перезапуска служба ещё работает: запись сделана при запуске, не при выходе"
sleep 3
ok "SIGKILL службы: launchd поднял её, при запуске оба вентилятора в Авто без клиента"
expect_state "not running" "чистый выход по простою (код 0): служба остаётся остановленной"
RUNS="$(runs)"
sleep 4
[ "$(runs)" = "$RUNS" ] || fail "после чистого выхода launchd снова запускал службу: runs $RUNS -> $(runs)"
ok "чистый выход не вызывает перезапуска"

# SMC не принимает «Авто»: при запуске служба пробует, по простою не выходит молча, кончает кодом 1, launchd поднимает её снова.
rm -f "$OUT/agent.log"
AGENT_KEEPALIVE=1 agent daemon FAN_TEST_SMC_STUCK
for _ in $(seq 1 180); do [ "$(runs)" -ge 2 ] && break; sleep 0.5; done
[ "$(runs)" -ge 2 ] || fail "ручной вентилятор не отпускается: launchd не поднял службу после выхода с ошибкой"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
/usr/bin/grep -q 'выход отложен' "$OUT/agent.log" || fail "простой с ручным вентилятором: выход не откладывался: $(cat "$OUT/agent.log")"
/usr/bin/grep -q 'выход с вентилятором в ручном режиме' "$OUT/agent.log" || fail "после попыток нет записи в журнале: $(cat "$OUT/agent.log")"
ok "вентилятор ручной и не отпускается: выход отложен, попытки в журнале, конец с ошибкой и перезапуск launchd"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl list | grep -q "$LABEL" || break
  sleep 0.3
done
if launchctl list | grep -q "$LABEL"; then fail "метка $LABEL осталась"; fi
ok "launchctl list без $LABEL"
echo "ПОМОЩНИК: ВСЁ ОК"
