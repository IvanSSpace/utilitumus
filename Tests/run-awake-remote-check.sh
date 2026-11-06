#!/bin/bash
# Вкладка «Не спать»: рисует центр, работает утилита. Настоящие подписанная утилита, launchd, связь и pmset.
# Обе стороны собраны со швом KIT_TEST_DEFAULTS: настройки в suite стенда, окно за экраном. Настоящие Utilitumus
# и его настройки не трогаются. Не запускать вместе с run-awake-app-check.sh: у них одна метка и один suite.
# Нужен сертификат «Utilitumus Signing». Папка стенда: AWAKE_REMOTE_DIR, иначе $TMPDIR/awake-remote-check; снимки в ней, в png/.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${AWAKE_REMOTE_DIR:-${TMPDIR:-/tmp}/awake-remote-check}"
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
HUB="$OUT/awake-remote-hub"
FOREIGN="$OUT/awake-remote-foreign"
IDLE_PID=""

reset_suite() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
cleanup() {
  if [ -n "$IDLE_PID" ]; then kill -9 "$IDLE_PID" 2>/dev/null || true; fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  reset_suite
  rm -f "$HOME/Library/Preferences/awake-remote-hub.plist" "$HOME/Library/Preferences/awake-remote-foreign.plist"
  defaults delete awake-remote-hub 2>/dev/null || true
  defaults delete awake-remote-foreign 2>/dev/null || true
}
trap 'exit 1' HUP INT TERM
trap cleanup EXIT

failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$3», получили «$2»"; fi; }

# Таймера в модели и странице быть не должно: grep 0 — нашёл, 1 — пусто, больше — ошибка самого grep.
status=0
FOUND="$(grep -nE 'Timer|asyncAfter|DispatchSource|Task\.sleep|\.wait\(|DispatchSemaphore' Sources/App/Satellites/RemoteAwakeModel.swift Sources/App/Satellites/RemoteAwakePage.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: модель вкладки ждёт или опрашивает:"; echo "$FOUND"; exit 1 ;;
  1) ok "в модели вкладки нет таймеров и синхронных ожиданий" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

mkdir -p "$OUT/src" "$OUT/png"
rm -f "$OUT"/png/*.png
scripts/build-app.sh "$ID" Awake 1.2.3 "$OUT" --test-seam

# Настоящий `ModuleDetail` из настоящего файла; точка входа у стенда своя.
sed '/^@main$/d' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/AwakeRemoteCheck.swift "$OUT/src/AwakeRemoteCheck.swift"
swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name AwakeRemoteCheck -o "$OUT/hub-build" \
  "$OUT/src/AwakeRemoteCheck.swift" "$OUT/src/UtilitumusApp.swift" \
  $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' -not -name UtilitumusApp.swift) \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfo.plist
cp "$OUT/hub-build" "$HUB"
codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus "$HUB" 2>/dev/null
cp "$OUT/hub-build" "$FOREIGN"
codesign --force --options runtime --sign "$SIGN_NAME" --identifier "$IDENTIFIER.foreign" "$FOREIGN" 2>/dev/null

reset_suite
defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$EXE</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
<key>MachServices</key><dict><key>$SERVICE</key><true/></dict>
<key>StandardErrorPath</key><string>$OUT/agent.log</string>
</dict></plist>
PLIST_EOF
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
  sleep 0.3
done
agent_pid() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}'; }
for _ in $(seq 1 50); do [ -n "$(agent_pid)" ] && break; sleep 0.1; done
PID="$(agent_pid)"
[ -n "$PID" ] || { echo "ПРОВАЛ: агент не запустился"; exit 1; }
for _ in $(seq 1 50); do [ -n "$("$HUB" state)" ] && break; sleep 0.1; done

echo "== чужая подпись"
BEFORE="$("$HUB" state)"
[ -n "$BEFORE" ] || { echo "ПРОВАЛ: утилита не ответила центру"; exit 1; }
if OUTPUT="$("$FOREIGN" foreign)"; then
  bad "moduleAction с чужим identifier прошёл: $OUTPUT"
else
  ok "moduleAction с чужим identifier: $OUTPUT"
fi
same "после отказа состояние то же" "$("$HUB" state)" "$BEFORE"
if pmset -g assertions | grep -F "$ASSERTION" | grep -qE "pid $PID\("; then bad "чужая подпись включила блокировку"; else ok "чужая подпись блокировку не включила"; fi
same "после отказа тот же процесс" "$(agent_pid)" "$PID"

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

echo "== простой: вкладка открыта, утилита работает"
"$HUB" idle "$OUT" > "$OUT/idle.log" & IDLE_PID=$!
for _ in $(seq 1 100); do grep -q готов "$OUT/idle.log" && break; sleep 0.1; done
sleep 10
for who in "центр(стенд) $IDLE_PID" "утилита $PID"; do
  set -- $who
  echo "     $1: rss $(ps -o rss= -p "$2" | tr -d ' ') КБ, footprint $(footprint -p "$2" 2>/dev/null | sed -n 's/.*phys_footprint: *//p;s/.*Footprint: *//p' | head -1), CPU за 20 с: $(top -l 3 -s 10 -pid "$2" -stats cpu | tail -1 | tr -d ' ') %"
done
kill -9 "$IDLE_PID" 2>/dev/null || true
wait "$IDLE_PID" 2>/dev/null || true
IDLE_PID=""

cleanup
listed() {
  local list
  list="$(launchctl list)"
  [[ "$list" == *"$LABEL"* ]]
}
for _ in $(seq 1 50); do listed || break; sleep 0.1; done
if listed; then bad "метка $LABEL осталась"; else ok "launchctl list без $LABEL"; fi
echo "     снимки: $OUT/png"
if [ "$failures" -eq 0 ]; then echo "ВКЛАДКА «НЕ СПАТЬ»: ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
