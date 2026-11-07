#!/bin/bash
# Вкладка «Стеш программ»: рисует центр, работает утилита. Настоящие подписанная утилита, launchd и связь.
# Программ у стенда нет (список пуст), закрыть и запустить настоящую нельзя; записи кладёт скрипт в тестовый домен.
# Не запускать вместе с другими проверками Стеша на одной метке. Папка стенда: SATELLITE_CHECK_DIR; снимки в stash/png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup stash Stash

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteStashModel.swift Sources/App/Satellites/RemoteStashPage.swift

build_utility
build_module_hub Tests/StashRemoteCheck.swift

# Запись о закрытой программе и сценарий, как после настоящего «Спрятать». Значок берётся у настоящего .app, он не запускается.
hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }
defaults write "$SUITE" StashedApps -data "$(hex '[{"bundleID":"com.apple.calculator","name":"Калькулятор","path":"/System/Applications/Calculator.app","windows":[{"height":200,"title":"","width":300,"x":1,"y":2}]}]')"
defaults write "$SUITE" StashScenarios -data "$(hex '[{"bundleIDs":["test.a"],"id":"11111111-2222-3333-4444-555555555555","name":"Работа"}]')"
defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «СТЕШ ПРОГРАММ»"
