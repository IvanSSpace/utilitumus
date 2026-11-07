#!/bin/bash
# Вкладка «Микшер» в лаунчере, работа в утилите. Настоящие подписанная утилита, launchd и связь; звук не перехватывается:
# утилита стенда собрана со швом (--test-seam), тапы в ней не создаются. Захват системного звука и разрешение — руками.
# Папка стенда: SATELLITE_CHECK_DIR; снимки в mixer/png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup mixer Mixer

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteMixerModel.swift Sources/App/Satellites/RemoteMixerPage.swift

build_utility
build_module_hub Tests/MixerRemoteCheck.swift

defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «МИКШЕР»"
