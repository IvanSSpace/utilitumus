#!/bin/bash
# Ключ «Буфера» и его передача центром. Связка в памяти, временный каталог, выдуманные ключи.
# Настоящая Связка ключей, index.bin, img-*.bin и буфер обмена не трогаются: страж ниже не даёт проверке даже назвать их.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/clipboard-key-check"
mkdir -p "$OUT"

status=0
FOUND="$(grep -nE 'SystemClipboardKeyring|ClipboardKeychain|NSPasteboard|SecItem|defaultDirectory|Application Support|ClipboardController|history-key' Tests/ClipboardKeyCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка называет настоящую связку, каталог или буфер:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   проверка не называет настоящую связку, каталог истории и буфер" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

cp Tests/ClipboardKeyCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" \
  Sources/Modules/Clipboard/ClipboardModels.swift \
  Sources/Modules/Clipboard/ClipboardStore.swift \
  Sources/Modules/Clipboard/ClipboardKeyring.swift \
  Sources/Modules/Clipboard/ClipboardWire.swift \
  Sources/Modules/Clipboard/ClipboardModel.swift \
  $(find Sources/Kit -name '*.swift') \
  -framework SwiftUI -framework AppKit -framework CryptoKit -framework Security -framework Carbon
"$OUT/check"
