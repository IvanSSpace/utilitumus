#!/bin/bash
# Каталог и установщик утилит: подставные launchctl, download и связь с утилитой, настоящие zip и codesign.
# /Applications и ~/Library/LaunchAgents не трогаются: все пути — в папке стенда.
# Папка стенда: SATELLITE_CHECK_DIR, иначе $TMPDIR/satellite-installer-check. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SATELLITE_CHECK_DIR:-${TMPDIR:-/tmp}/satellite-installer-check}"
F="$OUT/fixtures"
IDENT="local.utilitumus.app.test.fixture"
NAME="Fixture"
SIGN_NAME="Utilitumus Signing"

# Тест не имеет права дотянуться до настоящих путей и настоящей связи; установщик — до настроек.
forbid() {
  local status=0 found
  found="$(grep -nE "$1" "$2")" || status=$?
  case "$status" in
    0) echo "ПРОВАЛ: $3:"; echo "$found"; exit 1 ;;
    1) echo "ok   $3: нет" ;;
    *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
  esac
}
status=0
found="$(grep -rnE '\.live|live[A-Z]' Tests --include='*.swift')" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: настоящие замыкания и пути в тестах:"; echo "$found"; exit 1 ;;
  1) echo "ok   настоящие замыкания и пути в тестах: нет" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac
forbid 'UserDefaults|Kit\.defaults' Sources/App/Satellites/SatelliteInstaller.swift 'настройки в установщике'

rm -rf "$OUT"
mkdir -p "$OUT/src" "$F"

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

echo 'int main(void) { return 0; }' | clang -x c -target "$TARGET" -o "$F/exe" -

# bundle <папка> <версия> [имя]: неподписанный бандл, внутри относительная ссылка в пределах бандла.
bundle() {
  local app="$1/${3:-$NAME}.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$F/exe" "$app/Contents/MacOS/$NAME"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    echo "<key>CFBundleIdentifier</key><string>$IDENT</string>"
    echo "<key>CFBundleExecutable</key><string>$NAME</string>"
    echo "<key>CFBundleShortVersionString</key><string>$2</string>"
    echo '</dict></plist>'
  } > "$app/Contents/Info.plist"
  echo data > "$app/Contents/Resources/data.txt"
  ln -s data.txt "$app/Contents/Resources/inner"
}
# sign <бандл> <подпись> <identifier>
sign() { codesign --force --options runtime --sign "$2" --identifier "$3" "$1" 2>/dev/null; }
# good <дело> <версия>: подписанный как надо бандл в своей папке.
good() {
  mkdir -p "$F/$1"
  bundle "$F/$1" "$2"
  sign "$F/$1/$NAME.app" "$SIGN_NAME" "$IDENT"
}
# pack <дело>: архив как у выпуска, `ditto -c -k --keepParent`.
pack() { ditto -c -k --keepParent "$F/$1/$NAME.app" "$F/$1.zip"; }

good v1 1.0.0; pack v1
good v2 2.0.0; pack v2

mkdir -p "$F/adhoc"; bundle "$F/adhoc" 2.0.0; sign "$F/adhoc/$NAME.app" - "$IDENT"; pack adhoc
mkdir -p "$F/foreign"; bundle "$F/foreign" 2.0.0; sign "$F/foreign/$NAME.app" "$SIGN_NAME" "local.utilitumus.app.test.other"; pack foreign
good tampered 2.0.0; echo '<!-- правка после подписи -->' >> "$F/tampered/$NAME.app/Contents/Info.plist"; pack tampered

# Ниже подпись настоящая: отказать должна проверка архива, а не подпись.
# ditto молча убирает `../` и кладёт такой архив как обычный, поэтому смотреть надо сам архив.
good traversal 2.0.0; mkdir "$F/traversal/sub"; (cd "$F/traversal/sub" && zip -qry "$F/traversal.zip" "../$NAME.app")
good two 2.0.0; good two-second 2.0.0; mv "$F/two-second/$NAME.app" "$F/two/Other.app"; (cd "$F/two" && zip -qry "$F/two.zip" "$NAME.app" Other.app)
good renamed 2.0.0; mv "$F/renamed/$NAME.app" "$F/renamed/Other.app"; (cd "$F/renamed" && zip -qry "$F/renamed.zip" Other.app)
good extra 2.0.0; echo x > "$F/extra/readme.txt"; (cd "$F/extra" && zip -qry "$F/extra.zip" "$NAME.app" readme.txt)
good link-rel 2.0.0; ln -s ../../../../outside "$F/link-rel/$NAME.app/Contents/Resources/out"; touch "$F/link-rel/outside"; (cd "$F/link-rel" && zip -qry "$F/link-rel.zip" "$NAME.app")
good link-abs 2.0.0; ln -s /etc "$F/link-abs/$NAME.app/Contents/Resources/out"; (cd "$F/link-abs" && zip -qry "$F/link-abs.zip" "$NAME.app")
good link-dangling 2.0.0; ln -s nowhere "$F/link-dangling/$NAME.app/Contents/Resources/out"; (cd "$F/link-dangling" && zip -qry "$F/link-dangling.zip" "$NAME.app")
good link-top 2.0.0; mv "$F/link-top/$NAME.app" "$F/link-top/real"; ln -s real "$F/link-top/$NAME.app"; (cd "$F/link-top" && zip -qy "$F/link-top.zip" "$NAME.app")
head -c 4096 /dev/urandom > "$F/garbage.zip"

# Режимы файлов подписью не запечатаны: подпись таких бандлов верна, отказать должна проверка архива.
good mode-exe 2.0.0; chmod 777 "$F/mode-exe/$NAME.app/Contents/MacOS/$NAME"; pack mode-exe
good mode-dir 2.0.0; chmod 775 "$F/mode-dir/$NAME.app/Contents/Resources"; pack mode-dir

# Подпись верна и с нужным identifier, но Info.plist говорит о другом приложении.
mkdir -p "$F/plist-id"; bundle "$F/plist-id" 2.0.0
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.utilitumus.app.test.other" "$F/plist-id/$NAME.app/Contents/Info.plist"
sign "$F/plist-id/$NAME.app" "$SIGN_NAME" "$IDENT"; pack plist-id

cp Tests/SatelliteInstallerCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -module-name SatelliteInstallerCheck -o "$OUT/check" "$OUT/src/main.swift" \
  Sources/Kit/KitSigning.swift Sources/Kit/KitDefaults.swift Sources/Kit/SatelliteCatalog.swift \
  $(find Sources/Kit/Link -name '*.swift') Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteAgent.swift

"$OUT/check" "$F" "$OUT/work" Catalog/catalog.json
