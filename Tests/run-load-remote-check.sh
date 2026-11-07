#!/bin/bash
# Вкладка «Нагрузка» в центре, работа в утилите: снимки встроенного и удалённого экрана, чужая подпись, плохие действия,
# confirm с неизвестным id плана, пассивная утилита стоит, смерть утилиты. Настоящие подписанная утилита, launchd и связь.
# Ничего не останавливается и не запускается; история утилиты пишется в её временную папку. Папка стенда: SATELLITE_CHECK_DIR.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup load Load

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteLoadModel.swift Sources/App/Satellites/RemoteLoadPage.swift

build_utility
build_module_hub Tests/LoadRemoteCheck.swift

defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
PID="$(agent_pid)"

# Первая запись истории приходит с запозданием и меняет состояние сама. Отказ ни при чём: ждём её до сравнения.
for _ in $(seq 1 100); do [[ "$("$HUB" state)" == *'"history"'* ]] && break; sleep 0.1; done

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «НАГРУЗКА»"
