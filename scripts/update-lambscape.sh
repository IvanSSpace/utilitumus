#!/bin/bash
# Обновляет встроенную публичную версию lambscape (модуль «Нагрузка»).
# Берёт снимок ветки из локального клона: ./scripts/update-lambscape.sh [путь-к-клону] [ref]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=${1:-../lambscape}
REF=${2:-public/main}

rm -rf Vendor/lambscape
mkdir -p Vendor/lambscape
git -C "$SRC" archive "$REF" src/lambscape LICENSE | tar -x -C Vendor/lambscape
git -C "$SRC" rev-parse "$REF" > Vendor/lambscape/VERSION
echo "lambscape $REF ($(cut -c1-7 Vendor/lambscape/VERSION)) → Vendor/lambscape"
