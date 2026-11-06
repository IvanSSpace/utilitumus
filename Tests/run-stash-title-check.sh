#!/bin/bash
# Проверка хранения заголовков окон в стеше: собирает Tests/StashTitleCheck.swift с исходником стеша и запускает.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Без -parse-as-library: код верхнего уровня лежит в файле, который называется не main.swift.
cp Tests/StashTitleCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" Sources/Modules/Stash/StashStore.swift
"$OUT/check"
