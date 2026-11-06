#!/bin/bash
# Обновление центра: режимы файлов и повторная проверка копии в UpdateBundle, режимы в основном пути install.sh.
# curl, osascript и open в install.sh подменены, INSTALL_DIR в папке стенда: настоящее приложение не затрагивается.
# Папка стенда: UPDATE_CHECK_DIR, иначе $TMPDIR/update-bundle-check. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${UPDATE_CHECK_DIR:-${TMPDIR:-/tmp}/update-bundle-check}"
SIGN_NAME="Utilitumus Signing"

KC_PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KC="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
if [ -f "$KC_PASSWORD_FILE" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$KC_PASSWORD_FILE")" "$KC"
fi
if ! security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  echo "ПРОВАЛ: нет сертификата «$SIGN_NAME»"
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/root" "$OUT/bin"
OUT="$(cd "$OUT" && pwd -P)"

# Подписанная сборка-заглушка с настоящим identifier: не запускается, только проверяется и копируется.
APP="$OUT/src/Utilitumus.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo данные >"$APP/Contents/Resources/data.txt"
echo 'int main(void) { return 0; }' >"$OUT/stub.c"
clang -o "$APP/Contents/MacOS/Utilitumus" "$OUT/stub.c"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.utilitumus</string>
<key>CFBundleExecutable</key><string>Utilitumus</string>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
</dict></plist>
PLIST
codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus "$APP"

cp Tests/UpdateBundleCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" Sources/App/UpdateBundle.swift Sources/Kit/KitSigning.swift
"$OUT/check" "$APP" "$OUT/root"

# install.sh, основной путь: архив подставляет curl-заглушка.
cat >"$OUT/bin/curl" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then cp "$FAKE_ZIP" "$2"; exit 0; fi
  shift
done
exit 1
STUB
printf '#!/bin/bash\nexit 0\n' >"$OUT/bin/osascript"
printf '#!/bin/bash\nexit 0\n' >"$OUT/bin/open"
chmod +x "$OUT/bin/curl" "$OUT/bin/osascript" "$OUT/bin/open"

fail() { echo "ПРОВАЛ: $1"; exit 1; }
run_install() { # архив, папка установки; вывод в $OUT/install.log
  PATH="$OUT/bin:$PATH" FAKE_ZIP="$1" INSTALL_DIR="$2" NO_OPEN=1 bash install.sh >"$OUT/install.log" 2>&1
}

ditto -c -k --keepParent "$APP" "$OUT/good.zip"
mkdir -p "$OUT/inst"
run_install "$OUT/good.zip" "$OUT/inst" || { cat "$OUT/install.log"; fail "install.sh не поставил подписанную сборку"; }
[ -x "$OUT/inst/Utilitumus.app/Contents/MacOS/Utilitumus" ] || fail "install.sh: приложение не на месте"
echo "ok   install.sh ставит подписанную сборку"

WIDE="$OUT/wide/Utilitumus.app"
mkdir -p "$OUT/wide"
cp -R "$APP" "$WIDE"
chmod 0777 "$WIDE/Contents/Resources/data.txt"
codesign --verify --deep --strict "$WIDE" || fail "стенд: подпись должна быть цела, режимы ею не запечатаны"
ditto -c -k --keepParent "$WIDE" "$OUT/wide.zip"
mkdir -p "$OUT/inst2/Utilitumus.app"
echo старая >"$OUT/inst2/Utilitumus.app/old.txt"
if run_install "$OUT/wide.zip" "$OUT/inst2"; then fail "install.sh поставил сборку с правами 0777"; fi
grep -q 'запись разрешена' "$OUT/install.log" || { cat "$OUT/install.log"; fail "install.sh: нет сообщения о режимах"; }
[ -f "$OUT/inst2/Utilitumus.app/old.txt" ] || fail "install.sh: прежняя версия удалена до отказа"
echo "ok   install.sh отказывается от файла 0777 и не трогает прежнюю версию"
