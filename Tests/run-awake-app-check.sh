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

reset_suite() {
  defaults delete "$SUITE" 2>/dev/null || true
}
cleanup() {
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

echo "== первый запуск: связь и включённость из ModuleOn"
reset_suite
defaults write "$SUITE" "ModuleOn.$ID" -bool true
defaults write "$SUITE" Modules.ResetForStore.v1 -bool true
hub_state false ""
start_agent
PID="$(agent_pid)"
same "hello: id, версия, протокол" "$(hub hello)" "$ID 1.2.3 1"
same "XPC_SERVICE_NAME дал active, запуск launchd" "$(line)" "Mac засыпает как обычно"
same "App.<id>.Enabled взят из ModuleOn" "$(defaults read "$SUITE" "App.$ID.Enabled")" "1"
same "Modules.ResetForStore.v1 не тронут" "$(defaults read "$SUITE" Modules.ResetForStore.v1)" "1"

if "$OUT/client-foreign" hello > "$OUT/foreign.out" 2>&1; then
  bad "клиент с нашим сертификатом и чужим identifier прошёл"
else
  ok "чужой identifier: отказ ($(head -c 80 "$OUT/foreign.out"))"
fi
same "после отказа тот же процесс" "$(agent_pid)" "$PID"
same "центр работает и после отказа" "$(hub hello)" "$ID 1.2.3 1"

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
expect_line "статус с остатком" "Mac не уснёт · ещё 1 ч"
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
if wait_until "прямой запуск без агента вышел" has_exited "$DIRECT"; then
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -le 3 ]; then ok "без агента вышел за ${ELAPSED} с"; else bad "без агента шёл ${ELAPSED} с"; fi
fi
wait "$DIRECT" 2>/dev/null || true
if [ -s "$OUT/direct.log" ]; then ok "без агента в журнале: $(head -1 "$OUT/direct.log")"; else bad "без агента журнал пуст"; fi

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
defaults write "$SUITE" "App.$ID.HandedOver" -bool true
hub enable
expect_line "передача: пассивная стала активной без перезапуска" "Mac засыпает как обычно"
same "без перезапуска" "$(agent_pid)" "$PID"
command_keep_awake "$PID"
expect_assertion "после передачи команда работает" "$PID"
hub quit
wait_until "вышел" has_exited "$PID" || true

defaults delete "$SUITE" "App.$ID.HandedOver"
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
if launchctl list | grep -q "$LABEL"; then bad "метка $LABEL осталась"; else ok "launchctl list без $LABEL"; fi
if [ "$failures" -eq 0 ]; then echo "НЕ СПАТЬ: ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
