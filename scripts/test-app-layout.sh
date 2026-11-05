#!/bin/bash
# Тест памяти «раскладка для каждого приложения»: чистая логика без UI.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -o "$OUT/test" \
  Sources/Modules/Keyboard/AppLayoutMemory.swift \
  Tests/AppLayout/main.swift
"$OUT/test"
