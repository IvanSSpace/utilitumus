#!/bin/bash
# Ловушки инкрементальной сборки проверок: чужая программа на месте выхода, кэш другой копии проекта и другого набора флагов.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
. Tests/lib/incremental.sh

OUT="$(mktemp -d "${TMPDIR:-/tmp}/incremental-lib.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
same() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "ПРОВАЛ: $1: ждал «$3», вышло «$2»"; exit 1; }; }

build() { # вариант
  local files=("$OUT/$1/main.swift")
  incremental_flags "$OUT/$1/cache" "${files[@]}"
  swiftc "${INC_FLAGS[@]}" -module-name LibCheck -o "$OUT/program" "${files[@]}"
}
for v in a b; do mkdir -p "$OUT/$v"; echo "print(\"$v\")" > "$OUT/$v/main.swift"; done

build a; same "первая сборка" "$("$OUT/program")" a
sleep 1
build b; same "другой кэш, тот же выход" "$("$OUT/program")" b
sleep 1
build a; same "снова первый кэш без изменений: его программа, а не чужая" "$("$OUT/program")" a

sleep 1
echo 'print("a2")' > "$OUT/a/main.swift"
build a; same "правка исходника доходит" "$("$OUT/program")" a2

first="$(incremental_cache x A)"
same "другой набор флагов: другой кэш" "$([ "$first" != "$(incremental_cache x B)" ] && echo разный)" разный
same "другая копия проекта: другой кэш" "$([ "$first" != "$(cd "$OUT" && incremental_cache x A)" ] && echo разный)" разный

# Вызов без -incremental выход заранее не трогает: у него своя логика.
echo keep > "$OUT/untouched"
swiftc --version >/dev/null
same "обычный вызов ничего не удаляет" "$(cat "$OUT/untouched")" keep
echo "ВСЁ ОК"
