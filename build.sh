#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Utilitumus"
BUILD_DIR="${BUILD_DIR:-build}"  # своя папка — для параллельных сборок
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
# Явная минимальная версия: без -target swiftc берёт версию SDK машины
# сборки (macOS 26), и на 14.x/15.x приложение не запускается вообще.
# Должна совпадать с LSMinimumSystemVersion в Info.plist.
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

# Подпись. macOS привязывает разрешения («Универсальный доступ», запись звука)
# к подписи: ad-hoc подпись меняется с каждой сборкой, и разрешения слетают.
# Постоянный сертификат «Utilitumus Signing» (локально — ~/.config/utilitumus,
# в CI — из секретов) даёт одинаковую подпись у всех версий. Нет его — ad-hoc.
SIGN_NAME="Utilitumus Signing"
KC_PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KC="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
if [ -f "$KC_PASSWORD_FILE" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$KC_PASSWORD_FILE")" "$KC"
fi
if security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  SIGN_ID="$SIGN_NAME"
else
  SIGN_ID="-"
  echo "⚠️  Сертификата «$SIGN_NAME» нет — подпись ad-hoc, разрешения macOS слетят после пересборки."
fi

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

swiftc -O -parse-as-library -target "$TARGET" \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*') \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

# Root-помощник вентиляторов: отдельный бинарник, ставится кнопкой «Дать доступ».
swiftc -O -target "$TARGET" \
  -o "$APP_BUNDLE/Contents/MacOS/utilitumus-fan" \
  Sources/Shared/SMC.swift Sources/FanHelper/main.swift \
  -framework IOKit
codesign --force --sign "$SIGN_ID" --identifier local.utilitumus.fan "$APP_BUNDLE/Contents/MacOS/utilitumus-fan"

# Помощник ссылок «Utilitumus Links» — браузер по умолчанию для модуля «Браузер». Отдельное
# приложение без окна и Dock: macOS активирует получателя ссылки, и будь им сам Utilitumus,
# вперёд выходило бы главное окно.
LINKS_APP="$APP_BUNDLE/Contents/Helpers/Utilitumus Links.app"
mkdir -p "$LINKS_APP/Contents/MacOS" "$LINKS_APP/Contents/Resources"
swiftc -O -target "$TARGET" \
  -o "$LINKS_APP/Contents/MacOS/UtilitumusLinks" \
  Sources/LinkHelper/main.swift \
  Sources/Modules/Browser/BrowserCatalog.swift Sources/Modules/Browser/BrowserRules.swift \
  Sources/Modules/Browser/BrowserPicker.swift Sources/Modules/Browser/BrowserRouter.swift \
  -framework SwiftUI -framework AppKit
cp Sources/LinkHelper/Info.plist "$LINKS_APP/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" Info.plist)" "$LINKS_APP/Contents/Info.plist"
done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$LINKS_APP/Contents/Resources/"
codesign --force --sign "$SIGN_ID" "$LINKS_APP"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

codesign --force --sign "$SIGN_ID" "$APP_BUNDLE"

echo "Собрано: $APP_BUNDLE"

# В CI (GitHub Actions) только собираем — ставить в /Applications некуда.
[ -n "${NO_INSTALL:-}" ] && exit 0

INSTALLED="/Applications/$APP_NAME.app"
# Сначала штатный выход — чтобы отработал applicationWillTerminate (вентиляторы
# в «Авто»); pkill — только если не вышло.
pgrep -qf "$INSTALLED/Contents/MacOS/$APP_NAME" && osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1
pkill -f "$INSTALLED/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# Помощник ссылок живёт внутри бандла — его тоже, иначе работает старая копия.
pkill -f "$INSTALLED/Contents/Helpers/" 2>/dev/null || true
rm -rf "$INSTALLED"
cp -R "$APP_BUNDLE" "$INSTALLED"
echo "Установлено: $INSTALLED"
