#!/bin/bash
# Сквозная проверка: настоящие подписанный Awake.app, launchd и связь, настоящие реестр и установщик.
# Настоящая метка local.utilitumus.app.awake разрешена только здесь: перед запуском проверяется, что её нет.
# Бандл и плист — в папке стенда. Утилита собрана со швом (--test-seam-real-id): настройки в suite стенда,
# состояние центра подставное, значка нет, окно за экраном и прозрачное. Настоящие Utilitumus и настройки не трогаются.
# Нужен сертификат «Utilitumus Signing».
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
DOMAIN="gui/$(id -u)"
ID="awake"
LABEL="local.utilitumus.app.$ID"
SUITE="local.utilitumus.test.kit"
SIGN_NAME="Utilitumus Signing"
ASSERTION="Utilitumus: Keep Awake"
REAL_HUB="/Applications/Utilitumus.app/Contents/MacOS/Utilitumus"

# Только чтение настоящего домена: снимок для сверки в конце.
real_keys() { defaults read local.utilitumus 2>/dev/null | grep -E '(App\.awake\.|ModuleOn\.awake)' || true; }
# ps -o comm= даёт полный путь. Сравнение строк целиком: другие копии с похожим именем не задеваются.
pids_of() { ps -axww -o pid=,comm= | awk -v path="$1" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == path) print pid }'; }

# До trap: чужую метку снимать нельзя.
if launchctl print "$DOMAIN/$LABEL" > /dev/null 2>&1; then
  echo "ПРОВАЛ: метка $LABEL уже загружена, проверка не запускается"
  exit 2
fi
if [ -e "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
  echo "ПРОВАЛ: плист $LABEL уже есть в LaunchAgents, проверка не запускается"
  exit 2
fi
REAL_KEYS_BEFORE="$(real_keys)"
REAL_HUB_BEFORE="$(pids_of "$REAL_HUB")"

OUT="$(mktemp -d "${TMPDIR:-/tmp}/hub-e2e.XXXXXX")"
APPS="$OUT/Apps"
AGENTS="$OUT/Agents"
APP="$APPS/Awake.app"
EXE="$APP/Contents/MacOS/Awake"
AGENT="$AGENTS/$LABEL.plist"
HUB="$OUT/hub"
HOLD_PID=""

reset_suite() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
cleanup() {
  trap - EXIT
  if [ -n "$HOLD_PID" ]; then kill -9 "$HOLD_PID" 2>/dev/null || true; fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  for pid in $(pids_of "$EXE"); do kill -9 "$pid" 2>/dev/null || true; done
  rm -rf -- "$OUT"
  reset_suite
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$3», получили «$2»"; fi; }
check() { local what="$1"; shift; if "$@" 2>/dev/null; then ok "$what"; else bad "$what"; fi; }

# wait_until <секунд> <команда...>: тишина при успехе.
wait_until() {
  local tries=$(($1 * 10)); shift
  for _ in $(seq 1 "$tries"); do
    if "$@" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
expect() { local what="$1"; shift; if wait_until 5 "$@"; then ok "$what"; else bad "$what"; fi; }

agent_pid() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}'; }
# Имя может держать и настоящее приложение пользователя, поэтому только по pid утилиты.
holds_assertion() { pmset -g assertions | grep -F "$ASSERTION" | grep -qE "pid $1\("; }
no_assertion() { ! holds_assertion "$1"; }
has_exited() { ! kill -0 "$1" 2>/dev/null; }
no_label() { ! launchctl print "$DOMAIN/$LABEL" > /dev/null 2>&1; }
# Список в переменной: `launchctl list | grep -q` при pipefail падает от SIGPIPE и выглядит как «метки нет».
no_label_listed() {
  local list
  list="$(launchctl list)" || return 1
  [[ "$list" != *"local.utilitumus.app."* ]]
}
hub_line() { "$HUB" "$OUT" state | cut -d'|' -f"$1"; }
line_is() { [ "$(hub_line 4)" = "$1" ]; }
suite_key() { defaults read "$SUITE" "$1" 2>/dev/null || echo "нет"; }
app_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"; }
fingerprint() { cat "$EXE" "$APP/Contents/Info.plist" "$AGENT" | shasum -a 256 | cut -d' ' -f1; }
# Команда «Не спать» в сборке со швом приходит сигналом и работает как переключатель.
keep_awake() { kill -USR1 "$1"; }
seen_pids=""
remember() { seen_pids="$seen_pids $1"; }

echo "== сборка"
reset_suite
pack() { ditto -c -k --keepParent "$1" "$2"; }
# catalog <файл> <версия> <архив>
catalog() {
  cat > "$1" <<JSON
{"schema":1,"apps":[{"id":"$ID","version":"$2","minHub":"0.6.0","url":"file://$3","sha256":"$(shasum -a 256 "$3" | cut -d' ' -f1)","sizeMB":1}]}
JSON
}
# forge <дело> <подпись> <identifier>: номер 1.2.0 и чужая подпись.
forge() {
  mkdir -p "$OUT/$1"
  cp -R "$OUT/v2/Awake.app" "$OUT/$1/Awake.app"
  plutil -replace CFBundleShortVersionString -string 1.2.0 "$OUT/$1/Awake.app/Contents/Info.plist"
  codesign --force --options runtime --sign "$2" --identifier "$3" "$OUT/$1/Awake.app" 2>/dev/null
  pack "$OUT/$1/Awake.app" "$OUT/$1.zip"
  catalog "$OUT/$1.json" 1.2.0 "$OUT/$1.zip"
}
for step in "v1 1.0.0" "v2 1.1.0"; do
  set -- $step
  scripts/build-app.sh "$ID" Awake "$2" "$OUT/$1" --test-seam-real-id
  pack "$OUT/$1/Awake.app" "$OUT/$1.zip"
  catalog "$OUT/$1.json" "$2" "$OUT/$1.zip"
done
forge adhoc - "$LABEL"
forge other-id "$SIGN_NAME" "$LABEL.foreign"

mkdir -p "$OUT/src"
cp Tests/HubE2E.swift "$OUT/src/main.swift"
# Центр целиком, как в проверках модулей: модель «Не спать» тянет за собой дашборд, а он весь центр. Точка входа у стенда своя.
sed '/^@main$/d' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
HUB_LIST="$(scripts/hub-sources.sh)"
HUB_FILES=()
while IFS= read -r f; do case "$f" in */UtilitumusApp.swift) ;; *) HUB_FILES+=("$f") ;; esac; done <<<"$HUB_LIST"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name HubE2E -o "$HUB" "$OUT/src/main.swift" "$OUT/src/UtilitumusApp.swift" \
  "${HUB_FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework Carbon -framework Charts -framework CoreAudio -framework AudioToolbox -framework IOKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfoSeam.plist
codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus "$HUB" 2>/dev/null

echo "== установка"
defaults write "$SUITE" Test.HubRunning -bool false
same "до установки метки нет" "$(no_label && echo нет)" "нет"
same "установка: версия, ответ, включена, статус" "$("$HUB" "$OUT" install "$OUT/v1.json")" "1.0.0|true|true|Mac засыпает как обычно"
check "бандл на месте" test -d "$APP"
same "версия бандла" "$(app_version)" "1.0.0"
check "подпись установленного цела" codesign --verify --deep --strict "$APP"
same "identifier подписи" "$(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p')" "$LABEL"
same "плист: метка" "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT")" "$LABEL"
same "плист: путь к бинарнику" "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT")" "$EXE"
PID="$(agent_pid)"
remember "$PID"
check "launchd держит процесс" kill -0 "$PID"
same "launchd запустил именно бинарник из стенда" "$(pids_of "$EXE")" "$PID"
same "hello с версией" "$("$HUB" "$OUT" hello)" "$ID 1.0.0 3"
same "App.awake.Enabled поставлен при установке" "$(suite_key App.awake.Enabled)" "1"
same "передача записана" "$(suite_key App.awake.HandedOver)" "1"

echo "== команды"
expect "до команды assertion нет" no_assertion "$PID"
"$HUB" "$OUT" disable
same "setEnabled(false): статус" "$(hub_line 3)" "false"
same "setEnabled(false): настройка" "$(suite_key App.awake.Enabled)" "0"
keep_awake "$PID"
sleep 0.5
check "выключенная утилита не берёт assertion" no_assertion "$PID"
"$HUB" "$OUT" enable
same "setEnabled(true): статус" "$(hub_line 3)" "true"
keep_awake "$PID"
expect "включённая утилита берёт assertion" holds_assertion "$PID"
"$HUB" "$OUT" disable
expect "setEnabled(false) снимает assertion" no_assertion "$PID"
"$HUB" "$OUT" enable
same "модель центра: нажатие включило блокировку" "$("$HUB" "$OUT" model-toggle)" "true"
expect "модель центра: assertion у процесса утилиты" holds_assertion "$PID"
same "модель центра: нажатие выключило блокировку" "$("$HUB" "$OUT" model-toggle)" "false"
expect "модель центра: assertion снят" no_assertion "$PID"
"$HUB" "$OUT" open
same "окно за экраном: связь ответила, процесс тот же" "$(agent_pid)" "$PID"

