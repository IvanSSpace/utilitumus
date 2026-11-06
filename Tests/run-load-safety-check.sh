#!/bin/bash
# Защита от остановки, метки и подписи агентов, журнал действий. Только чистая логика и файл в папке стенда.
# Папка стенда: LOAD_CHECK_DIR, иначе $TMPDIR/load-safety-check.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${LOAD_CHECK_DIR:-${TMPDIR:-/tmp}/load-safety-check}"
rm -rf "$OUT"
mkdir -p "$OUT"
cp Tests/LoadSafetyCheck.swift "$OUT/main.swift"
# Модуль целиком: LoadStopPrompt лежит в LoadWire, а он тянет модели и хранилища; из общего нужен только Kit.
# Шов KIT_TEST_DEFAULTS обязателен: у бинарника без бандла Kit.defaults иначе был бы настоящий домен настроек.
swiftc -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/main.swift" $(find Sources/Kit -name '*.swift') $(find Sources/Modules/Load -name '*.swift')
"$OUT/check" "$OUT"
