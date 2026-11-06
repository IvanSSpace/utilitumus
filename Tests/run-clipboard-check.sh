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
cp Tests/ClipboardCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" \
  Sources/Modules/Clipboard/ClipboardModels.swift \
  Sources/Modules/Clipboard/ClipboardStore.swift \
  Sources/Modules/Clipboard/ClipboardPasteboard.swift \
  Sources/Modules/Clipboard/ClipboardPreview.swift \
  -framework AppKit -framework CryptoKit -framework Security
"$OUT/check"
