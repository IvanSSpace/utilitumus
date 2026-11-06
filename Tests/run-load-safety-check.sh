#!/bin/bash
# Защита от остановки, метки и подписи агентов, журнал действий. Только чистая логика и файл в папке стенда.
# Папка стенда: LOAD_CHECK_DIR, иначе $TMPDIR/load-safety-check.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${LOAD_CHECK_DIR:-${TMPDIR:-/tmp}/load-safety-check}"
rm -rf "$OUT"
mkdir -p "$OUT"
cp Tests/LoadSafetyCheck.swift "$OUT/main.swift"
L=Sources/Modules/Load/Native
# Всё, кроме экранов: логика связана внутри себя, а SwiftUI ей не нужен.
swiftc -o "$OUT/check" "$OUT/main.swift" $(find "$L/Core" -name '*.swift') \
  "$L/Background/BackgroundActions.swift" "$L/Background/BotRegistry.swift" "$L/Background/LaunchAgents.swift" \
  "$L/Sessions/MuxProbe.swift" "$L/Sessions/SessionModels.swift" "$L/Sessions/SessionsBuilder.swift" \
  "$L/Sessions/Transcripts.swift"
"$OUT/check" "$OUT"
