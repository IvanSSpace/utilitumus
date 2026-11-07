#!/bin/bash
# Боевая сборка не должна нести тестовый шов: сборки со швом подписаны тем же ключом (KitSigning.testPeerEpoch).
# Ищет в исполняемых файлах и Info.plist образец `local.utilitumus.test.` (домен настроек и метка стендов)
# и метку выпуска стенда. Образец собран из частей, чтобы скрипт не находил сам себя.
#   scripts/check-no-seam.sh <бандл.app>
set -euo pipefail
APP="${1:?Укажи бандл}"
[ -d "$APP" ] || { echo "Нет бандла: $APP" >&2; exit 1; }
NEEDLE="local.utilitumus.""test."
FOUND="$(find "$APP/Contents" -type f \( -path '*/MacOS/*' -o -path '*/Helpers/*' -o -name Info.plist \) -exec grep -laF -e "$NEEDLE" {} + 2>/dev/null || true)"
EPOCH="$(sed -n 's/.*static let testPeerEpoch = "\(.*\)".*/\1/p' "$(dirname "$0")/../Sources/Kit/KitSigning.swift")"
[ -n "$EPOCH" ] || { echo "Нет testPeerEpoch в Sources/Kit/KitSigning.swift" >&2; exit 1; }
while IFS= read -r PLIST; do
  [ "$(plutil -extract UtilitumusSecurityEpoch raw -o - "$PLIST" 2>/dev/null || true)" != "$EPOCH" ] || FOUND="${FOUND}"$'\n'"$PLIST"
done < <(find "$APP/Contents" -name Info.plist -type f)
# Сборка scripts/dev.sh (-Onone, свой каталог) помечена в Info.plist: в выпуск она не годится.
while IFS= read -r PLIST; do
  [ -z "$(plutil -extract UtilitumusDevBuild raw -o - "$PLIST" 2>/dev/null || true)" ] || FOUND="${FOUND}"$'\n'"$PLIST (сборка для разработки)"
done < <(find "$APP/Contents" -name Info.plist -type f)
if [ -n "$FOUND" ]; then
  echo "В сборке следы тестового шва — выкладывать нельзя:" >&2
  echo "$FOUND" >&2
  exit 1
fi
