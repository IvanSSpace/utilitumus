#!/bin/bash
# Связь и экран «Звук»: кодирование, проверки действий, снимки экрана до и после переноса на модель.
# Монитор не запускается, устройства не меняются, окно за экраном. Настройки — домен по имени файла стенда,
# после перехода модуля на Kit.defaults — свой suite. Папка стенда: SOUND_WIRE_DIR, иначе $TMPDIR/sound-wire-check.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SOUND_WIRE_DIR:-${TMPDIR:-/tmp}/sound-wire-check}"
SUITE="local.utilitumus.test.sound"
NAME="sound-wire-check"
# Экран до модели. Менять экран намеренно — обновить этот коммит.
BASE="509cdb3"

cleanup() {
  for domain in "$SUITE" "$NAME"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
}
trap cleanup EXIT
cleanup

mkdir -p "$OUT/src"
/usr/bin/git show "$BASE:Sources/Modules/Sound/SoundView.swift" \
  | sed 's/^struct SoundView: View {/struct LegacySoundView: View {/' > "$OUT/src/LegacySoundView.swift"
grep -q '^struct LegacySoundView: View {' "$OUT/src/LegacySoundView.swift"

swiftc -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name SoundWireCheck -o "$OUT/$NAME" \
  Tests/SoundWireCheck.swift "$OUT/src/LegacySoundView.swift" \
  $(find Sources/Kit Sources/Modules/Sound -name '*.swift') \
  -framework SwiftUI -framework AppKit -framework CoreAudio
KIT_TEST_SUITE="$SUITE" "$OUT/$NAME"
