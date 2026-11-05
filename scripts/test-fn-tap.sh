#!/bin/bash
# Тест детектора Fn-тапа и выбора раскладки: чистая логика, без AppKit.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -o "$OUT/test" \
  Sources/Modules/Keyboard/FnTapDetector.swift \
  Sources/Modules/Keyboard/KeyboardLayoutPicker.swift \
  Tests/FnTap/main.swift
"$OUT/test"
