#!/bin/bash
# Вкладка, карточка дашборда и пункт меню «Не спать»: рисует центр, работает утилита. Настоящие подписанная утилита, launchd, связь и pmset.
# Не запускать вместе с run-awake-app-check.sh: у них одна метка. Папка стенда: SATELLITE_CHECK_DIR; снимки в awake/png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup awake Awake

ASSERTION="Utilitumus: Keep Awake"
IDLE_PID=""
satellite_check_extra_cleanup() { if [ -n "$IDLE_PID" ]; then kill -9 "$IDLE_PID" 2>/dev/null || true; fi; }

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteAwakeModel.swift Sources/App/Satellites/RemoteAwakePage.swift Sources/App/Design/Dashboard.swift Sources/App/MenuBar.swift

build_utility
build_module_hub Tests/AwakeRemoteCheck.swift

defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected
if pmset -g assertions | grep -F "$ASSERTION" | grep -qE "pid $PID\("; then bad "чужая подпись включила блокировку"; else ok "чужая подпись блокировку не включила"; fi

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

for role in idle idle-dashboard; do
  echo "== простой ($role): экран открыт, утилита работает"
  "$HUB" "$role" "$OUT" > "$OUT/idle.log" & IDLE_PID=$!
  for _ in $(seq 1 100); do grep -q готов "$OUT/idle.log" && break; sleep 0.1; done
  sleep 10
  for who in "центр(стенд) $IDLE_PID" "утилита $PID"; do
    set -- $who
    echo "     $1: rss $(ps -o rss= -p "$2" | tr -d ' ') КБ, footprint $(footprint -p "$2" 2>/dev/null | sed -n 's/.*phys_footprint: *//p;s/.*Footprint: *//p' | head -1), CPU за 20 с: $(top -l 3 -s 10 -pid "$2" -stats cpu | tail -1 | tr -d ' ') %"
  done
  kill -9 "$IDLE_PID" 2>/dev/null || true
  wait "$IDLE_PID" 2>/dev/null || true
  IDLE_PID=""
  : > "$OUT/idle.log"
done

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «НЕ СПАТЬ»"
