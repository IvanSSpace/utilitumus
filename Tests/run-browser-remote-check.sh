#!/bin/bash
# Вкладка «Браузер»: экран рисует центр из общего домена, от утилиты только статус. Его отдаёт стенд, настоящая утилита не запускается.
# Браузер по умолчанию не меняется, помощник не собирается и не регистрируется. Папка стенда: SATELLITE_CHECK_DIR; снимки в browser/png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup browser Browser

forbid_timers Sources/App/Satellites/RemoteBrowserPage.swift

build_module_hub Tests/BrowserRemoteCheck.swift

# Реестр считает утилиту установленной по бандлу. Здесь только плист: запускать нечего, обработчиков ссылок в нём нет.
rm -rf "$APP"
mkdir -p "$APP/Contents"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
</dict></plist>
PLIST_EOF

echo "== вкладка"
"$HUB" run "$OUT" 0

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «БРАУЗЕР»"
