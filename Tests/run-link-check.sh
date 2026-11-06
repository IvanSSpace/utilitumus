#!/bin/bash
# Связь центра и утилиты: чистая логика, затем подписанные бинарники под launchd.
# Папка стенда: LINK_CHECK_DIR, иначе $TMPDIR/link-check. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${LINK_CHECK_DIR:-${TMPDIR:-/tmp}/link-check}"
DOMAIN="gui/$(id -u)"

# Метка launchd только тестовая; Mach-сервис и identifier сервера — как их даёт KitLink для id test.link.
LABEL="local.utilitumus.test.link"
SERVICE="local.utilitumus.app.test.link.xpc"
SERVER_ID="local.utilitumus.app.test.link"
PEER_ID="local.utilitumus.test.link.hub"
FOREIGN_ID="local.utilitumus.test.link.foreign"
SIGN_NAME="Utilitumus Signing"
PLIST="$OUT/$LABEL.plist"

cleanup() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
}
trap 'exit 1' HUP INT TERM
trap cleanup EXIT

# Без данных в уведомлениях и без синхронных ожиданий: grep 0 — нашёл, 1 — пусто, больше — ошибка самого grep.
forbid() {
  local status=0 found
  found="$(grep -rnE "$1" Sources/Kit/Link)" || status=$?
  case "$status" in
    0) echo "ПРОВАЛ: $2:"; echo "$found"; exit 1 ;;
    1) echo "ok   $2: нет" ;;
    *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
  esac
}
forbid 'userInfo' 'userInfo в Sources/Kit/Link'
forbid 'synchronousRemoteObjectProxy|DispatchSemaphore|DispatchGroup|\.wait\(' 'синхронное ожидание в Sources/Kit/Link'

mkdir -p "$OUT"
SOURCES="Sources/Kit/KitSigning.swift Sources/Kit/KitDefaults.swift $(find Sources/Kit/Link -name '*.swift')"

# Модули с разными именами, как у центра и утилит: протокол не должен зависеть от имени модуля.
mkdir -p "$OUT/src"
cp Tests/LinkCheck.swift "$OUT/src/main.swift"
# Метка выпуска: без бандла Info.plist лежит в самом бинарнике.
MARKED=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfo.plist)
swiftc -O -target "$TARGET" -module-name LinkCheckClient -o "$OUT/client-build" "$OUT/src/main.swift" $SOURCES "${MARKED[@]}"
swiftc -O -target "$TARGET" -module-name LinkCheckServer -o "$OUT/server-build" "$OUT/src/main.swift" $SOURCES "${MARKED[@]}"
# Без метки: другое имя ключа той же длины, остальное в файле то же.
unmark() { perl -0777 -pe 's#<key>UtilitumusSecurityEpoch</key>#<key>UtilitumusSecurityEpocX</key>#' "$OUT/$1-build" > "$OUT/$1-unmarked-build"; chmod +x "$OUT/$1-unmarked-build"; }
unmark client
unmark server

echo "== чистая логика"
"$OUT/client-build"

