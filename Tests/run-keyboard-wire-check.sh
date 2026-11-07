#!/bin/bash
# Клавиатура: состояние, действия и их проверки, экран до и после переноса на модель. Окно за экраном и прозрачное.
# Настоящие InputSources.swift, FnSystemAction.swift и App в стенд не собираются (Tests/KeyboardWireStubs.swift): 🌐, диктовка,
# TextInputSwitcher и текущая раскладка недоступны стенду. Настройки: домен самого файла и suite шва. Папка: KEYBOARD_WIRE_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${KEYBOARD_WIRE_DIR:-${TMPDIR:-/tmp}/keyboard-wire-check}"
# Экран до переноса на модель. Осознанное изменение вида — повод обновить этот коммит.
BASELINE=509cdb3
NAME=keyboard-wire-check
# Свой suite вместо общего local.utilitumus.test.kit: стенд пишет в Kit.defaults настройки модуля.
export KIT_TEST_SUITE="local.utilitumus.test.kit.keyboard-wire"
VIEW=Sources/Modules/Keyboard/UI/KeyboardView.swift
BASELINE_VIEW=Sources/Modules/Keyboard/KeyboardView.swift

cleanup() {
  for domain in "$NAME" "$KIT_TEST_SUITE"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/home" "$OUT/png"
SHOWN='s/@State private var logShown = false/@State private var logShown = testLogShown/'
sed "$SHOWN" "$VIEW" > "$OUT/src/KeyboardView.swift"
/usr/bin/git show "$BASELINE:$BASELINE_VIEW" | sed -e "$SHOWN" \
  -e 's/^struct KeyboardView: View {/struct BaselineKeyboardView: View {/' \
  -e 's/var controller = KeyboardController.shared/var controller = baselineModel/' > "$OUT/src/BaselineKeyboardView.swift"
for file in "$OUT/src/KeyboardView.swift" "$OUT/src/BaselineKeyboardView.swift"; do
  grep -q testLogShown "$file" || { echo "ПРОВАЛ: подстановка не сработала в $file"; exit 1; }
done
grep -q baselineModel "$OUT/src/BaselineKeyboardView.swift" || { echo "ПРОВАЛ: старый экран не подменён"; exit 1; }

# Инкрементальная сборка: кэш и копии подставных файлов вне папки стенда. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
. Tests/lib/incremental-sync.sh
CACHE="$(incremental_cache keyboard-wire KIT_TEST_DEFAULTS)"
incremental_sync "$OUT/src" "$CACHE/src"
FILES=(Tests/KeyboardWireCheck.swift Tests/KeyboardWireStubs.swift "$CACHE/src/KeyboardView.swift" "$CACHE/src/BaselineKeyboardView.swift"
  Sources/App/Design/Pages.swift Sources/Apps/Keyboard/KeyboardModule.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Modules/Keyboard -name '*.swift' -not -name InputSources.swift -not -name FnSystemAction.swift -not -name KeyboardView.swift | sort)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name KeyboardWireCheck -o "$OUT/$NAME" \
  "${FILES[@]}" \
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
