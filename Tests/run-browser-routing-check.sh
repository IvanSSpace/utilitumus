#!/bin/bash
# Куда ведёт ссылку модуль «Браузер» (чистая логика, без настроек и LaunchServices).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${BROWSER_CHECK_DIR:-${TMPDIR:-/tmp}/browser-routing-check}"
mkdir -p "$OUT"
cp Tests/BrowserRoutingCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" Sources/Modules/Browser/BrowserRules.swift
"$OUT/check"
