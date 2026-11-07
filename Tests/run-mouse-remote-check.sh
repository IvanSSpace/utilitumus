#!/bin/bash
# Вкладка «Мышь» в лаунчере, работа в утилите. Настоящие подписанная утилита, launchd и связь; tap на прокрутку и
# системный запрос доступа заглушены швом KIT_TEST_DEFAULTS. Папка стенда: SATELLITE_CHECK_DIR; снимки в mouse/png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup mouse Mouse

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteMouseModel.swift

build_utility
build_module_hub Tests/MouseRemoteCheck.swift

defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «МЫШЬ»"
