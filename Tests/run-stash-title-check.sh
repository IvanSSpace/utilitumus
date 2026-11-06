#!/bin/bash
# Проверка хранения заголовков окон в стеше: собирает Tests/StashTitleCheck.swift с исходником стеша и запускает.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Без -parse-as-library: код верхнего уровня лежит в файле, который называется не main.swift.
cp Tests/StashTitleCheck.swift "$OUT/main.swift"
# Шов KIT_TEST_DEFAULTS обязателен: у бинарника без бандла Kit.defaults иначе был бы настоящий домен настроек.
swiftc -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/main.swift" $(find Sources/Kit -name '*.swift') Sources/Modules/Stash/StashStore.swift
"$OUT/check"
