#!/bin/bash
# Проверка логики модуля «Буфер»: собирает Tests/ClipboardCheck.swift с нужными исходниками и запускает.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/clipboard-check"
mkdir -p "$OUT"

# Настоящая Связка ключей и настоящая история этой проверке недоступны: связка только в памяти.
status=0
FOUND="$(grep -nE 'SecItem(Copy|Add|Delete|Update)|ClipboardKeychain\.system|SystemClipboardKeyring|defaultDirectory|Application Support|history-key|NSPasteboard\.general' Tests/ClipboardCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка называет настоящую связку, каталог или буфер:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   проверка не называет настоящую связку, каталог истории и общий буфер" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac
# Без -parse-as-library: код верхнего уровня лежит в файле, который называется не main.swift.
# Инкрементальная сборка: кэш вне папки стенда, копия с тем же содержимым не меняет время изменения. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache clipboard)"
mkdir -p "$CACHE/src"
cmp -s Tests/ClipboardCheck.swift "$CACHE/src/main.swift" || cp Tests/ClipboardCheck.swift "$CACHE/src/main.swift"
FILES=("$CACHE/src/main.swift"
  Sources/Modules/Clipboard/ClipboardModels.swift
  Sources/Modules/Clipboard/ClipboardStore.swift
  Sources/Modules/Clipboard/ClipboardPasteboard.swift
  Sources/Modules/Clipboard/ClipboardPreview.swift)
incremental_flags "$CACHE" "${FILES[@]}"
rm -f "$OUT/check"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -module-name ClipboardCheck -o "$OUT/check" "${FILES[@]}" \
  -framework AppKit -framework CryptoKit -framework Security
"$OUT/check"
