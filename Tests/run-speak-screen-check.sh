#!/bin/bash
# «Озвучка»: экран так, как его собирает центр — Sources/Modules/Speak/UI, Kit и модель вкладки на подставной связи.
# По исходникам: в экране и модели центра нет AX, синтеза речи, запросов прав и ядра утилиты.
# Вживую: каждое нажатие уходит одним действием связи, которое утилита примет; скорость и голоса видны сразу, отказ откатывается;
# экран на модели центра совпадает с экраном на фикстуре до пикселя; снимки экрана.
# Сборка со швом KIT_TEST_DEFAULTS, дом подставной. Папка стенда: SPEAK_SCREEN_DIR, иначе $TMPDIR/speak-screen-check;
# снимки — SPEAK_SCREEN_PNG_DIR, иначе её подпапка png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${SPEAK_SCREEN_DIR:-${T%/}/speak-screen-check}"
PNG="${SPEAK_SCREEN_PNG_DIR:-$OUT/png}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.speak-screen"
UI=Sources/Modules/Speak/UI
REMOTE=(Sources/App/Satellites/RemoteSpeakModel.swift Sources/App/Satellites/RemoteSpeakPage.swift)

cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
cleanup

FAILED=0
ok() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; FAILED=1; }
# grep: 0 — нашёл, 1 — пусто, больше — ошибка самого grep (её нельзя принять за «пусто»).
none() { # что проверяем, grep -E образец, где...
  local what="$1" pattern="$2" found status=0
  shift 2
  found="$(/usr/bin/grep -rnE -- "$pattern" "$@")" || status=$?
  case "$status" in
    0) bad "$what:"; echo "$found" ;;
    1) ok "$what" ;;
    *) bad "$what: grep завершился с кодом $status" ;;
  esac
}

echo "== Исходники: $UI и ${REMOTE[*]}"
none "нет фреймворков звука, AX и прав" '^import (AVFoundation|AVFAudio|AudioToolbox|IOKit|ApplicationServices|NaturalLanguage|Speech)\b' "$UI" "${REMOTE[@]}"
none "нет вызовов AX, синтеза и запросов прав" 'AXIsProcess|AXUIElement|kAXTrusted|AVSpeech|NSSpeechSynthesizer|CGRequest|CGPreflight|NSAppleScript|tccutil' "$UI" "${REMOTE[@]}"
none "экран сам Системные настройки не открывает" 'NSWorkspace|openURL|systempreferences' "$UI" "${REMOTE[@]}"
none "нет ядра утилиты" '\b(SpeakController|SpeakService|SpeakPlayer|SpeechSynthesizing|SelectionReading|SpeakVoiceChooser|SpeakRate)\b' "$UI" "${REMOTE[@]}"
none "нет буфера обмена" 'NSPasteboard|Kit\.pasteboard' "$UI" "${REMOTE[@]}"

echo "== Вживую"
rm -rf "$OUT/src" "$OUT/home"
mkdir -p "$OUT/src" "$OUT/home" "$PNG"
cp Tests/SpeakScreenCheck.swift "$OUT/src/SpeakScreenCheck.swift"
# Только то, что есть у центра: экран, Kit и модель вкладки. Ядро «Озвучки» сюда не входит — экран обязан собираться без него.
swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name SpeakScreenCheck -o "$OUT/check" \
  "$OUT/src/SpeakScreenCheck.swift" $(find "$UI" -name '*.swift' | LC_ALL=C sort) \
  Sources/App/Satellites/RemoteSpeakModel.swift Sources/App/Satellites/RemoteModuleModel.swift \
  Sources/App/Satellites/RemoteModuleSurface.swift Sources/App/Design/DashState.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort)
status=0
env HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" "$OUT/check" "$PNG" || status=$?
[ "$status" = 0 ] || bad "проверка в процессе: код $status"

if [ "$FAILED" != 0 ]; then echo "ПРОВАЛ: есть замечания выше"; exit 1; fi
echo "ВСЁ ОК"
