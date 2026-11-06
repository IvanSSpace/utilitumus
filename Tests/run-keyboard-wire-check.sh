#!/bin/bash
# Клавиатура: состояние, действия и их проверки, экран до и после переноса на модель. Окно за экраном и прозрачное.
# Настоящий InputSources.swift и App в стенд не собираются (Tests/KeyboardWireStubs.swift): 🌐, диктовка,
# TextInputSwitcher и текущая раскладка недоступны стенду. Настройки: домен самого файла и suite шва. Папка: KEYBOARD_WIRE_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${KEYBOARD_WIRE_DIR:-${TMPDIR:-/tmp}/keyboard-wire-check}"
# Экран до переноса на модель. Осознанное изменение вида — повод обновить этот коммит.
BASELINE=509cdb3
NAME=keyboard-wire-check
VIEW=Sources/Modules/Keyboard/KeyboardView.swift

cleanup() {
  defaults delete "$NAME" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$NAME.plist"
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/home" "$OUT/png"
SHOWN='s/@State private var logShown = false/@State private var logShown = testLogShown/'
sed "$SHOWN" "$VIEW" > "$OUT/src/KeyboardView.swift"
/usr/bin/git show "$BASELINE:$VIEW" | sed -e "$SHOWN" \
  -e 's/^struct KeyboardView: View {/struct BaselineKeyboardView: View {/' \
  -e 's/var controller = KeyboardController.shared/var controller = baselineModel/' > "$OUT/src/BaselineKeyboardView.swift"
for file in "$OUT/src/KeyboardView.swift" "$OUT/src/BaselineKeyboardView.swift"; do
  grep -q testLogShown "$file" || { echo "ПРОВАЛ: подстановка не сработала в $file"; exit 1; }
done
grep -q baselineModel "$OUT/src/BaselineKeyboardView.swift" || { echo "ПРОВАЛ: старый экран не подменён"; exit 1; }

swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name KeyboardWireCheck -o "$OUT/$NAME" \
  Tests/KeyboardWireCheck.swift Tests/KeyboardWireStubs.swift "$OUT/src/KeyboardView.swift" "$OUT/src/BaselineKeyboardView.swift" \
  $(find Sources/Modules/Keyboard -name '*.swift' -not -name InputSources.swift -not -name KeyboardView.swift) \
  $(find Sources/Kit -name '*.swift') Sources/App/Design/Pages.swift Sources/Apps/Keyboard/KeyboardModule.swift \
  -framework SwiftUI -framework AppKit -framework CoreGraphics

# В файле стенда нет кода, который мог бы тронуть систему.
if nm -u "$OUT/$NAME" | grep -E '_TISSelectInputSource|_CFPreferencesSetAppValue'; then echo "ПРОВАЛ: стенд умеет менять систему"; exit 1; fi
if grep -aqE 'TextInputSwitcher|activateSettings' "$OUT/$NAME"; then echo "ПРОВАЛ: в стенде есть TextInputSwitcher"; exit 1; fi
echo "ok   в файле стенда нет TISSelectInputSource, CFPreferencesSetAppValue, TextInputSwitcher, activateSettings"

system_values() {
  defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || echo нет
  defaults export com.apple.symbolichotkeys - 2>/dev/null | shasum
}
BEFORE="$(system_values)"
CFFIXED_USER_HOME="$OUT/home" "$OUT/$NAME" "$OUT"
if [ "$(system_values)" = "$BEFORE" ]; then echo "ok   AppleFnUsageType и symbolichotkeys после прогона те же"; else echo "FAIL системные настройки изменились"; exit 1; fi
echo "     снимки: $OUT/png"
