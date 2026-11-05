#!/bin/bash
# Тест детектора Fn-тапа и выбора раскладки: логика без UI.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -o "$OUT/test" \
  Sources/Modules/Keyboard/FnTapDetector.swift \
  Sources/Modules/Keyboard/KeyboardLayoutPicker.swift \
  Sources/Modules/Keyboard/InputSources.swift \
  Sources/Modules/Keyboard/KeyboardLog.swift \
  Tests/FnTap/main.swift \
  -framework Carbon -framework AppKit
"$OUT/test"
