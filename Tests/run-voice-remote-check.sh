#!/bin/bash
# «Голос»: настоящая подписанная утилита под launchd, чужая подпись, мусор, пассивная роль, смерть утилиты.
# Нужен сертификат подписи. Микрофон и горячую клавишу сборка со швом не трогает: в ней start лишь пишет «голос: старт».
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup voice Voice

# Настоящую папку моделей проверка не трогает: до и после снимок её содержимого и времён должен совпасть.
REAL_MODELS="$HOME/Library/Application Support/Utilitumus/Voice/Models"
real_snapshot() { ls -laT "$REAL_MODELS" 2>/dev/null | shasum; }
BEFORE="$(real_snapshot)"
# Модели стенда лежат во временной папке своего suite (шов KIT_TEST_DEFAULTS); начинаем с пустой.
TEST_MODELS="${TMPDIR:-/tmp}/utilitumus-test-models/$SUITE"
rm -rf "$TEST_MODELS"
satellite_check_extra_cleanup() { rm -rf "$TEST_MODELS"; }

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteVoiceModel.swift Sources/App/Satellites/RemoteVoicePage.swift

build_utility
build_module_hub Tests/VoiceRemoteCheck.swift

echo "== пассивная утилита остановлена"
defaults write "$SUITE" Test.HubRunning -bool true
defaults write "$SUITE" "ModuleOn.$ID" -bool true
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
sleep 1
if grep -q "голос: старт" "$LOG"; then bad "пассивная утилита запустила работу"; else ok "пассивная утилита не запускала работу"; fi

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
echo "     снимки: $OUT/png"

[ "$BEFORE" = "$(real_snapshot)" ] && ok "папка настоящих моделей не менялась" || bad "папка настоящих моделей изменилась"

satellite_check_finish "ВКЛАДКА «ГОЛОС»"
