#!/bin/bash
# Отдельное приложение «Не спать» под launchd: связь, блокировка, запуск мимо launchd, передача от центра.
# Сборка со швом KIT_TEST_DEFAULTS: настройки только в suite стенда, состояние центра подставное, значка и видимых
# окон нет. Настоящие Utilitumus и его настройки не трогаются. Нужен сертификат «Utilitumus Signing».
# Папка стенда: AWAKE_CHECK_DIR, иначе $TMPDIR/awake-app-check.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${AWAKE_CHECK_DIR:-${TMPDIR:-/tmp}/awake-app-check}"
DOMAIN="gui/$(id -u)"
LABEL="local.utilitumus.test.awake"
ID="test.awake"
IDENTIFIER="local.utilitumus.app.$ID"
SERVICE="$IDENTIFIER.xpc"
SUITE="local.utilitumus.test.kit"
SIGN_NAME="Utilitumus Signing"
ASSERTION="Utilitumus: Keep Awake"
PLIST="$OUT/$LABEL.plist"
APP="$OUT/Awake.app"
EXE="$APP/Contents/MacOS/Awake"
LOG="$OUT/agent.log"
FAKE_HUB_ID="local.utilitumus.test.fakehub"
FAKE_HUB="$OUT/FakeHub.app"
FAKE_HUB_PID=""
WATCH_PID=""

reset_suite() {
  defaults delete "$SUITE" 2>/dev/null || true
}
cleanup() {
  if [ -n "$FAKE_HUB_PID" ]; then kill -9 "$FAKE_HUB_PID" 2>/dev/null || true; fi
  if [ -n "$WATCH_PID" ]; then kill -9 "$WATCH_PID" 2>/dev/null || true; fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  reset_suite
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
trap 'exit 1' HUP INT TERM
trap cleanup EXIT

failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$3», получили «$2»"; fi; }

mkdir -p "$OUT/src"
[ -f Sources/Apps/Awake/Info.plist ] || { echo "ПРОВАЛ: нет Sources/Apps/Awake"; exit 1; }
scripts/build-app.sh "$ID" Awake 1.2.3 "$OUT" --test-seam

same "LSUIElement" "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" "true"
same "bundle id" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" "$IDENTIFIER"

cp Tests/SatelliteRoleCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/client-build" "$OUT/src/main.swift" \
  Sources/Kit/KitDefaults.swift Sources/Kit/KitSigning.swift Sources/Kit/SatelliteCatalog.swift \
  Sources/Kit/SatelliteRole.swift Sources/Kit/SatelliteSelfUpdate.swift $(find Sources/Kit/Link -name '*.swift') \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfo.plist
signed() {
  cp "$OUT/client-build" "$OUT/$1"
  codesign --force --options runtime --sign "$SIGN_NAME" --identifier "$2" "$OUT/$1" 2>/dev/null
}
signed client-hub "local.utilitumus"
# Подставной центр: приложение без Dock и без окон, как настоящий при выключенной настройке Dock.
cat > "$OUT/src/fakehub.swift" <<'SWIFT_EOF'
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
SWIFT_EOF
mkdir -p "$FAKE_HUB/Contents/MacOS"
swiftc -target "$TARGET" -o "$FAKE_HUB/Contents/MacOS/FakeHub" "$OUT/src/fakehub.swift" -framework AppKit
signed client-foreign "local.utilitumus.test.awake.foreign"
hub() { "$OUT/client-hub" "$@"; }

# Снимает прошлый агент, ставит новый. RunAtLoad как в настоящем плисте утилиты.
start_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  : > "$LOG"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$EXE</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
<key>MachServices</key><dict><key>$SERVICE</key><true/></dict>
<key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST_EOF
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
      wait_until "агент отвечает" hub hello > /dev/null
      return 0
    fi
    sleep 0.3
  done
  echo "ПРОВАЛ: launchctl bootstrap $LABEL"
  exit 1
}
agent_pid() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}'; }

# Имя в pmset могло остаться и у настоящего приложения пользователя, поэтому только по pid стенда.
holds_assertion() { pmset -g assertions | grep -F "$ASSERTION" | grep -qE "pid $1\("; }
holds_display_assertion() { pmset -g assertions | grep -F "$ASSERTION" | grep -E "pid $1\(" | grep -qE 'DisplaySleep'; }

