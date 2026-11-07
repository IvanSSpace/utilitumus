#!/bin/bash
# Kit.ownBundleIDs и Kit.isOurs: точный список, подделки не проходят; Стеш и Нагрузка не трогают наше.
# Шов KIT_TEST_DEFAULTS обязателен: у бинарника без бандла Kit.defaults иначе был бы настоящий домен настроек.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="$(mktemp -d)"
OUT="$(cd "$OUT" && pwd -P)"
PIDS=()
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$OUT"
}
trap cleanup EXIT

# Сравнивать с собой по Bundle.main в модулях нельзя: из утилиты это не защитит лаунчер.
# BrowserCatalog остаётся: там это про то, в каком процессе идёт код, и помощник ссылок собирается без Kit.
status=0
FOUND="$(grep -rnE '(==|!=) *Bundle\.main\.bundleIdentifier|let [a-z]+ = Bundle\.main\.bundleIdentifier' Sources/Modules)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: сравнение с собой по Bundle.main:"; echo "$FOUND"; exit 1 ;;
  1) ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac
echo "ok   в модулях нет сравнения с собой по Bundle.main"

# Как у настоящих: без окна и значка в Dock, только регистрация в системе.
cat >"$OUT/stub.swift" <<'SWIFT'
import AppKit
NSApplication.shared.setActivationPolicy(.accessory)
RunLoop.main.run()
SWIFT
swiftc -target "$TARGET" -o "$OUT/stub" "$OUT/stub.swift" -framework AppKit
stub() {
  local app="$OUT/$1.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$OUT/stub" "$app/Contents/MacOS/stub"
  plutil -create xml1 "$app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$2" "$app/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string stub "$app/Contents/Info.plist"
  plutil -insert LSUIElement -bool true "$app/Contents/Info.plist"
}
stub ours local.utilitumus.app.sound
stub evil local.utilitumus.evil
"$OUT/ours.app/Contents/MacOS/stub" & OURS=$!; PIDS+=("$OURS")
"$OUT/evil.app/Contents/MacOS/stub" & EVIL=$!; PIDS+=("$EVIL")

# Инкрементальная сборка: кэш вне временной папки проверки, её удаляют. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache own-identity KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
cmp -s Tests/OwnIdentityCheck.swift "$CACHE/src/main.swift" || cp Tests/OwnIdentityCheck.swift "$CACHE/src/main.swift"
L=Sources/Modules/Load/Native
U=Sources/Modules/Load/UI
FILES=("$CACHE/src/main.swift" "$L/Background/BackgroundActions.swift" "$L/Background/BotStatus.swift" \
  "$L/Background/LaunchAgents.swift" "$L/Sessions/MuxProbe.swift" "$U/Native/Sessions/SessionModels.swift" \
  "$U/Native/Sessions/MuxTypes.swift" "$U/Native/Core/MemoryMap.swift" "$U/LoadTypes.swift" \
  "$L/Sessions/SessionsBuilder.swift" "$L/Sessions/Transcripts.swift" Sources/Modules/Stash/StashStore.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit "$L/Core" -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name OwnIdentityCheck -o "$OUT/check" "${FILES[@]}"

# id, которые реально получают бандлы: список в Kit не должен разойтись со сборкой.
REAL=()
for plist in Info.plist Sources/LinkHelper/Info.plist Sources/Apps/*/Info.plist; do
  REAL+=("$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")")
done
while IFS= read -r id; do REAL+=("$id"); done < <(grep -oE -- '--identifier local\.[a-z.]+' build.sh | cut -d' ' -f2)

"$OUT/check" "$OURS" "$EVIL" "${REAL[@]}"
echo "Свои id: OK"
