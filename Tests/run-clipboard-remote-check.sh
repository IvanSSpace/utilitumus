#!/bin/bash
# Вкладка «Буфер» в лаунчере, работа в утилите: пиксели встроенного и внешнего экрана, чужая подпись, плохие действия,
# пассивная утилита остановлена, смерть утилиты, передача ключа только от центра (не от копии утилиты и не от чужого).
# Настоящие подписанная утилита, launchd и связь; Связка ключей только в памяти, история во временной папке, буфер не опрашивается.
# Нужен сертификат «Utilitumus Signing», поэтому запускать через очередь сборок. Папка стенда: SATELLITE_CHECK_DIR.
set -euo pipefail
source "$(dirname "$0")/satellite-check-lib.sh"
satellite_check_setup clipboard Clipboard

# Страж: проверка не называет настоящую связку, каталог истории и буфер.
status=0
FOUND="$(grep -nE 'SystemClipboardKeyring|ClipboardKeychain|NSPasteboard|SecItem(Copy|Add|Delete|Update)|defaultDirectory|Application Support|history-key' Tests/ClipboardRemoteCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка называет настоящую связку, каталог или буфер:"; echo "$FOUND"; exit 1 ;;
  1) ok "проверка не называет настоящую связку, каталог истории и буфер" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

OWNCOPY="$OUT/clipboard-check-owncopy"
satellite_check_extra_cleanup() { rm -f "$OWNCOPY"; defaults delete clipboard-check-owncopy 2>/dev/null || true; }

forbid_timers Sources/App/Satellites/RemoteModuleModel.swift Sources/App/Satellites/RemoteModulePage.swift Sources/App/Satellites/RemoteClipboardPage.swift

build_utility
build_module_hub Tests/ClipboardRemoteCheck.swift
# Копия самой утилиты (так запускает её Finder): слушатель её пускает, ключ она передать не должна.
cp "$OUT/hub-build" "$OWNCOPY"
codesign --force --options runtime --sign "$SIGN_NAME" --identifier "$IDENTIFIER" "$OWNCOPY" 2>/dev/null

echo "== пассивная утилита: центр ≥0.6.0 держит модуль"
defaults write "$SUITE" "ModuleOn.$ID" -bool true
defaults write "$SUITE" Test.HubRunning -bool true
defaults write "$SUITE" Test.HubVersion -string 0.6.0
start_agent
"$HUB" passive "$OUT" || bad "пассивная утилита: проверка не прошла"

echo "== активная утилита ждёт ключ"
satellite_reset_suite
defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
# Выдуманный ключ прежней записи: в память стенда, не в Связку ключей.
defaults write "$SUITE" Test.ClipboardLegacyKey -string "$(head -c 32 /dev/urandom | base64)"
start_agent
PID="$(agent_pid)"
for _ in $(seq 1 100); do [[ "$("$HUB" state)" == *'"keyState":"waiting"'* ]] && break; sleep 0.1; done
[[ "$("$HUB" state)" == *'"keyState":"waiting"'* ]] && ok "утилита ждёт ключ" || bad "утилита не перешла в ожидание ключа"

echo "== чужая подпись и копия утилиты"
check_foreign_rejected
BEFORE="$("$HUB" state)"
COPY="$("$OWNCOPY" own-copy "$OUT" || true)"
same "копия утилиты: ключ не принят, состояние то же" "$COPY" "received=false stateSame=true"
same "после копии утилита всё ещё ждёт ключ" "$("$HUB" state)" "$BEFORE"

echo "== вкладка"
"$HUB" run "$OUT" "$PID"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «БУФЕР»"
