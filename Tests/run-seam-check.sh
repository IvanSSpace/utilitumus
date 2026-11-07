#!/bin/bash
# Сборки со швом (KIT_TEST_DEFAULTS) подписаны боевым ключом, но не должны пройти боевые проверки:
# тестовая метка выпуска, поиск следов шва в бандле, scripts/check-no-seam.sh. Подписей не требует:
# сборка утилиты может оборваться на codesign, до него бандл и метка уже готовы.
# Папка стенда: SEAM_CHECK_DIR, иначе $TMPDIR/seam-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${SEAM_CHECK_DIR:-${TMPDIR:-/tmp}/seam-check}"
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
fail() { echo "ПРОВАЛ: $1"; exit 1; }
ok() { echo "ok   $1"; }

# Инкрементальная сборка самой проверки: у сборки без шва и со швом свой кэш, объекты не смешиваются (Tests/lib/incremental.sh).
# Настоящая утилита ниже собирается как всегда, через build-app.sh с -O: следы шва ищем именно в такой сборке.
. Tests/lib/incremental.sh
build_check() { # <выходной файл> <имя кэша> [-D флаг]
  local out="$1" name="$2"; shift 2
  local cache; cache="$(incremental_cache "$name" "$@")"
  mkdir -p "$cache/src"
  cmp -s Tests/SeamCheck.swift "$cache/src/main.swift" || cp Tests/SeamCheck.swift "$cache/src/main.swift"
  local files=("$cache/src/main.swift" Sources/Kit/KitSigning.swift)
  incremental_flags "$cache" "${files[@]}"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" ${1+-D "$1"} -module-name SeamCheck -o "$out" "${files[@]}"
}
build_check "$OUT/check-prod" seam-prod
build_check "$OUT/check-seam" seam-seam KIT_TEST_DEFAULTS
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
