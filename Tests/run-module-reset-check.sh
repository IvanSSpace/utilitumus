#!/bin/bash
# Проверка одноразового сброса модулей (чистая логика, без UserDefaults и системы).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/module-reset-check"
mkdir -p "$OUT"
cp Tests/ModuleResetCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" Sources/App/ModuleReset.swift
"$OUT/check"
