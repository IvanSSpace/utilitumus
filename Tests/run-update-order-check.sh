#!/bin/bash
# Порядок шагов обновления и удержание вентиляторов: настоящие UpdateBundle и FanController, поддельные SMC и служба.
# В сборке нет ни SMC.swift, ни FanHelperClient.swift: дойти до настоящего SMC или службы ей нечем (ниже проверяется по nm).
# Папка стенда: UPDATE_ORDER_CHECK_DIR, иначе $TMPDIR/update-order-check. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${UPDATE_ORDER_CHECK_DIR:-${TMPDIR:-/tmp}/update-order-check}"
SIGN_NAME="Utilitumus Signing"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

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
mkdir -p "$OUT/src" "$OUT/root" "$OUT/home"
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

cp Tests/UpdateOrderCheck.swift "$OUT/main.swift"
swiftc -target "$TARGET" -module-name UpdateOrderCheck -o "$OUT/update-order-check" "$OUT/main.swift" \
  Sources/App/UpdateBundle.swift Sources/Kit/KitSigning.swift \
  Sources/Modules/Fans/FanController.swift Sources/Modules/Fans/FanGate.swift -framework AppKit

if nm -u "$OUT/update-order-check" | grep -E 'IOConnect|IOService|NSXPCConnection'; then
  echo "ПРОВАЛ: стенд мог бы дойти до настоящего SMC или службы"
  exit 1
fi
echo "ok   nm: нет вызовов SMC и XPC"

# От настроек остаётся пустой файл домена этого бинарника: cfprefsd не смотрит на подменённую папку.
trap 'rm -f "$HOME/Library/Preferences/update-order-check.plist"' EXIT
# FanController пишет журнал в домашнюю папку: здесь она своя. Без неё проверка сама откажется работать.
CFFIXED_USER_HOME="$OUT/home" "$OUT/update-order-check" "$APP" "$OUT/root" "$OUT/home"
