#!/bin/bash
# Защита от остановки, метки и подписи агентов, журнал действий. Только чистая логика и файл в папке стенда.
# Папка стенда: LOAD_CHECK_DIR, иначе $TMPDIR/load-safety-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${LOAD_CHECK_DIR:-${TMPDIR:-/tmp}/load-safety-check}"
rm -rf "$OUT"
mkdir -p "$OUT"
# Инкрементальная сборка: кэш вне папки стенда, копия с тем же содержимым не меняет время изменения. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache load-safety KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
cmp -s Tests/LoadSafetyCheck.swift "$CACHE/src/main.swift" || cp Tests/LoadSafetyCheck.swift "$CACHE/src/main.swift"
# Модуль целиком: LoadStopPrompt лежит в LoadWire, а он тянет модели и хранилища; из общего нужен только Kit.
# Шов KIT_TEST_DEFAULTS обязателен: у бинарника без бандла Kit.defaults иначе был бы настоящий домен настроек.
FILES=("$CACHE/src/main.swift")
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Kit Sources/Modules/Load -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -D KIT_TEST_DEFAULTS -module-name LoadSafetyCheck -o "$OUT/check" "${FILES[@]}"
"$OUT/check" "$OUT"
