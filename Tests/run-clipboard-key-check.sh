#!/bin/bash
# Ключ «Буфера» и его передача центром. Связка в памяти, временный каталог, выдуманные ключи.
# Настоящая Связка ключей, index.bin, img-*.bin и буфер обмена не трогаются: страж ниже не даёт проверке даже назвать их.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/clipboard-key-check"
mkdir -p "$OUT"

status=0
FOUND="$(grep -nE 'SystemClipboardKeyring|ClipboardKeychain\.system|NSPasteboard|SecItem(Copy|Add|Delete|Update)|defaultDirectory|Application Support|ClipboardController|history-key' Tests/ClipboardKeyCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка называет настоящую связку, каталог или буфер:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   проверка не называет настоящую связку, каталог истории и буфер" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Перед удалением утилиты центр ключ не просит: своя запись утилиты остаётся. Обработчики в утилите только для старого центра.
status=0
FOUND="$(grep -rnE 'ClipboardKeyReturn|returnKey|dropKey' Sources/App Sources/Modules/Clipboard/UI)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: центр снова просит ключ перед удалением утилиты:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   центр не просит ключ перед удалением утилиты" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Инкрементальная сборка: кэш вне папки стенда, копия с тем же содержимым не меняет время изменения. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache clipboard-key KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
cmp -s Tests/ClipboardKeyCheck.swift "$CACHE/src/main.swift" || cp Tests/ClipboardKeyCheck.swift "$CACHE/src/main.swift"
# Сборка со швом: настройки в своём suite, модуль без опроса буфера и горячей клавиши.
export KIT_TEST_SUITE="local.utilitumus.test.kit.clipboardkey"
trap 'defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"' EXIT
FILES=("$CACHE/src/main.swift" Sources/Apps/Clipboard/ClipboardModule.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Modules/Clipboard Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
rm -f "$OUT/check"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -D KIT_TEST_DEFAULTS -module-name ClipboardKeyCheck -o "$OUT/check" "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CryptoKit -framework Security -framework Carbon
"$OUT/check"
