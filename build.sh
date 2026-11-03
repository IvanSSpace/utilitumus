#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Utilitumus"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
# Явная минимальная версия: без -target swiftc берёт версию SDK машины
# сборки (macOS 26), и на 14.x/15.x приложение не запускается вообще.
# Должна совпадать с LSMinimumSystemVersion в Info.plist.
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

swiftc -O -parse-as-library -target "$TARGET" \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*') \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit -framework WebKit

# Root-помощник вентиляторов: отдельный бинарник, ставится кнопкой «Дать доступ».
swiftc -O -target "$TARGET" \
  -o "$APP_BUNDLE/Contents/MacOS/utilitumus-fan" \
  Sources/Shared/SMC.swift Sources/FanHelper/main.swift \
  -framework IOKit
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/utilitumus-fan"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
# Публичный lambscape для модуля «Нагрузка» (обновлять: scripts/update-lambscape.sh)
cp -R Vendor/lambscape "$APP_BUNDLE/Contents/Resources/lambscape"

codesign --force --deep --sign - "$APP_BUNDLE"

echo "Собрано: $APP_BUNDLE"

# В CI (GitHub Actions) только собираем — ставить в /Applications некуда.
[ -n "${NO_INSTALL:-}" ] && exit 0

INSTALLED="/Applications/$APP_NAME.app"
# Сначала штатный выход — чтобы отработал applicationWillTerminate (вентиляторы
# в «Авто», сервер lambscape остановлен); pkill — только если не вышло.
pgrep -qf "$INSTALLED/Contents/MacOS/$APP_NAME" && osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1
pkill -f "$INSTALLED/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -rf "$INSTALLED"
cp -R "$APP_BUNDLE" "$INSTALLED"
echo "Установлено: $INSTALLED"
