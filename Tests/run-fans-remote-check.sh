#!/bin/bash
# Вкладка «Вентиляторы»: рисует центр, работает утилита. Настоящие подписанная утилита, launchd и связь.
# Службы вентиляторов нет и не ставится: окна пароля, AppleScript и записи в SMC здесь не бывает (SMC только читается).
# Не запускать вместе с другими проверками «Вентиляторов» под этой меткой. Папка стенда: SATELLITE_CHECK_DIR; снимки в fans/png.
# Нужен сертификат «Utilitumus Signing»: без него проверка не идёт (NOT RUN).
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup fans Fans

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteFansModel.swift Sources/App/Satellites/RemoteFansPage.swift

build_utility
build_module_hub Tests/FansRemoteCheck.swift

echo "== утилита: пассивная остановлена"
# Пассивность решает центр: запущен, не старый и модуль у него включён, а передачи ещё не было.
defaults write "$SUITE" Test.HubRunning -bool true
defaults write "$SUITE" Test.HubVersion -string 0.6.0
defaults write "$SUITE" "ModuleOn.$ID" -bool true
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
sleep 1
PASSIVE="$("$HUB" state)"
case "$PASSIVE" in
  *'"cpuSensors":[]'*'"fans":[]'*|*'"cpuSensors":[]'*) ok "центр запущен: утилита пассивна, датчики не читаются, вентиляторы не трогает" ;;
  *) bad "пассивная утилита работает: $PASSIVE" ;;
esac

echo "== утилита: активная"
defaults write "$SUITE" Test.HubRunning -bool false
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка, плохие действия, смерть утилиты"
"$HUB" run "$OUT" "$PID"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «ВЕНТИЛЯТОРЫ»"
