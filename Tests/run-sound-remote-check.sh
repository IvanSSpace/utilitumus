#!/bin/bash
# Вкладка «Звук»: рисует центр, работает утилита. Настоящие подписанная утилита, launchd и связь.
# Устройство по умолчанию у Mac не меняется: утилита собрана со швом, и её монитор ничего не пишет в CoreAudio.
# Папка стенда: SATELLITE_CHECK_DIR; снимки в sound/png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup sound Sound

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteSoundModel.swift Sources/App/Satellites/RemoteSoundPage.swift

build_utility
build_module_hub Tests/SoundRemoteCheck.swift

defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «ЗВУК»"
