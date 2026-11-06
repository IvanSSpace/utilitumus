#!/bin/bash
# «Голос»: настоящая подписанная утилита под launchd, чужая подпись, мусор, пассивная роль, смерть утилиты.
# Нужен сертификат подписи. Микрофон и горячую клавишу сборка со швом не трогает: в ней start лишь пишет «голос: старт».
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup voice Voice

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteVoiceModel.swift Sources/App/Satellites/RemoteVoicePage.swift

build_utility
build_module_hub Tests/VoiceRemoteCheck.swift

echo "== пассивная утилита остановлена"
defaults write "$SUITE" Test.HubRunning -bool true
defaults write "$SUITE" "ModuleOn.$ID" -bool true
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
sleep 1
if grep -q "голос: старт" "$LOG"; then bad "рядом с работающим встроенным модулем утилита запустила работу"; else ok "пассивная утилита не запускала работу"; fi

echo "== активная"
defaults write "$SUITE" Test.HubRunning -bool false
defaults delete "$SUITE" "ModuleOn.$ID" 2>/dev/null || true
start_agent
sleep 1
grep -q "голос: старт" "$LOG" && ok "активная утилита запустилась" || bad "активная утилита не запустилась"
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка, мусор, смерть утилиты"
"$HUB" run "$OUT" "$PID"

satellite_check_finish "ВКЛАДКА «ГОЛОС»"
