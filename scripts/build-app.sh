#!/bin/bash
# Собирает отдельную утилиту из Sources/Apps/<Имя>, Sources/Modules/<Имя> и Sources/Kit.
#   scripts/build-app.sh awake Awake 1.0.0 build/apps
# Пятый аргумент --test-seam только для стендов: настройки в своём suite, состояние центра подставное.
set -euo pipefail
# Установщик отвергает архив с файлами, доступными на запись группе или всем.
umask 022

SWIFT_FLAGS=()
if [ $# -eq 5 ] && [ "$5" = "--test-seam" ]; then
  SWIFT_FLAGS=(-D KIT_TEST_DEFAULTS)
elif [ $# -ne 4 ]; then
  echo "Использование: scripts/build-app.sh <id> <Имя> <версия> <каталог-вывода> [--test-seam]" >&2
  exit 1
fi
ID="$1"
NAME="$2"
VERSION="$3"
OUT_DIR="$4"

fail() { echo "$1" >&2; exit 1; }
# Вне UTF-8: диапазон [a-z] не должен зависеть от языка системы.
matches() { local LC_ALL=C; [[ "$1" =~ $2 ]]; }

# Те же правила, что у SatelliteCatalog.isValidID и isValidVersion: иначе каталог не прочитается.
matches "$ID" '^[a-z0-9][a-z0-9.-]*$' || fail "Недопустимый id: ${ID}"
matches "$VERSION" '^[0-9]+(\.[0-9]+)*$' || fail "Недопустимая версия: ${VERSION}"
# Имя становится именем модуля swiftc, путём и именем ассета: GitHub заменяет в нём пробелы и не-ASCII.
matches "$NAME" '^[A-Za-z][A-Za-z0-9]*$' || fail "Недопустимое имя: ${NAME}"

# Относительный путь — от папки вызывающего, а не от корня репозитория.
case "$OUT_DIR" in
  /*) ;;
  *) OUT_DIR="$PWD/$OUT_DIR" ;;
esac
cd "$(dirname "$0")/.."

for path in "Sources/Apps/$NAME/Info.plist" "Sources/Modules/$NAME" Sources/Kit; do
  [ -e "$path" ] || fail "Нет ${path}"
done

MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

# Подпись как в build.sh: нет сертификата (CI) — ad-hoc. Выкладывать такое не даст release-app.sh.
SIGN_NAME="Utilitumus Signing"
KC_PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KC="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
if [ -f "$KC_PASSWORD_FILE" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$KC_PASSWORD_FILE")" "$KC"
fi
if [[ "$(security find-identity -p codesigning)" == *"\"$SIGN_NAME\""* ]]; then
  SIGN_ID="$SIGN_NAME"
else
  SIGN_ID="-"
  echo "⚠️  Сертификата «${SIGN_NAME}» нет — подпись ad-hoc." >&2
fi

# Только сам бандл: в папке вывода может лежать чужое.
APP="$OUT_DIR/$NAME.app"
rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Без -parse-as-library: точка входа утилиты — Sources/Apps/<Имя>/main.swift.
swiftc -O -target "arm64-apple-macos$MIN_SYSTEM" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
  -o "$APP/Contents/MacOS/$NAME" \
  $(find "Sources/Apps/$NAME" "Sources/Modules/$NAME" Sources/Kit -name '*.swift') \
  -framework SwiftUI -framework AppKit

INFO="$APP/Contents/Info.plist"
cp "Sources/Apps/$NAME/Info.plist" "$INFO"
# -replace, а не Set из PlistBuddy: добавит ключ, которого нет.
plutil -replace CFBundleIdentifier -string "local.utilitumus.app.$ID" "$INFO"
plutil -replace CFBundleExecutable -string "$NAME" "$INFO"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO"
plutil -replace CFBundleVersion -string "$VERSION" "$INFO"
plutil -replace LSMinimumSystemVersion -string "$MIN_SYSTEM" "$INFO"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  plutil -replace CFBundleIconFile -string AppIcon "$INFO"
fi

codesign --force --options runtime --sign "$SIGN_ID" --identifier "local.utilitumus.app.$ID" "$APP"

echo "Собрано: $APP"
