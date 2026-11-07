#!/bin/bash
# Тест детектора Fn-тапа и выбора раскладки: логика без UI.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
# Шов KIT_TEST_DEFAULTS обязателен: у бинарника без бандла Kit.defaults иначе был бы настоящий домен настроек.
swiftc -D KIT_TEST_DEFAULTS -o "$OUT/test" \
  Sources/Kit/KitDefaults.swift \
  Sources/Modules/Keyboard/FnTapDetector.swift \
  Sources/Modules/Keyboard/KeyboardLayoutPicker.swift \
  Sources/Modules/Keyboard/InputSources.swift \
  Sources/Modules/Keyboard/KeyboardLog.swift \
  Sources/Modules/Keyboard/UI/KeyboardTypes.swift \
  Sources/Modules/Keyboard/UI/FnSystemAction.swift \
  Tests/FnTap/main.swift \
  -framework Carbon -framework AppKit
"$OUT/test"
