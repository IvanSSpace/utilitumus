#!/bin/bash
# Вкладка «Боты» в лаунчере, работа в утилите: пиксели встроенного и внешнего экрана, чужая подпись, плохие действия,
# проверка файла bots.toml (права, битый, нет), замеры только под арендой экрана, команды ботов стенд не запускает.
# Настоящие подписанная утилита, launchd и связь. bots.toml стенда лежит во временной папке; настоящих ботов, настоящих меток
# и настоящего файла проверка не касается. Папка стенда: SATELLITE_CHECK_DIR; снимки в bots/png.
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup bots Bots

IDLE_PID=""
satellite_check_extra_cleanup() {
  if [ -n "$IDLE_PID" ]; then kill -9 "$IDLE_PID" 2>/dev/null || true; fi
  rm -f "$(getconf DARWIN_USER_TEMP_DIR)utilitumus-test-bots-$SUITE.toml"
  # Поддельные агенты и проекты для поиска ботов; одна из папок закрыта, снимаем запрет перед удалением.
  chmod -R u+rwx "$STAND_HOME/proj" 2>/dev/null || true
  rm -rf "$STAND_HOME/proj" "$STAND_HOME/Library/LaunchAgents"
}

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteBotsModel.swift Sources/App/Satellites/RemoteBotsPage.swift Sources/Modules/Bots/UI/BotsView.swift Sources/Modules/Bots/BotsMonitor.swift Sources/Modules/Bots/UI/BotsWire.swift

# Команды бота запускает только BotRunner, и он спрашивает стенд.
if grep -q 'Kit.standRefuses' Sources/Kit/BotExec.swift && ! grep -rn 'Exec.run' Sources/Modules/Bots Sources/Apps/Bots | grep -v 'Exec.launchctl' | grep -q .; then
  ok "команды ботов запускает только BotRunner, а он спрашивает Kit.standRefuses"
else
  bad "в модуле «Боты» есть запуск команд мимо BotRunner или нет Kit.standRefuses"
fi

# Поиск ботов только читает: в его файле и в очистке текста из Kit нет записи, запуска программ, сети и launchd.
if /usr/bin/grep -nE 'O_WRONLY|O_RDWR|O_CREAT|FileHandle\(forW|\.write\(|createFile|createDirectory|removeItem|moveItem|copyItem|setAttributes|unlink\(|rename\(|chmod\(|Process\(|posix_spawn|Exec\.|system\(|URLSession|NWConnection|CFStream|socket\(|connect\(|NSWorkspace|kill\(|launchctl' Sources/Modules/Bots/BotsDiscovery.swift Sources/Kit/ScreenText.swift | /usr/bin/grep -vE '^[0-9]+:[[:space:]]*//' | /usr/bin/grep -q .; then
  bad "в BotsDiscovery.swift есть запись, запуск программ или сеть"
else
  ok "в BotsDiscovery.swift нет записи, запуска программ, сети и launchd"
fi
# Собирается отдельно, без остального кода: поиск зависит только от очистки текста, а она ни от чего.
mkdir -p "$OUT/probe-home/Library/LaunchAgents"
if swiftc -parse-as-library -target "$TARGET" -o "$OUT/discovery-probe" Sources/Modules/Bots/BotsDiscovery.swift Sources/Kit/ScreenText.swift Tests/BotsDiscoveryProbe.swift 2>"$OUT/probe-build.log" \
   && [ "$("$OUT/discovery-probe" --home "$OUT/probe-home" | head -1)" = "найдено: 0, пропущено: 0" ]; then
  ok "поиск собирается один, без остального кода, и в пустом доме ничего не находит"
else
  bad "отдельная сборка поиска не удалась (см. $OUT/probe-build.log)"
fi

# `pure`: только логика и изоляция, без утилиты и launchd. Нужен для поломок проверки.
if [ "${1:-}" = pure ]; then
  build_module_hub Tests/BotsRemoteCheck.swift
  "$HUB" pure && echo "ЛОГИКА «БОТОВ»: ВСЁ ОК" || { echo "ЛОГИКА «БОТОВ»: ПРОВАЛ"; exit 1; }
  exit 0
fi

build_utility
build_module_hub Tests/BotsRemoteCheck.swift

defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
PID="$(agent_pid)"

echo "== чужая подпись"
check_foreign_rejected

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

# Тихий простой: экран открыт, но ничего не меняется. Под арендой опрос раз в 5 с, пока экрана нет, процесс спит.
echo "== простой: экран закрыт"
sleep 3
echo "     утилита: rss $(ps -o rss= -p "$PID" | tr -d ' ') КБ, CPU за 20 с: $(top -l 3 -s 10 -pid "$PID" -stats cpu | tail -1 | tr -d ' ') %"
echo "== простой: экран открыт"
"$HUB" idle "$OUT" > "$OUT/idle.log" & IDLE_PID=$!
for _ in $(seq 1 100); do grep -q готов "$OUT/idle.log" && break; sleep 0.1; done
sleep 8
echo "     утилита: rss $(ps -o rss= -p "$PID" | tr -d ' ') КБ, CPU за 20 с: $(top -l 3 -s 10 -pid "$PID" -stats cpu | tail -1 | tr -d ' ') %"
kill -9 "$IDLE_PID" 2>/dev/null || true
wait "$IDLE_PID" 2>/dev/null || true
IDLE_PID=""

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «БОТЫ»"