# wait_until <что> <команда...>: до 5 с, тишина при успехе.
wait_until() {
  local what="$1"; shift
  for _ in $(seq 1 50); do
    if "$@" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  bad "не дождались: $what"
  return 1
}
no_assertion() { ! holds_assertion "$1"; }
has_exited() { ! kill -0 "$1" 2>/dev/null; }

expect_assertion() { if wait_until "$1" holds_assertion "$2"; then ok "$1"; fi; }
expect_no_assertion() { if wait_until "$1" no_assertion "$2"; then ok "$1"; fi; }
# Команда могла не успеть дойти: сначала даём ей время, потом смотрим, что assertion нет.
expect_still_no_assertion() {
  sleep 0.5
  if holds_assertion "$2"; then bad "$1"; else ok "$1"; fi
}
# Команда «Не спать» в сборке со швом приходит сигналом: окна и значка на экране нет.
command_keep_awake() { kill -USR1 "$1"; }
line() { hub status | cut -d'|' -f2; }
expect_line() {
  for _ in $(seq 1 30); do
    [ "$(line)" = "$2" ] && { ok "$1"; return 0; }
    sleep 0.1
  done
  bad "$1: ждали «$2», получили «$(line)»"
}
hub_state() {
  defaults write "$SUITE" Test.HubRunning -bool "$1"
  defaults write "$SUITE" Test.HubVersion -string "$2"
}
png() {
  rm -f "$1"
  defaults write "$SUITE" Test.PNGPath -string "$1"
  hub open
  sleep 1
  kill -USR2 "$(agent_pid)"
  if wait_until "PNG $1" test -s "$1"; then ok "окно за экраном отрисовано: $1"; fi
}

# fake_hub_start <версия>: версию утилита может узнать только из Info.plist запущенного бандла.
fake_hub_start() {
  cat > "$FAKE_HUB/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$FAKE_HUB_ID</string>
<key>CFBundleExecutable</key><string>FakeHub</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST_EOF
  if [ "$1" = нечитаемая ]; then plutil -remove CFBundleShortVersionString "$FAKE_HUB/Contents/Info.plist" > /dev/null; fi
  "$FAKE_HUB/Contents/MacOS/FakeHub" & FAKE_HUB_PID=$!
}
# fake_hub_stop <сигнал>
fake_hub_stop() {
  kill "-$1" "$FAKE_HUB_PID"
  wait "$FAKE_HUB_PID" 2>/dev/null || true
  FAKE_HUB_PID=""
}
last_icon() { grep 'значок' "$LOG" | tail -1; }
icon_is() { [ "$(last_icon)" = "Не спать: значок $1" ]; }
expect_icon() { if wait_until "$1" icon_is "$2"; then ok "$1"; else bad "$1: $(last_icon)"; fi; }

echo "== первый запуск: связь и включённость из ModuleOn"
reset_suite
defaults write "$SUITE" "ModuleOn.$ID" -bool true
defaults write "$SUITE" Modules.ResetForStore.v1 -bool true
hub_state false ""
start_agent
PID="$(agent_pid)"
same "hello: id, версия, протокол" "$(hub hello)" "$ID 1.2.3 3"
same "XPC_SERVICE_NAME дал active, запуск launchd" "$(line)" "Mac засыпает как обычно"
same "App.<id>.Enabled взят из ModuleOn" "$(defaults read "$SUITE" "App.$ID.Enabled")" "1"
same "Modules.ResetForStore.v1 не тронут" "$(defaults read "$SUITE" Modules.ResetForStore.v1)" "1"

if "$OUT/client-foreign" hello > "$OUT/foreign.out" 2>&1; then
  bad "клиент с нашим сертификатом и чужим identifier прошёл"
else
  ok "чужой identifier: отказ ($(head -c 80 "$OUT/foreign.out"))"
fi
same "после отказа тот же процесс" "$(agent_pid)" "$PID"
same "центр работает и после отказа" "$(hub hello)" "$ID 1.2.3 3"

