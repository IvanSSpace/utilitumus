#!/bin/bash
# Модель, связь и экран модуля «Мышь». Окно за экраном и прозрачное, tap не запускается, системный запрос доступа
# заглушён швом KIT_TEST_DEFAULTS. Настройки только в своём suite: параметры по умолчанию заменены в копии исходника.
# Экран «до» — MouseView из коммита перед переходом на модель. Папка стенда: MOUSE_WIRE_DIR, иначе $TMPDIR/mouse-wire-check.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MOUSE_WIRE_DIR:-${TMPDIR:-/tmp}/mouse-wire-check}"
SUITE="local.utilitumus.test.mouse-wire"
BEFORE=509cdb3

cleanup() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
trap cleanup EXIT
cleanup

rm -rf "$OUT/src"
mkdir -p "$OUT/src" "$OUT/png"
cp Tests/MouseWireCheck.swift "$OUT/src/MouseWireCheck.swift"
/usr/bin/git show "$BEFORE:Sources/Modules/Mouse/MouseView.swift" | sed 's/MouseView/LegacyMouseView/' > "$OUT/src/LegacyMouseView.swift"
sed -E 's/UserDefaults = (\.standard|Kit\.defaults)/UserDefaults = mouseCheckDefaults/' \
  Sources/Modules/Mouse/MouseScrollLogic.swift > "$OUT/src/MouseScrollLogic.swift"
[ "$(grep -c 'UserDefaults = mouseCheckDefaults' "$OUT/src/MouseScrollLogic.swift")" = 2 ] \
  || { echo "ПРОВАЛ: настройки модуля не переведены на suite стенда"; exit 1; }

swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name MouseWireCheck -o "$OUT/check" \
  "$OUT/src/MouseWireCheck.swift" "$OUT/src/LegacyMouseView.swift" "$OUT/src/MouseScrollLogic.swift" Sources/Apps/Mouse/MouseModule.swift \
  $(find Sources/Modules/Mouse -name '*.swift' -not -name MouseScrollLogic.swift) \
  $(find Sources/Kit -name '*.swift') Sources/App/Design/Pages.swift \
  -framework SwiftUI -framework AppKit -framework IOKit
"$OUT/check" "$OUT"
