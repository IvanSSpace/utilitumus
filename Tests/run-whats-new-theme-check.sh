#!/bin/bash
# «Что нового» и тема: в «Графите» плитки пунктов без ярких цветов, в цветных темах прежние. Окно за экраном (x: -10000),
# настройки не нужны: тема подаётся в окружение. Kit.defaults — в своём suite (шов KIT_TEST_DEFAULTS), настоящий домен не трогается.
# Папка: WHATS_NEW_THEME_CHECK_DIR, иначе $TMPDIR/whats-new-theme-check. PNG остаются в png/.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${WHATS_NEW_THEME_CHECK_DIR:-${TMPDIR:-/tmp}/whats-new-theme-check}"
BIN="whats-new-theme-stand"
SUITE="local.utilitumus.test.kit.whats-new-theme"

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache whats-new-theme "$TARGET" KIT_TEST_DEFAULTS)"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/png"
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"
cp Tests/WhatsNewThemeCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift UtilitumusApp.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
# UtilitumusApp.swift у стенда свой, без @main.
HUB_LIST="$(scripts/hub-sources.sh)"
FILES=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift")
while IFS= read -r f; do case "$f" in */UtilitumusApp.swift) ;; *) FILES+=("$f") ;; esac; done <<<"$HUB_LIST"
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name WhatsNewThemeStand -o "$OUT/$BIN" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
ROOT="$PWD"
cd "$OUT"
KIT_TEST_SUITE="$SUITE" "./$BIN" "$ROOT/Resources/WhatsNew.json" "$OUT/png"
