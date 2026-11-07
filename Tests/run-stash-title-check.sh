#!/bin/bash
# Проверка хранения заголовков окон в стеше: собирает Tests/StashTitleCheck.swift с исходником стеша и запускает.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Без -parse-as-library: код верхнего уровня лежит в файле, который называется не main.swift.
# Инкрементальная сборка: кэш вне папки стенда, копия с тем же содержимым не меняет время изменения. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache stash-title KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
cmp -s Tests/StashTitleCheck.swift "$CACHE/src/main.swift" || cp Tests/StashTitleCheck.swift "$CACHE/src/main.swift"
# Шов KIT_TEST_DEFAULTS обязателен: у бинарника без бандла Kit.defaults иначе был бы настоящий домен настроек.
FILES=("$CACHE/src/main.swift" Sources/Modules/Stash/StashStore.swift)
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -D KIT_TEST_DEFAULTS -module-name StashTitleCheck -o "$OUT/check" "${FILES[@]}"
"$OUT/check"
