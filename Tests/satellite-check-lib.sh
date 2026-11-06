# Общий каркас проверки модуля: подключается через source из Tests/run-<модуль>-*-check.sh.
#
#   source Tests/satellite-check-lib.sh
#   satellite_check_setup sound Sound
#   build_utility
#   build_module_hub Tests/SoundRemoteCheck.swift
#   start_agent
#   "$HUB" run "$OUT" "$(agent_pid)"
#   satellite_check_finish
#
# Метка launchd, id, домен настроек и папка выводятся из имени модуля, поэтому проверки разных модулей идут одновременно.
# Настоящие Utilitumus и его настройки не трогаются. Нужен сертификат «Utilitumus Signing».

satellite_check_setup() {
  MODULE="$1"
  NAME="$2"
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
  OUT="${SATELLITE_CHECK_DIR:-${TMPDIR:-/tmp}/satellite-check}/$MODULE"
  DOMAIN="gui/$(id -u)"
  ID="test.$MODULE"
  LABEL="local.utilitumus.test.$MODULE"
  IDENTIFIER="local.utilitumus.app.$ID"
  SERVICE="$IDENTIFIER.xpc"
  # Его читает Kit.defaults в сборке со швом: и центр стенда, и утилита (через плист).
  SUITE="local.utilitumus.test.kit.$MODULE"
  export KIT_TEST_SUITE="$SUITE"
  SIGN_NAME="Utilitumus Signing"
  PLIST="$OUT/$LABEL.plist"
  APP="$OUT/$NAME.app"
  EXE="$APP/Contents/MacOS/$NAME"
  LOG="$OUT/agent.log"
  HUB="$OUT/$MODULE-check-hub"
  FOREIGN="$OUT/$MODULE-check-foreign"
  failures=0
  # Подпись как в build.sh. Без этого codesign ждёт разблокировку связки и висит молча.
  local kc_password="$HOME/.config/utilitumus/keychain-password" kc="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
  if [ -f "$kc_password" ] && [ -f "$kc" ]; then security unlock-keychain -p "$(cat "$kc_password")" "$kc"; fi
  mkdir -p "$OUT/src" "$OUT/png"
  rm -f "$OUT"/png/*.png
  trap 'exit 1' HUP INT TERM
  trap satellite_check_cleanup EXIT
  satellite_reset_suite
}

satellite_reset_suite() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}

# Дополняется модулем: satellite_check_extra_cleanup() { ...; }
satellite_check_cleanup() {
  if declare -F satellite_check_extra_cleanup > /dev/null; then satellite_check_extra_cleanup; fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  satellite_reset_suite
  for name in "$MODULE-check-hub" "$MODULE-check-foreign"; do
    defaults delete "$name" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$name.plist"
  done
}

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$3», получили «$2»"; fi; }

# Таймера в модели и на её экранах быть не должно: grep 0 — нашёл, 1 — пусто, больше — ошибка самого grep.
forbid_timers() {
  local status=0 found
  found="$(grep -nE 'Timer|asyncAfter|DispatchSource|Task\.sleep|\.wait\(|DispatchSemaphore' "$@")" || status=$?
  case "$status" in
    0) echo "ПРОВАЛ: модель вкладки ждёт или опрашивает:"; echo "$found"; exit 1 ;;
    1) ok "в модели вкладки нет таймеров и синхронных ожиданий" ;;
    *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
  esac
}

build_utility() {
  scripts/build-app.sh "$ID" "$NAME" 1.2.3 "$OUT" --test-seam
}

# Центр стенда из всех исходников центра. Подпись: $HUB как центр, $FOREIGN с чужим identifier.
build_module_hub() {
  local check="$1"
  # Настоящий `ModuleDetail` из настоящего файла; точка входа у стенда своя.
  sed '/^@main$/d' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
  cp "$check" Tests/SatelliteCheckKit.swift Tests/SatelliteStandKit.swift "$OUT/src/"
  swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name "${NAME}ModuleCheck" -o "$OUT/hub-build" \
    "$OUT/src/$(basename "$check")" "$OUT/src/SatelliteCheckKit.swift" "$OUT/src/SatelliteStandKit.swift" "$OUT/src/UtilitumusApp.swift" \
    $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' -not -name UtilitumusApp.swift) \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfo.plist
  sign_hub
}

sign_hub() {
  cp "$OUT/hub-build" "$HUB"
  codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus "$HUB" 2>/dev/null
  cp "$OUT/hub-build" "$FOREIGN"
  codesign --force --options runtime --sign "$SIGN_NAME" --identifier "$IDENTIFIER.foreign" "$FOREIGN" 2>/dev/null
}

# Снимает прошлый агент, ставит новый. RunAtLoad как в настоящем плисте утилиты.
# THROTTLE — через сколько секунд launchd поднимет утилиту заново, если она прожила меньше 10 с.
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
<key>EnvironmentVariables</key><dict><key>KIT_TEST_SUITE</key><string>$SUITE</string></dict>
${THROTTLE:+<key>ThrottleInterval</key><integer>$THROTTLE</integer>}
</dict></plist>
PLIST_EOF
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
    sleep 0.3
  done
  for _ in $(seq 1 50); do [ -n "$(agent_pid)" ] && return 0; sleep 0.1; done
  echo "ПРОВАЛ: агент не запустился"
  exit 1
}
agent_pid() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}'; }

# Чужая подпись: действие не проходит, состояние и процесс те же. После start_agent и хотя бы одной сборки центра.
check_foreign_rejected() {
  local before output pid
  pid="$(agent_pid)"
  for _ in $(seq 1 50); do before="$("$HUB" state)"; [ -n "$before" ] && break; sleep 0.1; done
  [ -n "$before" ] || { echo "ПРОВАЛ: утилита не ответила центру"; exit 1; }
  if output="$("$FOREIGN" foreign)"; then
    bad "moduleAction с чужим identifier прошёл: $output"
  else
    ok "moduleAction с чужим identifier: $output"
  fi
  same "после отказа состояние то же" "$("$HUB" state)" "$before"
  same "после отказа тот же процесс" "$(agent_pid)" "$pid"
}

# Завершает проверку: снимает метку и говорит итог. Первый аргумент — как назвать проверку.
satellite_check_finish() {
  satellite_check_cleanup
  local list
  for _ in $(seq 1 50); do
    list="$(launchctl list)"
    [[ "$list" == *"$LABEL"* ]] || break
    sleep 0.1
  done
  list="$(launchctl list)"
  if [[ "$list" == *"$LABEL"* ]]; then bad "метка $LABEL осталась"; else ok "launchctl list без $LABEL"; fi
  if [ "$failures" -eq 0 ]; then echo "$1: ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
}
