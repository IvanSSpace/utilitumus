#!/bin/bash
# Основа модулей на утилите-пробе: модель, хост, протокол v3. Настоящие launchd, подпись и связь.
# Имя пробы — аргумент: метка, домен и папка выводятся из него, поэтому две пробы идут одновременно.
# Tests/run-satellite-base-check.sh [имя]   Папка стенда: SATELLITE_CHECK_DIR.
set -euo pipefail
umask 022
source "$(dirname "$0")/satellite-check-lib.sh"
PROBE="${1:-probe}"
satellite_check_setup "$PROBE" Probe

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift

# Единственные места с уведомлением, видным всем: о состоянии оно не сообщает.
status=0
FOUND="$(grep -rn 'DistributedNotificationCenter' Sources/Kit Sources/App/Satellites | grep -vE 'Sources/Kit/Link/(LinkProtocol|LinkClient)\.swift|SatelliteRegistry\.swift')" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: уведомление, видное всем, вне связи:"; echo "$FOUND"; exit 1 ;;
  *) ok "уведомления, видные всем, только у связи и реестра" ;;
esac

printf 'let probeName = "%s"\n' "$PROBE" > "$OUT/src/ProbeName.swift"
printf 'MainActor.assumeIsolated { SatelliteMain.run(ProbeModule()) }\n' > "$OUT/src/main.swift"

# Утилита-проба: как build-app.sh, только источники из Tests. Метка выпуска и остальное — из Info.plist «Не спать».
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name Probe -o "$EXE" \
  "$OUT/src/main.swift" "$OUT/src/ProbeName.swift" Tests/SatelliteProbe.swift Tests/SatelliteProbeWire.swift \
  $(find Sources/Kit -name '*.swift') -framework SwiftUI -framework AppKit
cp Sources/Apps/Awake/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$IDENTIFIER" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Probe "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 1.2.3 "$APP/Contents/Info.plist"
codesign --force --options runtime --sign "$SIGN_NAME" --identifier "$IDENTIFIER" "$APP"

swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name ProbeCheck -o "$OUT/hub-build" \
  Tests/SatelliteBaseCheck.swift Tests/SatelliteCheckKit.swift Tests/SatelliteProbeWire.swift "$OUT/src/ProbeName.swift" \
  Sources/App/Satellites/RemoteModuleModel.swift $(find Sources/Kit -name '*.swift') -framework SwiftUI -framework AppKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfo.plist
sign_hub

echo "== модель и помощники на управляемой связи"
"$HUB" pure "$APP"

JOURNAL="$OUT/journal.log"
: > "$JOURNAL"
defaults write "$SUITE" Test.Journal -string "$JOURNAL"
defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
THROTTLE=1
start_agent

echo "== чужая подпись"
check_foreign_rejected

echo "== настоящая утилита"
"$HUB" live "$OUT" "$(agent_pid)"

satellite_check_finish "ОСНОВА МОДУЛЕЙ ($PROBE)"
