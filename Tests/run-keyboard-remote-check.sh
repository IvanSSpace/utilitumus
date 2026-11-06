#!/bin/bash
# Вкладка «Клавиатура»: рисует центр, работает утилита. Настоящие подписанная утилита, launchd и связь.
# Все фишки выключены в домене стенда ДО запуска утилиты и центра: tap не создаётся, ничего не пишется в com.apple.HIToolbox
# и com.apple.symbolichotkeys, TextInputSwitcher не трогается, раскладка не меняется (для этого в проверке нет ни одного
# действия, включающего фишку). Разрешение «Мониторинг ввода» проверяется руками. Папка стенда: SATELLITE_CHECK_DIR.
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup keyboard Keyboard

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteKeyboardModel.swift Sources/App/Satellites/RemoteKeyboardPage.swift

system_values() {
  defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || echo нет
  defaults export com.apple.symbolichotkeys - 2>/dev/null | shasum
}
BEFORE="$(system_values)"

build_utility
build_module_hub Tests/KeyboardRemoteCheck.swift

defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
defaults write "$SUITE" Keyboard.Feature.fnLanguage -bool false
defaults write "$SUITE" Keyboard.Feature.perAppLayout -bool false
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

same "AppleFnUsageType и symbolichotkeys после прогона те же" "$(system_values)" "$BEFORE"
echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «КЛАВИАТУРА»"
