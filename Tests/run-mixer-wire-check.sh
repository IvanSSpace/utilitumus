#!/bin/bash
# Состояние, действия, проверки и экран «Микшера» без связи и без звука: `start()` не вызывается, тапов нет.
# Настройки в своём suite, настоящие не трогаются. Окно за экраном и прозрачное. Папка стенда: MIXER_WIRE_DIR.
# MIXER_BEFORE_REV=<коммит>: ещё снимки встроенного экрана из этого коммита, сравнение до пикселя.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MIXER_WIRE_DIR:-${TMPDIR:-/tmp}/mixer-wire-check}"
SUITE="local.utilitumus.test.mixer"
FLAGS=(-parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox)

reset_suite() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
trap reset_suite EXIT

# Копия исходников для стенда: настройки уходят в его suite, «Остальные» можно открыть без клика.
prepare() {
  local from="$1" to="$2"
  rm -rf "$to"
  mkdir -p "$to"
  find "$from/Sources/Modules/Mixer" -name '*.swift' -exec cp {} "$to/" \;
  cp "$from/Sources/App/Design/Pages.swift" "$to/"
  sed -i '' -E 's/UserDefaults\.standard|Kit\.defaults/mixerStandDefaults/g' "$to/MixerController.swift"
  sed -i '' 's/@State private var showOthers = false/@State private var showOthers = standShowOthers/' "$to/MixerView.swift"
  grep -q 'showOthers = standShowOthers' "$to/MixerView.swift" || { echo "ПРОВАЛ: стенд не открыл «Остальные»"; exit 1; }
}

reset_suite
rm -rf "$OUT"
mkdir -p "$OUT"
prepare . "$OUT/src"
# Инкрементальная сборка: кэш и копии подставных файлов вне папки стенда. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
. Tests/lib/incremental-sync.sh
CACHE="$(incremental_cache mixer-wire KIT_TEST_DEFAULTS)"
incremental_sync "$OUT/src" "$CACHE/src"
FILES=(Tests/MixerWireCheck.swift "$CACHE"/src/*.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} "${FLAGS[@]}" -module-name MixerWireCheck -o "$OUT/check" "${FILES[@]}"
"$OUT/check" run "$OUT/after"

if [ -n "${MIXER_BEFORE_REV:-}" ]; then
  mkdir -p "$OUT/base"
  /usr/bin/git archive "$MIXER_BEFORE_REV" Sources/Kit Sources/Modules/Mixer Sources/App/Design/Pages.swift | tar -x -C "$OUT/base"
  prepare "$OUT/base" "$OUT/base-src"
  # Та же точка закрепления списков, что и в проверяемой версии: только она добавлена к старому контроллеру.
  { echo 'extension MixerController {'; sed -n '/#if KIT_TEST_DEFAULTS/,/#endif/p' "$OUT/src/MixerController.swift"; echo '}'; } >> "$OUT/base-src/MixerController.swift"
  swiftc "${FLAGS[@]}" -D MIXER_BASELINE -module-name MixerWireBase -o "$OUT/base-check" Tests/MixerWireCheck.swift "$OUT"/base-src/*.swift $(find "$OUT/base/Sources/Kit" -name '*.swift')
  "$OUT/base-check" render "$OUT/before"
  "$OUT/check" compare "$OUT/before" "$OUT/after"
fi
