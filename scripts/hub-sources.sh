#!/bin/bash
# Исходники центра, по одному на строку, в порядке LC_ALL=C. Единственный источник этого списка: build.sh, scripts/dev.sh, проверки центра.
# Читает Sources в текущей папке: звать из корня дерева. Сам в корень не переходит, потому что run-store-notes-check собирает и копию другой ревизии.
# Вызывающие берут вывод через HUB_LIST="$(scripts/hub-sources.sh)": `$(...)` внутри массива и `< <(...)` теряют код возврата, и сборка пошла бы дальше.
set -euo pipefail
list="$(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' | LC_ALL=C sort)"
[ -n "$list" ] || { echo "hub-sources.sh: нет исходников в ${PWD}" >&2; exit 1; }
printf '%s\n' "$list"