echo "== блокировка"
expect_still_no_assertion "до команды assertion нет" "$PID"
command_keep_awake "$PID"
expect_assertion "команда «Не спать» создаёт assertion" "$PID"
expect_line "статус: Mac не уснёт" "Mac не уснёт"
hub disable
expect_no_assertion "setEnabled(false) снимает assertion" "$PID"
same "статус: выключено" "$(hub status | cut -d'|' -f1)" "false"
same "App.<id>.Enabled записан" "$(defaults read "$SUITE" "App.$ID.Enabled")" "0"
command_keep_awake "$PID"
expect_still_no_assertion "выключенная утилита команду не исполняет" "$PID"
hub enable
command_keep_awake "$PID"
expect_assertion "снова включили: команда работает" "$PID"
hub quit
expect_no_assertion "quit снимает assertion" "$PID"
if wait_until "процесс вышел после quit" has_exited "$PID"; then ok "quit: процесс вышел"; fi
case "$(launchctl print "$DOMAIN/$LABEL" | grep -m1 'state = ')" in
  *"not running"*) ok "launchd не перезапустил после quit" ;;
  *) bad "после quit launchd его перезапустил" ;;
esac

echo "== длительность в статусе"
defaults write "$SUITE" AwakeDuration -int 3600
start_agent
command_keep_awake "$(agent_pid)"
expect_line "со сроком статус без остатка: центр не перечитывает его по таймеру" "Mac не уснёт"
PID="$(agent_pid)"
hub quit
defaults write "$SUITE" AwakeDuration -int 0
wait_until "вышел" has_exited "$PID" || true

echo "== запуск мимо launchd"
start_agent
PID="$(agent_pid)"
START=$(date +%s)
XPC_SERVICE_NAME=0 "$EXE" & DIRECT=$!
if wait_until "прямой запуск вышел" has_exited "$DIRECT"; then
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -le 3 ]; then ok "прямой запуск вышел сам за ${ELAPSED} с"; else bad "прямой запуск шёл ${ELAPSED} с"; fi
fi
wait "$DIRECT" 2>/dev/null || true
same "агент тот же" "$(agent_pid)" "$PID"
same "второго процесса нет" "$(pgrep -f "$EXE" | wc -l | tr -d ' ')" "1"
sleep 0.3
if grep -q "окно показано" "$LOG"; then ok "openWindow дошёл до работающей копии (свой identifier принят)"; else bad "openWindow не дошёл"; cat "$LOG"; fi
if grep -q "окно показано 480x520 x=-10000" "$LOG"; then ok "окно 480×520 за экраном"; else bad "размер или место окна: $(grep 'окно показано' "$LOG" | tail -1)"; fi
png "$OUT/awake-dusk.png"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
sleep 0.3
START=$(date +%s)
XPC_SERVICE_NAME=0 "$EXE" 2> "$OUT/direct.log" & DIRECT=$!
# launchd держит перезапуск 10 с, поэтому утилита ждёт дольше и только потом сдаётся.
for _ in $(seq 1 200); do has_exited "$DIRECT" && break; sleep 0.1; done
if has_exited "$DIRECT"; then
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -ge 11 ] && [ "$ELAPSED" -le 18 ]; then ok "без агента ждал ${ELAPSED} с и вышел"; else bad "без агента шёл ${ELAPSED} с"; fi
else
  bad "прямой запуск без агента не вышел за 20 с"
fi
wait "$DIRECT" 2>/dev/null || true
if grep -q "окно об ошибке запуска" "$OUT/direct.log"; then ok "без агента человеку показана ошибка: $(head -1 "$OUT/direct.log")"; else bad "без агента нет ошибки: $(cat "$OUT/direct.log")"; fi

# Агент поднялся, пока запуск ещё пробует: окно должно открыться, а не ошибка.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
sleep 0.3
XPC_SERVICE_NAME=0 "$EXE" 2> "$OUT/direct.log" & DIRECT=$!
sleep 3
start_agent
for _ in $(seq 1 100); do has_exited "$DIRECT" && break; sleep 0.1; done
wait "$DIRECT" 2>/dev/null || true
if grep -q "окно показано" "$LOG" && ! grep -q "окно об ошибке" "$OUT/direct.log"; then ok "агент поднялся через 3 с: повтор дошёл, ошибки нет"; else bad "повтор не дошёл: $(cat "$OUT/direct.log")"; fi
hub quit
wait_until "вышел" has_exited "$(agent_pid)" || true