echo "== центр завершается, утилита живёт"
"$HUB" "$OUT" hold > "$OUT/hold.log" &
HOLD_PID=$!
hold_saw() { grep -qF "$1" "$OUT/hold.log"; }
if wait_until 5 hold_saw "1.0.0|true|true|Mac засыпает как обычно"; then ok "живой центр видит утилиту"; else bad "живой центр не увидел утилиту: $(cat "$OUT/hold.log")"; fi
keep_awake "$PID"
expect "assertion при живом центре" holds_assertion "$PID"
check "у живого центра своего assertion нет" no_assertion "$HOLD_PID"
if wait_until 5 hold_saw "1.0.0|true|true|Mac не уснёт"; then ok "statusChanged дошёл до центра"; else bad "statusChanged не дошёл: $(cat "$OUT/hold.log")"; fi
kill -9 "$HOLD_PID"
wait "$HOLD_PID" 2>/dev/null || true
HOLD_PID=""
sleep 1
same "центр снят: процесс утилиты тот же" "$(agent_pid)" "$PID"
check "центр снят: утилита жива" kill -0 "$PID"
check "центр снят: assertion на месте" holds_assertion "$PID"

echo "== центр запущен снова"
same "hello успешен" "$("$HUB" "$OUT" hello)" "$ID 1.0.0 3"
same "статус виден новому центру" "$("$HUB" "$OUT" state)" "1.0.0|true|true|Mac не уснёт"
same "процесс тот же" "$(agent_pid)" "$PID"
check "assertion на месте" holds_assertion "$PID"

echo "== обновление"
START=$(date +%s)
same "обновление до 1.1.0: версия, ответ, включена, статус" "$("$HUB" "$OUT" install "$OUT/v2.json")" "1.1.0|true|true|Mac засыпает как обычно"
ELAPSED=$(($(date +%s) - START))
if [ "$ELAPSED" -le 20 ]; then ok "обновление заняло ${ELAPSED} с"; else bad "обновление заняло ${ELAPSED} с"; fi
expect "старый процесс вышел" has_exited "$PID"
check "старый процесс без assertion" no_assertion "$PID"
NEW_PID="$(agent_pid)"
remember "$NEW_PID"
if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$PID" ]; then ok "новый процесс"; else bad "процесс не сменился: $NEW_PID"; fi
PID="$NEW_PID"
same "hello с новой версией" "$("$HUB" "$OUT" hello)" "$ID 1.1.0 3"
same "версия бандла" "$(app_version)" "1.1.0"
same "в папке приложений только утилита" "$(ls "$APPS")" "Awake.app"
same "настройка пережила обновление" "$(suite_key App.awake.Enabled)" "1"
check "подпись обновлённого цела" codesign --verify --deep --strict "$APP"

echo "== подмена"
keep_awake "$PID"
expect "assertion до подмены" holds_assertion "$PID"
BEFORE="$(fingerprint)"
for forged in adhoc other-id; do
  if OUTPUT="$("$HUB" "$OUT" install "$OUT/$forged.json")"; then
    bad "$forged: установка прошла"
  else
    case "$OUTPUT" in
      *"не от автора"*) ok "$forged: отказ по подписи" ;;
      *) bad "$forged: отказ не по подписи: $OUTPUT" ;;
    esac
  fi
  same "$forged: бандл и плист те же" "$(fingerprint)" "$BEFORE"
  same "$forged: процесс тот же" "$(agent_pid)" "$PID"
  same "$forged: hello прежний" "$("$HUB" "$OUT" hello)" "$ID 1.1.0 3"
  check "$forged: assertion на месте" holds_assertion "$PID"
done

echo "== удаление"
check "assertion перед удалением" holds_assertion "$PID"
"$HUB" "$OUT" uninstall
check "бандла нет" test ! -e "$APP"
check "плиста нет" test ! -e "$AGENT"
expect "агента нет" no_label
expect "процесс вышел" has_exited "$PID"
check "assertion снята" no_assertion "$PID"
same "процессов из бандла нет" "$(pids_of "$EXE")" ""
if "$HUB" "$OUT" hello > /dev/null; then bad "после удаления связь отвечает"; else ok "после удаления связи нет"; fi
same "передача снята" "$(suite_key App.awake.HandedOver)" "нет"
same "настройка утилиты осталась" "$(suite_key App.awake.Enabled)" "1"

echo "== уборка"
cleanup
expect "launchctl list без local.utilitumus.app.*" no_label_listed
for pid in $seen_pids; do
  check "assertion процесса $pid нет" no_assertion "$pid"
done
OTHERS="$(pmset -g assertions | grep -F "$ASSERTION" || true)"
if [ -n "$OTHERS" ]; then echo "     (имя держит другой процесс, не из стенда: $OTHERS)"; fi
check "папки стенда нет" test ! -e "$OUT"
check "suite стенда нет" test ! -e "$HOME/Library/Preferences/$SUITE.plist"
same "настоящие App.awake.* и ModuleOn.awake те же" "$(real_keys)" "$REAL_KEYS_BEFORE"
same "настоящий центр не перезапускался" "$(pids_of "$REAL_HUB")" "$REAL_HUB_BEFORE"
check "в LaunchAgents плиста нет" test ! -e "$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$failures" -eq 0 ]; then echo "ЦЕНТР И УТИЛИТА: ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
