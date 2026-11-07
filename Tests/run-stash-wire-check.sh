#!/bin/bash
# Модель, связь и экран Стеша. Все программы поддельные, настоящие не закрываются и не запускаются;
# настройки только в своём suite, настоящий стеш не читается и не пишется. Окно за экраном и прозрачное.
# Экран «до» — StashView из коммита перед переходом на модель. Папка стенда: STASH_WIRE_DIR, иначе $TMPDIR/stash-wire-check.
# STASH_WIRE_LOGIC=1: только разбор и проверки действий, без экрана, для контрольных поломок.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${STASH_WIRE_DIR:-${TMPDIR:-/tmp}/stash-wire-check}"
SUITE="local.utilitumus.test.stash"
BEFORE=509cdb3

cleanup() {
  defaults delete "$SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
}
trap cleanup EXIT
cleanup

# Общий экземпляр читает настоящие настройки, а настоящий NSWorkspace видит настоящие программы.
status=0
FOUND="$(grep -nE 'StashStore\.shared|StashView\(\)|\.standard|NSWorkspace|local\.utilitumus"' Tests/StashWireCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка дотягивается до настоящего:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   в проверке нет общего экземпляра, .standard и NSWorkspace" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Инкрементальная сборка: кэш и копии подставных файлов вне папки стенда. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
. Tests/lib/incremental-sync.sh
rm -rf "$OUT/src" "$OUT/Check.app"
mkdir -p "$OUT/src" "$OUT/png" "$OUT/Check.app/Contents/MacOS"
OUT="$(cd "$OUT" && pwd -P)"
cp Tests/StashWireCheck.swift "$OUT/src/StashWireCheck.swift"
EXE="$OUT/Check.app/Contents/MacOS/check"

if [ "${STASH_WIRE_LOGIC:-}" = 1 ]; then
  export KIT_TEST_SUITE="$SUITE"
  CACHE="$(incremental_cache stash-wire-logic STASH_NO_SCREEN KIT_TEST_DEFAULTS)"
  incremental_sync "$OUT/src" "$CACHE/src"
  FILES=("$CACHE/src/StashWireCheck.swift" Sources/Modules/Stash/StashStore.swift Sources/Modules/Stash/StashModel.swift Sources/Modules/Stash/StashWire.swift)
  while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit -name '*.swift' | sort)
  incremental_flags "$CACHE" "${FILES[@]}"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D STASH_NO_SCREEN -D KIT_TEST_DEFAULTS -module-name StashWireCheck -o "$EXE" \
    "${FILES[@]}" -framework AppKit -framework SwiftUI -framework IOKit
  "$EXE"
  exit 0
fi

# Копии только для стенда: сцены заполняют стеш напрямую, Kit пишет в свой suite, общий suite Kit не тронут соседями.
sed 's/private(set) //' Sources/Modules/Stash/StashStore.swift > "$OUT/src/StashStore.swift"
[ "$(grep -c 'private(set)' "$OUT/src/StashStore.swift")" = 0 ] || { echo "ПРОВАЛ: private(set) остался"; exit 1; }
# Kit пишет в suite стенда: домен ему задаёт переменная окружения, общий suite Kit соседями не тронут.
export KIT_TEST_SUITE="$SUITE"
# Прежний экран: тот же стор, только свои имена и store передаётся явно.
/usr/bin/git show "$BEFORE:Sources/Modules/Stash/StashView.swift" \
  | perl -pe 's/\bStashView\b/LegacyStashView/g; s/\bStashChip\b/LegacyStashChip/g; s/\bmemoryText\b/legacyMemoryText/g; s/\bprograms\(/legacyPrograms(/g; s/\@ObservedObject var store = StashStore\.shared/\@ObservedObject var store: StashStore\n    init(store: StashStore) { self.store = store }/' \
  > "$OUT/src/LegacyStashView.swift"
grep -q 'init(store: StashStore)' "$OUT/src/LegacyStashView.swift" || { echo "ПРОВАЛ: прежний экран не подготовлен"; exit 1; }

CACHE="$(incremental_cache stash-wire KIT_TEST_DEFAULTS)"
incremental_sync "$OUT/src" "$CACHE/src"
FILES=("$CACHE/src/StashWireCheck.swift" "$CACHE/src/StashStore.swift" "$CACHE/src/LegacyStashView.swift"
  Sources/Modules/Stash/StashView.swift Sources/Modules/Stash/StashModel.swift Sources/Modules/Stash/StashWire.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name StashWireCheck -o "$EXE" \
  "${FILES[@]}" -framework SwiftUI -framework AppKit -framework IOKit
"$EXE" "$OUT"