echo "== утилита объявляет о себе после старта"
reset_suite
defaults write "$SUITE" Test.HubBundleID -string "$FAKE_HUB_ID"
: > "$OUT/watch.log"
"$OUT/client-hub" watch > "$OUT/watch.log" & WATCH_PID=$!
wait_until "наблюдатель готов" grep -q "слушаю" "$OUT/watch.log" || true
start_agent
sees_status() { grep -q "statusChanged" "$OUT/watch.log"; }
if wait_until "statusChanged при старте" sees_status; then ok "после старта сервиса ушёл statusChanged"; fi
kill -9 "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

echo "== утилиту поставили отдельно: центра не было"
same "нет ModuleOn: утилита включена" "$(hub status | cut -d'|' -f1)" "true"
same "нет ModuleOn: включённость записана" "$(defaults read "$SUITE" "App.$ID.Enabled")" "1"
PID="$(agent_pid)"
command_keep_awake "$PID"
expect_assertion "нет ModuleOn: команда работает" "$PID"
command_keep_awake "$PID"
expect_no_assertion "и снимается" "$PID"
hub quit
wait_until "вышел" has_exited "$PID" || true

echo "== центр без Dock появляется и выходит"
reset_suite
defaults write "$SUITE" Test.HubBundleID -string "$FAKE_HUB_ID"
defaults write "$SUITE" "ModuleOn.$ID" -bool true
start_agent
PID="$(agent_pid)"
expect_icon "центра нет: значок виден" "виден"
expect_line "центра нет: утилита активна" "Mac засыпает как обычно"
command_keep_awake "$PID"
expect_assertion "человек сам включил блокировку" "$PID"
fake_hub_start 0.6.0
expect_icon "центр запущен: значок скрыт" "скрыт"
expect_line "запуск центра не снимает блокировку: статус честный" "Mac не уснёт"
if holds_assertion "$PID"; then ok "запуск центра не снимает блокировку"; else bad "запуск центра снял блокировку"; fi
command_keep_awake "$PID"
expect_no_assertion "кнопка снимает блокировку и в пассивном режиме" "$PID"
expect_line "теперь ждём передачу: версия взята из Info.plist запущенного центра" "Ждём передачу от центра"
command_keep_awake "$PID"
expect_still_no_assertion "снова включить, пока ждём передачу, нельзя" "$PID"
fake_hub_stop TERM
expect_icon "центр вышел без Dock: значок вернулся" "виден"
expect_line "центр вышел: пассивная утилита решила заново" "Mac засыпает как обычно"
fake_hub_start 0.6.0
expect_line "центр снова запущен: снова ждём" "Ждём передачу от центра"
fake_hub_stop KILL
expect_icon "центр упал: значок вернулся" "виден"
expect_line "центр упал: утилита активна" "Mac засыпает как обычно"

echo "== старый центр"
command_keep_awake "$PID"
expect_assertion "блокировка перед запуском старого центра" "$PID"
fake_hub_start 0.5.3
expect_no_assertion "старый центр снимает блокировку: модуль может работать в нём" "$PID"
expect_line "старый центр: версия из его Info.plist" "Модуль уже работает в Utilitumus — обновите центр"
fake_hub_stop TERM
expect_line "старый центр вышел: активна" "Mac засыпает как обычно"

echo "== версию центра не прочитать"
command_keep_awake "$PID"
expect_assertion "блокировка перед запуском центра" "$PID"
fake_hub_start нечитаемая
expect_icon "центр без версии: значок скрыт" "скрыт"
if holds_assertion "$PID"; then ok "нет версии: включённая блокировка держится"; else bad "нет версии: блокировка снята"; fi
expect_line "нет версии: статус честный" "Mac не уснёт"
command_keep_awake "$PID"
expect_no_assertion "нет версии: кнопка снимает" "$PID"
command_keep_awake "$PID"
expect_still_no_assertion "нет версии: новую блокировку не даёт" "$PID"
fake_hub_stop TERM
expect_line "центр без версии вышел: активна" "Mac засыпает как обычно"

