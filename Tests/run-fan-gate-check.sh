#!/bin/bash
# Проверка гистерезиса и сглаживания вентиляторов (чистая логика, без SMC и помощника).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/fan-gate-check"
mkdir -p "$OUT"
cp Tests/FanGateCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" Sources/Modules/Fans/FanGate.swift
"$OUT/check"
