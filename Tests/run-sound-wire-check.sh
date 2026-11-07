#!/bin/bash
# Связь и экран «Звук»: кодирование, проверки действий, снимки экрана до и после переноса на модель.
# Устройства не меняются (в сборке со швом AudioMonitor ничего не пишет), окно за экраном; монитор запускается только в разделе жизненного цикла. Настройки — домен по имени файла стенда,
# после перехода модуля на Kit.defaults — свой suite. Папка стенда: SOUND_WIRE_DIR, иначе $TMPDIR/sound-wire-check.
source "$(dirname "$0")/lib/check-limit.sh"
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

# Инкрементальная сборка: кэш и копии подставных файлов вне папки стенда. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
. Tests/lib/incremental-sync.sh
CACHE="$(incremental_cache sound-wire KIT_TEST_DEFAULTS)"
incremental_sync "$OUT/src" "$CACHE/src"
FILES=(Tests/SoundWireCheck.swift "$CACHE/src/LegacySoundView.swift" Sources/Apps/Sound/SoundModule.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit Sources/Modules/Sound -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
rm -f "$OUT/$NAME"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name SoundWireCheck -o "$OUT/$NAME" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio
KIT_TEST_SUITE="$SUITE" "$OUT/$NAME"