echo "== выключенная утилита при центре"
command_keep_awake "$PID"
expect_assertion "блокировка перед выключением" "$PID"
fake_hub_start 0.6.0
expect_line "центр запущен: блокировка держится" "Mac не уснёт"
hub disable
expect_no_assertion "выключение снимает блокировку" "$PID"
fake_hub_stop TERM
hub quit
wait_until "вышел" has_exited "$PID" || true
defaults delete "$SUITE" Test.HubBundleID

echo "== пассивный режим и передача от центра"
reset_suite
defaults write "$SUITE" "ModuleOn.$ID" -bool true
hub_state true 0.6.0
start_agent
PID="$(agent_pid)"
expect_line "центр ≥0.6.0, модуль включён: ждём передачу" "Ждём передачу от центра"
command_keep_awake "$PID"
expect_still_no_assertion "пассивный режим: команда не создаёт assertion" "$PID"
png "$OUT/awake-passive.png"
# Модуль вёл центр: настройка изменилась уже после запуска утилиты.
defaults write "$SUITE" AwakeKeepDisplay -bool true
defaults write "$SUITE" "App.$ID.HandedOver" -bool true
hub enable
expect_line "передача: пассивная стала активной без перезапуска" "Mac засыпает как обычно"
same "без перезапуска" "$(agent_pid)" "$PID"
command_keep_awake "$PID"
expect_assertion "после передачи команда работает" "$PID"
if holds_display_assertion "$PID"; then ok "после передачи настройка не устаревшая: экран тоже не гаснет"; else bad "после передачи утилита работает со старой настройкой экрана"; fi
hub quit
wait_until "вышел" has_exited "$PID" || true

defaults delete "$SUITE" "App.$ID.HandedOver"
defaults delete "$SUITE" AwakeKeepDisplay
hub_state true 0.5.3
start_agent
expect_line "центр старше 0.6.0: обновите центр" "Модуль уже работает в Utilitumus — обновите центр"
PID="$(agent_pid)"
command_keep_awake "$PID"
expect_still_no_assertion "старый центр: команда не создаёт assertion" "$PID"
hub quit
wait_until "вышел" has_exited "$PID" || true

echo "== замена бандла"
ditto -c -k --keepParent "$APP" "$OUT/update.zip"
SUM="$(shasum -a 256 "$OUT/update.zip" | cut -d' ' -f1)"
TARGET_APP="$OUT/target/Awake.app"
rm -rf "$OUT/target"; mkdir -p "$TARGET_APP"; touch "$TARGET_APP/old"
if "$OUT/client-hub" replace "$OUT/update.zip" 00 1.2.3 "$TARGET_APP" > /dev/null; then bad "плохая сумма принята"; else ok "плохая сумма: отказ"; fi
if "$OUT/client-hub" replace "$OUT/update.zip" "$SUM" 9.9.9 "$TARGET_APP" > /dev/null; then bad "не та версия принята"; else ok "не та версия: отказ"; fi
[ -f "$TARGET_APP/old" ] && ok "после отказов бандл не тронут" || bad "после отказа бандл изменён"
"$OUT/client-hub" replace "$OUT/update.zip" "$SUM" 1.2.3 "$TARGET_APP" || bad "замена не прошла"
[ ! -f "$TARGET_APP/old" ] && ok "бандл заменён" || bad "бандл не заменён"
codesign --verify --deep --strict "$TARGET_APP" && ok "подпись заменённого цела" || bad "подпись заменённого"

cleanup
# Список в переменной: `launchctl list | grep -q` при pipefail падает от SIGPIPE и выглядит как «метки нет».
listed() {
  local list
  list="$(launchctl list)"
  [[ "$list" == *"$LABEL"* ]]
}
not_listed() { ! listed; }
if wait_until "launchctl list без $LABEL" not_listed; then ok "launchctl list без $LABEL"; fi
if [ "$failures" -eq 0 ]; then echo "НЕ СПАТЬ: ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
