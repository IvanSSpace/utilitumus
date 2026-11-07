#!/bin/bash
# Состояние, действия, проверки и экран «Микшера» без связи и без звука: `start()` не вызывается, тапов нет.
# Настройки в своём suite, настоящие не трогаются. Окно за экраном и прозрачное. Папка стенда: MIXER_WIRE_DIR.
# MIXER_BEFORE_REV=<коммит>: ещё снимки встроенного экрана из этого коммита, сравнение до пикселя.
# Совместимость: типы связи настоящего Микшера берутся из тега, снимки эквалайзера идут в MIXER_EQ_PNG.
source "$(dirname "$0")/lib/check-limit.sh"
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
  sed -i '' 's/@State private var eqOpen = false/@State private var eqOpen = standEqOpen/' "$to/MixerView.swift"
}

# Типы связи опубликованного Микшера 1.3.0, под другими именами рядом с новыми. Лаунчер 0.9.0 собран с тем же договором: файл с тех пор не менялся.
OLD_MIXER_TAG="mixer-v1.3.0"
old_wire() {
  /usr/bin/git show "$OLD_MIXER_TAG:Sources/Modules/Mixer/UI/MixerWire.swift" \
    | sed -n '1,/^\/\/\/ Иконка приложения/p' | sed '$d' \
    | sed -E 's/[[:<:]]MixerAppState[[:>:]]/OldMixerAppState/g; s/[[:<:]]MixerState[[:>:]]/OldMixerState/g; s/[[:<:]]MixerAction[[:>:]]/OldMixerAction/g'
}

reset_suite
rm -rf "$OUT"
mkdir -p "$OUT"
prepare . "$OUT/src"
grep -q 'eqOpen = standEqOpen' "$OUT/src/MixerView.swift" || { echo "ПРОВАЛ: стенд не раскрыл эквалайзер"; exit 1; }
[ "$(/usr/bin/git rev-parse "$OLD_MIXER_TAG:Sources/Modules/Mixer/UI/MixerWire.swift")" = "$(/usr/bin/git rev-parse "v0.9.0:Sources/Modules/Mixer/UI/MixerWire.swift")" ] \
  || { echo "ПРОВАЛ: договор связи у $OLD_MIXER_TAG и v0.9.0 разный, сверять надо с обоими"; exit 1; }
old_wire > "$OUT/src/OldMixerWire.swift"
grep -q 'enum OldMixerAction' "$OUT/src/OldMixerWire.swift" || { echo "ПРОВАЛ: старый договор связи не получен"; exit 1; }
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
# Настройки переживают перезапуск: запись и чтение разными процессами, как при следующем запуске Микшера.
"$OUT/check" eq-write
"$OUT/check" eq-read

if [ -n "${MIXER_BEFORE_REV:-}" ]; then
  mkdir -p "$OUT/base"
  /usr/bin/git archive "$MIXER_BEFORE_REV" Sources/Kit Sources/Modules/Mixer Sources/App/Design/Pages.swift | tar -x -C "$OUT/base"
  prepare "$OUT/base" "$OUT/base-src"
  # Та же точка закрепления списков, что и в проверяемой версии: только она добавлена к старому контроллеру.
  # Строки эквалайзера убираются: в старом контроллере его нет. Снимки сверяют строки без него. Своя точка закрепления есть с 405a23b.
  grep -q 'func testPin' "$OUT/base-src/MixerController.swift" || { echo 'extension MixerController {'; sed -n '/#if KIT_TEST_DEFAULTS/,/#endif/p' "$OUT/src/MixerController.swift" | grep -vE 'equalizers|app\.eq' ; echo '}'; } >> "$OUT/base-src/MixerController.swift"
  swiftc "${FLAGS[@]}" -D MIXER_BASELINE -module-name MixerWireBase -o "$OUT/base-check" Tests/MixerWireCheck.swift "$OUT"/base-src/*.swift $(find "$OUT/base/Sources/Kit" -name '*.swift')
  "$OUT/base-check" render "$OUT/before"
  "$OUT/check" compare "$OUT/before" "$OUT/after"
fi
