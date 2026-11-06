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

# Движок голосового ввода (sherpa-onnx, статически): скачивается один раз, хэши сверяются.
# Без интернета и без Vendor/ сборка останавливается здесь с понятной ошибкой.
scripts/fetch-sherpa.sh

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# DEV_OPT=-Onone — быстрая сборка центра для просмотра; выпускная всегда с -O.
swiftc "${DEV_OPT:--O}" -parse-as-library -target "$TARGET" ${PILOT_ARGS[@]+"${PILOT_ARGS[@]}"} \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  $(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*') \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

# Root-служба вентиляторов: отдельный бинарник, ставится кнопкой «Дать доступ». Только Foundation и IOKit;
# -wmo убирает из root-процесса всё, что не вызывается (остальное в KitSigning, вроде запуска процессов).
swiftc -O -wmo -target "$TARGET" \
  -o "$APP_BUNDLE/Contents/MacOS/utilitumus-fan" \
  Sources/Shared/SMC.swift Sources/Shared/FanLink.swift Sources/Kit/KitSigning.swift Sources/FanHelper/main.swift \
  -framework IOKit
# --options runtime (hardened runtime): в процесс нельзя внедрить чужой код через DYLD_* и подменённые библиотеки.
codesign --force --options runtime --sign "$SIGN_ID" --identifier local.utilitumus.fan "$APP_BUNDLE/Contents/MacOS/utilitumus-fan"

# Помощник голосового ввода: отдельный процесс, sherpa-onnx влинкован статически.
# Динамическую библиотеку под hardened runtime с нашим сертификатом загрузить нельзя
# (нужен disable-library-validation) — поэтому процесс, а не dylib. Без entitlements.
SHERPA="Vendor/sherpa-onnx"
clang -O2 -Wall -target "$TARGET" \
  -I "$SHERPA/include" \
  -o "$APP_BUNDLE/Contents/MacOS/utilitumus-voice" \
  Sources/VoiceHelper/main.c \
  "$SHERPA/lib/libsherpa-onnx-c-api.a" "$SHERPA/lib/libsherpa-onnx-core.a" \
  "$SHERPA/lib/libonnxruntime.a" "$SHERPA/lib/libkaldi-decoder-core.a" \
  "$SHERPA/lib/libkaldi-native-fbank-core.a" "$SHERPA/lib/libkissfft-float.a" \
  "$SHERPA/lib/libsherpa-onnx-fst.a" "$SHERPA/lib/libsherpa-onnx-fstfar.a" \
  "$SHERPA/lib/libsherpa-onnx-kaldifst-core.a" "$SHERPA/lib/libssentencepiece_core.a" \
  "$SHERPA/lib/libutf8proc.a" \
  -lc++ -framework Foundation -framework Accelerate -Wl,-dead_strip
codesign --force --options runtime --sign "$SIGN_ID" --identifier local.utilitumus.voice "$APP_BUNDLE/Contents/MacOS/utilitumus-voice"

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
# identifier явно: Updater и install.sh сверяют именно его.
codesign --force --options runtime --sign "$SIGN_ID" --identifier local.utilitumus.links "$LINKS_APP"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
cp Resources/WhatsNew.json "$APP_BUNDLE/Contents/Resources/"

codesign --force --options runtime --entitlements Utilitumus.entitlements --sign "$SIGN_ID" "$APP_BUNDLE"

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
