#!/bin/bash
# Граница Sources/Kit: компилируется сам по себе и не упоминает логику центра.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

if [ ! -d Sources/Kit ]; then
  echo "ПРОВАЛ: нет Sources/Kit"
  exit 1
fi

# Сначала список файлов: пустой $(find) дал бы swiftc без входных файлов и непонятную ошибку.
FILES="$(find Sources/Kit -name '*.swift')"
if [ -z "$FILES" ]; then
  echo "ПРОВАЛ: в Sources/Kit нет swift-файлов"
  exit 1
fi

swiftc -typecheck -parse-as-library -target "$TARGET" $FILES -framework SwiftUI -framework AppKit

# grep: 0 — нашёл, 1 — пусто, больше — ошибка самого grep (её нельзя принять за «пусто»).
PATTERN='\b(ModuleManager|StoreModel|SetupFlow|Updater|AccessState|[A-Z][a-z]+Controller)\b'
status=0
FOUND="$(grep -rnE "$PATTERN" Sources/Kit)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: Sources/Kit ссылается на логику центра:"; echo "$FOUND"; exit 1 ;;
  1) ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

echo "Граница Kit: OK"