# Подпись как в build.sh.
KC_PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KC="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
if [ -f "$KC_PASSWORD_FILE" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$KC_PASSWORD_FILE")" "$KC"
fi
if ! security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  echo "ПРОВАЛ: нет сертификата «$SIGN_NAME»"
  exit 1
fi

# signed <откуда> <куда> <подпись> <identifier>
signed() {
  cp "$OUT/$1-build" "$OUT/$2"
  codesign --force --options runtime --sign "$3" --identifier "$4" "$OUT/$2" 2>/dev/null
}
signed server server        "$SIGN_NAME" "$SERVER_ID"
signed server fake-adhoc    -            "$SERVER_ID"
signed server fake-foreign  "$SIGN_NAME" "$FOREIGN_ID"
signed server fake-ours     "$SIGN_NAME" "$SERVER_ID"
signed client client        "$SIGN_NAME" "$PEER_ID"
signed client rogue-adhoc   -            "$PEER_ID"
signed client rogue-foreign "$SIGN_NAME" "$FOREIGN_ID"
signed client-unmarked rogue-unmarked "$SIGN_NAME" "$PEER_ID"
signed server-unmarked fake-unmarked  "$SIGN_NAME" "$SERVER_ID"
# Как старый выпуск: наш сертификат, нужный identifier, без метки и без hardened runtime.
cp "$OUT/client-unmarked-build" "$OUT/rogue-old"
codesign --force --sign "$SIGN_NAME" --identifier "$PEER_ID" "$OUT/rogue-old" 2>/dev/null

# agent <программа и её аргументы>: снимает прошлый агент, ставит этот, журнал вызовов с нуля.
agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  : > "$OUT/calls.log"
  : > "$OUT/connections.log"
  rm -f "$OUT/hang"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    echo "<key>Label</key><string>$LABEL</string>"
    echo '<key>ProgramArguments</key><array>'
    for arg in "$@"; do echo "<string>$arg</string>"; done
    echo '</array>'
    echo "<key>MachServices</key><dict><key>$SERVICE</key><true/></dict>"
    echo "<key>StandardErrorPath</key><string>$OUT/agent.log</string>"
    if [ -n "${THROTTLE:-}" ]; then echo "<key>ThrottleInterval</key><integer>$THROTTLE</integer>"; fi
    echo '</dict></plist>'
  } > "$PLIST"
  # launchd отпускает метку не сразу после bootout.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && return 0
    sleep 0.3
  done
  echo "ПРОВАЛ: launchctl bootstrap $LABEL"
  exit 1
}
real_server() { agent "$OUT/server" server "$OUT" --peer "$PEER_ID"; }
fake() { agent "$OUT/$1" fake "$OUT" "$2"; }
scenario() { echo "== $1 ($2)"; "$OUT/$1" client "$2" "$OUT"; }

real_server
scenario client basic
: > "$OUT/calls.log"
scenario rogue-adhoc rogue
scenario rogue-foreign rogue
scenario rogue-unmarked rogue
scenario rogue-old rogue
echo "== настоящий клиент после rogue"
: > "$OUT/calls.log"
scenario client basic

real_server
scenario client hang-hello
real_server
scenario client hang-status
real_server
scenario client hang-action

real_server
scenario client killed

# Без задержки перезапуска: иначе первый вызов после kill истечёт по сроку, соединение закроется по этой
# причине, и сценарий не проверит, что клиент сам замечает смерть сервиса.
THROTTLE=0 real_server
scenario client killed-idle

real_server
scenario client quit
state="$(launchctl print "$DOMAIN/$LABEL" | grep -m1 'state = ' || true)"
case "$state" in
  *"not running"*) echo "ok   после quit launchd его не перезапустил:$state" ;;
  *) echo "ПРОВАЛ: после quit$state"; exit 1 ;;
esac

fake fake-adhoc ok
scenario client rejected
fake fake-foreign ok
scenario client rejected
fake fake-unmarked ok
scenario client rejected
fake fake-adhoc ok
scenario client rejected-race
fake fake-ours silent
scenario client silent
fake fake-ours v99
scenario client v99
fake fake-ours garbage
scenario client garbage

cleanup
# Список в переменной: `launchctl list | grep -q` при pipefail падает от SIGPIPE и выглядит как «метки нет».
listed() {
  local list
  list="$(launchctl list)"
  [[ "$list" == *"$LABEL"* ]]
}
# bootout снимает метку не сразу.
for _ in $(seq 1 50); do
  listed || break
  sleep 0.1
done
if listed; then
  echo "ПРОВАЛ: метка $LABEL осталась"
  exit 1
fi
echo "ok   launchctl list без $LABEL"
echo "СВЯЗЬ: ВСЁ ОК"
