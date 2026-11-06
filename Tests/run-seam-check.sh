#!/bin/bash
# Сборки со швом (KIT_TEST_DEFAULTS) подписаны боевым ключом, но не должны пройти боевые проверки:
# тестовая метка выпуска, поиск следов шва в бандле, scripts/check-no-seam.sh. Подписей не требует:
# сборка утилиты может оборваться на codesign, до него бандл и метка уже готовы.
# Папка стенда: SEAM_CHECK_DIR, иначе $TMPDIR/seam-check.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${SEAM_CHECK_DIR:-${TMPDIR:-/tmp}/seam-check}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
rm -rf "$OUT"
mkdir -p "$OUT/src"
OUT="$(cd "$OUT" && pwd -P)"
fail() { echo "ПРОВАЛ: $1"; exit 1; }
ok() { echo "ok   $1"; }

cp Tests/SeamCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -o "$OUT/check-prod" "$OUT/src/main.swift" Sources/Kit/KitSigning.swift
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check-seam" "$OUT/src/main.swift" Sources/Kit/KitSigning.swift
"$OUT/check-prod" "$OUT" || fail "боевая сборка проверки"
"$OUT/check-seam" "$OUT" || fail "сборка проверки со швом"

# scripts/check-no-seam.sh на готовых бандлах из проверки выше.
scripts/check-no-seam.sh "$OUT/clean-prod/X.app" || fail "check-no-seam отверг чистый бандл"
ok "check-no-seam: чистый бандл проходит"
if scripts/check-no-seam.sh "$OUT/dirty-prod/X.app" 2>/dev/null; then fail "check-no-seam пропустил образец шва в бинарнике"; fi
ok "check-no-seam: образец в бинарнике — отказ"
if scripts/check-no-seam.sh "$OUT/et-seam/X.app" 2>/dev/null; then fail "check-no-seam пропустил тестовую метку"; fi
ok "check-no-seam: тестовая метка — отказ"

# Настоящая утилита обоих видов. Подпись может не получиться (нет ключа): бандл и метка к этому моменту уже есть.
for kind in prod seam; do
  flag=(); [ "$kind" = seam ] && flag=(--test-seam)
  mkdir -p "$OUT/build-$kind"
  scripts/build-app.sh test.awake Awake 1.2.3 "$OUT/build-$kind" ${flag[@]+"${flag[@]}"} >"$OUT/build-$kind.log" 2>&1 || true
  [ -x "$OUT/build-$kind/Awake.app/Contents/MacOS/Awake" ] || { cat "$OUT/build-$kind.log"; fail "утилита ($kind) не собралась"; }
done
EPOCH_PROD="$(plutil -extract UtilitumusSecurityEpoch raw -o - "$OUT/build-prod/Awake.app/Contents/Info.plist")"
EPOCH_SEAM="$(plutil -extract UtilitumusSecurityEpoch raw -o - "$OUT/build-seam/Awake.app/Contents/Info.plist")"
[ "$EPOCH_PROD" = 1 ] || fail "боевая утилита: метка $EPOCH_PROD"
[ "$EPOCH_SEAM" = test.1 ] || fail "утилита со швом: метка $EPOCH_SEAM"
ok "метка: боевая 1, со швом test.1"
scripts/check-no-seam.sh "$OUT/build-prod/Awake.app" || fail "в боевой утилите нашлись следы шва"
ok "боевая утилита: следов шва нет"
if scripts/check-no-seam.sh "$OUT/build-seam/Awake.app" 2>/dev/null; then fail "утилита со швом прошла check-no-seam"; fi
ok "утилита со швом: check-no-seam отказывает"
echo "ВСЁ ОК"
