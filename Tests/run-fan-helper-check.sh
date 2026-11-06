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

CHECK_SOURCES="$OUT/src/main.swift Sources/Shared/FanLink.swift Sources/Kit/KitSigning.swift Sources/Modules/Fans/FanHelperClient.swift Sources/Modules/Fans/FanHelperInstaller.swift"
HELPER_SOURCES="Sources/Shared/FanLink.swift Sources/Kit/KitSigning.swift Sources/FanHelper/main.swift"

swiftc -O -target "$TARGET" -module-name FanCheckPure -o "$OUT/pure" $CHECK_SOURCES -framework AppKit
swiftc -O -target "$TARGET" -D FAN_TEST_FAKE_SMC -module-name FanCheckClient -o "$OUT/client-build" $CHECK_SOURCES -framework AppKit
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

# Дочерний процесс наследует разрешения приложения: непроверенный бинарник из бандла запускать нельзя.
# Приложение и не запускает помощника: статус и команды идут по XPC, копию проверяет root-скрипт установки.
if grep -nE 'Process\(\)|NSTask|posix_spawn' Sources/Modules/Fans/*.swift; then fail "модуль Вентиляторы запускает процесс"; fi
ok "модуль Вентиляторы не запускает процессов, в том числе копию помощника из бандла"
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
[ "$("$OUT/daemon" version)" = 4 ] || fail "version сборки со швом"
[ ! -s "$LOG" ] || fail "version записал в SMC"
ok "version печатает версию без SMC"

[ "$("$OUT/prod-signed" version)" = 4 ] || fail "version боевой сборки"
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
}
run_install() {
  local text
  text="$("$OUT/pure" print-install "$OUT/$1" | sandbox_script)"
  case "$text" in *"/Library/"*|*"/bin/launchctl"*|*"/usr/sbin/chown"*) fail "в скрипте остался настоящий путь" ;; esac
  /bin/sh -c "$text" >/dev/null 2>"$OUT/install.err"
}

reset_sandbox
run_install prod-signed || { cat "$OUT/install.err"; fail "установка верно подписанного бинарника"; }
cmp -s "$OUT/prod-signed" "$SB/tools/local.utilitumus.fan" || fail "установлен не тот файл"
[ "$(stat -f '%Lp' "$SB/tools/local.utilitumus.fan")" = 755 ] || fail "права бинарника не 755"
[ "$(stat -f '%Lp' "$SB/daemons/local.utilitumus.fan.plist")" = 644 ] || fail "права плиста не 644"
plutil -lint "$SB/daemons/local.utilitumus.fan.plist" >/dev/null || fail "плист не разбирается"
grep -q "launchctl bootout system/local.utilitumus.fan" "$SB/calls.log" || fail "нет bootout"
grep -q "launchctl bootstrap system $SB/daemons/local.utilitumus.fan.plist" "$SB/calls.log" || fail "нет bootstrap"
grep -q "chown root:wheel .*/helper" "$SB/calls.log" || fail "нет chown бинарника"
grep -q "chown root:wheel .*/plist" "$SB/calls.log" || fail "нет chown плиста"
[ -z "$(find "$SB/tools" -name '.install.*')" ] || fail "временный каталог остался"
ok "установка: бинарник 755 на месте старого setuid, плист 644, служба снята и поставлена"

for bad in spoof-adhoc spoof-foreign rogue-foreign; do
  reset_sandbox
  if run_install "$bad"; then fail "установка $bad прошла"; fi
  [ "$(cat "$SB/tools/local.utilitumus.fan")" = старый ] || fail "$bad заменил бинарник"
  [ ! -e "$SB/daemons/local.utilitumus.fan.plist" ] || fail "$bad поставил плист"
  if grep -q launchctl "$SB/calls.log"; then fail "$bad дошёл до launchctl"; fi
  [ -z "$(find "$SB/tools" -name '.install.*')" ] || fail "временный каталог остался после отказа"
done
ok "чужая подпись: остановка до mv, файлы не тронуты, launchctl не вызван"

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
ok "удаление снимает службу, плист и бинарник"

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
    if [ -n "${2:-}" ]; then echo "<key>$2</key><string>1</string>"; fi
    echo '</dict>'
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
role() { echo "== $1 $2"; "$OUT/$1" "$2"; }

agent daemon
expect_state "not running" "служба не запущена до первого подключения"
role hub hub
role fans-app hub
for rogue in rogue-adhoc rogue-adhoc-fan rogue-foreign rogue-prefix rogue-satellite; do
  role "$rogue" rogue
done
[ ! -s "$LOG" ] || fail "чужие клиенты изменили поддельный SMC"
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

agent daemon FAN_TEST_SMC_STUCK
role hub stuck

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

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl list | grep -q "$LABEL" || break
  sleep 0.3
done
if launchctl list | grep -q "$LABEL"; then fail "метка $LABEL осталась"; fi
ok "launchctl list без $LABEL"
echo "ПОМОЩНИК: ВСЁ ОК"
