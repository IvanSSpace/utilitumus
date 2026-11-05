#!/bin/bash
# Проверка логики модуля «Буфер»: собирает Tests/ClipboardCheck.swift с нужными исходниками и запускает.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/clipboard-check"
mkdir -p "$OUT"
# Без -parse-as-library: код верхнего уровня лежит в файле, который называется не main.swift.
cp Tests/ClipboardCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" \
  Sources/Modules/Clipboard/ClipboardModels.swift \
  Sources/Modules/Clipboard/ClipboardStore.swift \
  Sources/Modules/Clipboard/ClipboardPasteboard.swift \
  -framework AppKit -framework CryptoKit -framework Security
"$OUT/check"
