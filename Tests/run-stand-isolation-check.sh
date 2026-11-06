#!/bin/bash
# Стенды (сборки со швом KIT_TEST_DEFAULTS) живут под launchd с настоящим домом и не должны задеть ничего настоящего.
# Три части:
#   1. утилита шва под launchd с подставным домом: NSHomeDirectory, homeDirectoryForCurrentUser и urls(for:) отдают временный дом;
#      охрана Kit.assertStandPath роняет процесс на настоящем пути;
#   2. охрана по исходникам: новый API с настоящими путями или внешними действиями в Sources/Modules и Sources/Apps
#      обязан попасть в Tests/stand-reviewed-paths.txt, то есть пройти разбор («шов есть» или «отказ в стенде»);
#   3. снимок настоящих мест до и после (имена, размеры, mtime; содержимое не читается).
# Не нужен сертификат: пробный процесс без подписи, меток Mach нет.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source Tests/stand-snapshot.sh
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${STAND_ISOLATION_DIR:-${TMPDIR:-/tmp}/stand-isolation-check}"
DOMAIN="gui/$(id -u)"
LABEL="local.utilitumus.test.isolation"
PLIST="$OUT/$LABEL.plist"
failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$3», получили «$2»"; fi; }
cleanup() { launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
rm -rf "$OUT"; mkdir -p "$OUT/src" "$OUT/home/Library"

stand_snapshot_take "$OUT/before.txt"

# 1. Пробный процесс шва
cp Tests/StandIsolationProbe.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name StandIsolationProbe -o "$OUT/probe" \
  "$OUT/src/main.swift" Sources/Kit/KitDefaults.swift -framework ApplicationServices 2>&1 | tail -5
[ -x "$OUT/probe" ] || { echo "ПРОВАЛ: probe не собрался"; exit 1; }
HOME_REAL="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$OUT/probe</string><string>$OUT/probe.txt</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
<key>EnvironmentVariables</key><dict><key>KIT_TEST_SUITE</key><string>local.utilitumus.test.kit.isolation</string><key>CFFIXED_USER_HOME</key><string>$OUT/home</string><key>HOME</key><string>$OUT/home</string></dict>
</dict></plist>
PLIST_EOF
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST" || { echo "ПРОВАЛ: launchctl bootstrap"; exit 1; }
for _ in $(seq 1 50); do [ -s "$OUT/probe.txt" ] && break; sleep 0.1; done
[ -s "$OUT/probe.txt" ] || { echo "ПРОВАЛ: probe под launchd не ответил"; exit 1; }
FAKE="$(cd "$OUT/home" && pwd -P)"
val() { sed -n "s/^$1=//p" "$OUT/probe.txt"; }
canon() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }
same "под launchd NSHomeDirectory — временный дом" "$(canon "$(val home)")" "$FAKE"
same "homeDirectoryForCurrentUser — временный дом" "$(canon "$(val homeURL)")" "$FAKE"
same "Application Support — во временном доме" "$(val appSupport | sed "s#^$OUT/home#X#; s#^/private##; s#^.*/stand-isolation-check/home#X#")" "X/Library/Application Support"
same "Library — во временном доме" "$(canon "$(val library)")" "$FAKE/Library"
same "настоящий дом по getpwuid остался настоящим (его закрывает охрана)" "$(val realHome)" "$HOME_REAL"
same "охрана: временное разрешено" "$(val guardTemp)" "ok"
same "охрана: подставной дом разрешён" "$(val guardHomeFake)" "ok"
same "охрана: /Applications закрыт" "$(val guardApplications)" "/Applications"
same "охрана: /Library закрыт" "$(val guardLibrary)" "/Library"
same "охрана: настоящие журналы закрыты" "$(val guardRealLogs)" "$HOME_REAL"
same "охрана: тестовые настройки local.utilitumus.test.* разрешены" "$(val guardTestPrefs)" "ok"
if ( "$OUT/probe" real-write ) > "$OUT/crash.txt" 2>&1; then bad "assertStandPath не уронил процесс на настоящем пути"; else ok "assertStandPath роняет процесс на настоящем пути"; fi
cleanup
if launchctl list | /usr/bin/grep -q "$LABEL"; then bad "метка $LABEL осталась"; else ok "launchctl list без $LABEL"; fi

# 2. Охрана по исходникам
TOKENS=('homeDirectoryForCurrentUser' 'NSHomeDirectory' 'NSSearchPathForDirectories' 'urls(for:' 'getpwuid' '"~/' '"/Applications' '"/Library'
  'UserDefaults(suiteName' 'UserDefaults.standard' 'SecItem' 'NSPasteboard.general' 'Process()' '.terminate()' 'forceTerminate()' 'kill(' 'launchctl'
  'LSRegisterURL' 'setDefaultApplication' 'AudioObjectSetPropertyData' 'CFPreferences' 'osascript' 'NSAppleScript' 'removeItem' 'TISSelectInputSource'
  'NSWorkspace.shared.open' 'NSWorkspace.shared.openApplication')
: > "$OUT/found.txt"
for token in "${TOKENS[@]}"; do
  /usr/bin/grep -rlF --include='*.swift' -- "$token" Sources/Modules Sources/Apps | while read -r file; do
    # строки с комментариями не считаются
    if /usr/bin/grep -F -- "$token" "$file" | /usr/bin/grep -vE '^[[:space:]]*//' | /usr/bin/grep -q .; then echo "$file|$token"; fi
  done
done | LC_ALL=C sort -u > "$OUT/found.txt"
REVIEWED="$OUT/reviewed.txt"
/usr/bin/grep -vE '^[[:space:]]*(#|$)' Tests/stand-reviewed-paths.txt | LC_ALL=C sort -u > "$REVIEWED"
NEW="$(comm -13 "$REVIEWED" "$OUT/found.txt")"
if [ -n "$NEW" ]; then
  bad "новый API с настоящим путём или внешним действием не разобран (добавь шов или отказ и впиши в Tests/stand-reviewed-paths.txt):"
  echo "$NEW" | sed 's/^/     /'
else
  ok "в Sources/Modules и Sources/Apps нет неразобранных настоящих путей ($(wc -l < "$OUT/found.txt" | tr -d ' ') разобрано)"
fi

# 3. Снимок настоящих мест
stand_snapshot_compare "$OUT/before.txt" || failures=$((failures + 1))

if [ "$failures" -eq 0 ]; then echo "стенд изолирован: ВСЁ ОК"; else echo "ПРОВАЛОВ: $failures"; exit 1; fi
