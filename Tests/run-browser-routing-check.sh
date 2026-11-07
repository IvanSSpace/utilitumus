#!/bin/bash
# Куда ведёт ссылку модуль «Браузер»: логика без настроек и LaunchServices, плюс подпись и расположение на бандлах стенда.
# Бандлы не регистрируются в системе и не запускаются, браузер по умолчанию не меняется. Нужен сертификат «Utilitumus Signing».
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${BROWSER_CHECK_DIR:-${TMPDIR:-/tmp}/browser-routing-check}"
SIGN_NAME="Utilitumus Signing"
rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
F="$OUT/fixtures"

scripts/unlock-signing.sh
if ! security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  echo "ПРОВАЛ: нет сертификата «$SIGN_NAME»"
  exit 1
fi

echo 'int main(void) { return 0; }' | clang -x c -o "$OUT/exe" -
# fixture <путь>: бандл без codesign; у собранного файла только подпись компоновщика.
fixture() {
  local app="$F/$1"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$OUT/exe" "$app/Contents/MacOS/Fixture"
  echo данные >"$app/Contents/Resources/data.txt"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.utilitumus.test.browser</string>
<key>CFBundleExecutable</key><string>Fixture</string>
</dict></plist>
PLIST
}
signed() { fixture "$1"; codesign --force --sign "$SIGN_NAME" "$F/$1" 2>/dev/null; }

signed Applications/Signed.app
signed Applications/Cached.app
signed Applications/Sub/Signed.app
signed Elsewhere/Signed.app
signed Applications2/Signed.app
signed Applications/Stripped.app
codesign --remove-signature "$F/Applications/Stripped.app/Contents/MacOS/Fixture"
fixture Applications/Linker.app
fixture Applications/AdHoc.app
codesign --force --sign - "$F/Applications/AdHoc.app" 2>/dev/null
signed Applications/Tampered.app
echo подмена >"$F/Applications/Tampered.app/Contents/Resources/data.txt"
ln -s ../Elsewhere/Signed.app "$F/Applications/Link.app"
ln -s ../Elsewhere "$F/Applications/LinkDir"

# Зачем нужен сертификат, а не просто codesign --verify: что он скажет про ad-hoc.
if codesign --verify "$F/Applications/AdHoc.app" 2>/dev/null; then
  echo "ok   codesign --verify принимает ad-hoc (поэтому требуется сертификат)"
else
  echo "ПРОВАЛ: стенд: codesign --verify не принял ad-hoc, предпосылка проверки устарела"
  exit 1
fi

cp Tests/BrowserRoutingCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" Sources/Modules/Browser/BrowserRules.swift
"$OUT/check" "$F"
