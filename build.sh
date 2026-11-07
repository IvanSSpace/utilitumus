#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Только для scripts/build-pilot.sh: аргумент, а не переменная окружения, чтобы случайно окружение release.sh
# и CI подменить адрес каталога не могло. Такая сборка не ставится.
PILOT_ARGS=()
if [ $# -eq 2 ] && [ "$1" = "--pilot-catalog-source" ]; then
  [ -n "${NO_INSTALL:-}" ] || { echo "Сборку пилота ставит автор: нужен NO_INSTALL=1." >&2; exit 1; }
  PILOT_ARGS=(-D KIT_PILOT_CATALOG "$2")
elif [ $# -ne 0 ]; then
  echo "Использование: ./build.sh" >&2
  exit 1
fi

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
scripts/unlock-signing.sh
if security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  SIGN_ID="$SIGN_NAME"
else
  SIGN_ID="-"
  echo "⚠️  Сертификата «${SIGN_NAME}» нет — подпись ad-hoc, разрешения macOS слетят после пересборки."
fi

# Список исходников центра, до чистки папки: если scripts/hub-sources.sh упал, сборка останавливается здесь и прошлая сборка цела.
HUB_LIST="$(scripts/hub-sources.sh)"
HUB_FILES=()
while IFS= read -r f; do HUB_FILES+=("$f"); done <<<"$HUB_LIST"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Быстрая сборка без оптимизации — scripts/dev.sh; здесь всегда -O.
swiftc -O -parse-as-library -target "$TARGET" ${PILOT_ARGS[@]+"${PILOT_ARGS[@]}"} \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  "${HUB_FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio

# Помощник ссылок «Utilitumus Links» — браузер по умолчанию для модуля «Браузер». Отдельное
# приложение без окна и Dock: macOS активирует получателя ссылки, и будь им сам Utilitumus,
# вперёд выходило бы главное окно.
LINKS_APP="$APP_BUNDLE/Contents/Helpers/Utilitumus Links.app"
mkdir -p "$LINKS_APP/Contents/MacOS" "$LINKS_APP/Contents/Resources"
swiftc -O -target "$TARGET" \
  -o "$LINKS_APP/Contents/MacOS/UtilitumusLinks" \
  Sources/LinkHelper/main.swift \
  Sources/Modules/Browser/UI/BrowserCatalog.swift Sources/Modules/Browser/UI/BrowserRules.swift \
  Sources/Modules/Browser/BrowserPicker.swift Sources/Modules/Browser/BrowserRouter.swift \
  -framework SwiftUI -framework AppKit
cp Sources/LinkHelper/Info.plist "$LINKS_APP/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" Info.plist)" "$LINKS_APP/Contents/Info.plist"
done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$LINKS_APP/Contents/Resources/"
# identifier явно: Updater и install.sh сверяют именно его.
codesign --force --options runtime --sign "$SIGN_ID" --identifier local.utilitumus.links "$LINKS_APP"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
cp Resources/WhatsNew.json "$APP_BUNDLE/Contents/Resources/"

# Без entitlements: микрофон, захват звука и Apple Events нужны только утилитам, центр их не просит.
codesign --force --options runtime --sign "$SIGN_ID" "$APP_BUNDLE"

echo "Собрано: $APP_BUNDLE"

# В CI (GitHub Actions) только собираем — ставить в /Applications некуда.
[ -n "${NO_INSTALL:-}" ] && exit 0

INSTALLED="/Applications/$APP_NAME.app"
# Сначала штатный выход; pkill — только если не вышло.
pgrep -qf "$INSTALLED/Contents/MacOS/$APP_NAME" && osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1
pkill -f "$INSTALLED/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# Помощник ссылок живёт внутри бандла — его тоже, иначе работает старая копия.
pkill -f "$INSTALLED/Contents/Helpers/" 2>/dev/null || true
rm -rf "$INSTALLED"
cp -R "$APP_BUNDLE" "$INSTALLED"
echo "Установлено: $INSTALLED"
