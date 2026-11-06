#!/bin/bash
# Ключ «Буфера» и его передача центром. Связка в памяти, временный каталог, выдуманные ключи.
# Настоящая Связка ключей, index.bin, img-*.bin и буфер обмена не трогаются: страж ниже не даёт проверке даже назвать их.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/clipboard-key-check"
mkdir -p "$OUT"

status=0
FOUND="$(grep -nE 'SystemClipboardKeyring|ClipboardKeychain|NSPasteboard|SecItem(Copy|Add|Delete|Update)|defaultDirectory|Application Support|ClipboardController|history-key' Tests/ClipboardKeyCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка называет настоящую связку, каталог или буфер:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   проверка не называет настоящую связку, каталог истории и буфер" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

cp Tests/ClipboardKeyCheck.swift "$OUT/main.swift"
# Сборка со швом: настройки в своём suite, модуль без опроса буфера и горячей клавиши.
export KIT_TEST_SUITE="local.utilitumus.test.kit.clipboardkey"
trap 'defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"' EXIT
swiftc -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/main.swift" \
  Sources/Apps/Clipboard/ClipboardModule.swift \
  $(find Sources/Modules/Clipboard -name '*.swift') \
  $(find Sources/Kit -name '*.swift') \
  -framework SwiftUI -framework AppKit -framework CryptoKit -framework Security -framework Carbon
"$OUT/check"
