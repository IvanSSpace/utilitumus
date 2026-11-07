#!/bin/bash
# Вкладка «Микшер» в лаунчере, работа в утилите. Настоящие подписанная утилита, launchd и связь; звук не перехватывается:
# утилита стенда собрана со швом (--test-seam), тапы в ней не создаются. Захват системного звука и разрешение — руками.
# Папка стенда: SATELLITE_CHECK_DIR; снимки в mixer/png.
# Совместимость настоящими сборками: новый лаунчер с Микшером из тега, и лаунчер из тега, с его же проверкой, с новым Микшером.
# Теги надо двигать, когда у людей появляются новые версии: это пары, которые встретятся при поэтапном обновлении.
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

# Дерево прошлого выпуска. Путь постоянный, а распаковка однократная: иначе время файлов новое и кэш сборки бесполезен.
old_tree() { # тег
  local tree
  tree="$(incremental_cache "old-tree-$1")"
  if [ ! -e "$tree/.ready" ]; then
    rm -rf "$tree"
    mkdir -p "$tree"
    /usr/bin/git archive "$1" Sources scripts Tests Info.plist | tar -x -C "$tree"
    touch "$tree/.ready"
  fi
  echo "$tree"
}

OLD_MIXER_TAG="mixer-v1.3.0"
OLD_HUB_TAG="v0.9.0"

echo "== пара: этот лаунчер и Микшер $OLD_MIXER_TAG"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
OLD_UTILITY="$OUT/old-utility"
mkdir -p "$OLD_UTILITY"
TREE="$(old_tree "$OLD_MIXER_TAG")"
( cd "$TREE" && build_seam_utility "$ID" "$NAME" 1.2.3 "$OLD_UTILITY" --test-seam )
satellite_reset_suite
defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
# Откат: на диске настройки новой версии. Старая их не читает и не стирает.
defaults write "$SUITE" MixerEqualizer -dict test.fixture.idle '{enabled=1;preset=voice;bands=(1,2,3,4,5,6,7,8,9,10);}'
SAVED_EQ="$(defaults read "$SUITE" MixerEqualizer)"
NEW_EXE="$EXE"
EXE="$OLD_UTILITY/$NAME.app/Contents/MacOS/$NAME"
/usr/bin/grep -q setEqualizer "$EXE" && bad "сборка из $OLD_MIXER_TAG уже знает эквалайзер: сверять не с чем" || ok "в сборке из $OLD_MIXER_TAG эквалайзера нет"
start_agent
MIXER_PAIR=old-utility "$HUB" run "$OUT" "$(agent_pid)"
same "Микшер $OLD_MIXER_TAG не тронул настройки эквалайзера" "$(defaults read "$SUITE" MixerEqualizer)" "$SAVED_EQ"
EXE="$NEW_EXE"

echo "== пара: лаунчер $OLD_HUB_TAG со своей проверкой и этот Микшер"
TREE="$(old_tree "$OLD_HUB_TAG")"
( cd "$TREE" && build_module_hub Tests/MixerRemoteCheck.swift )
satellite_reset_suite
defaults write "$SUITE" Test.HubRunning -bool false
defaults write "$SUITE" "App.$ID.Enabled" -bool true
start_agent
/usr/bin/grep -q setEqualizer "$OUT/hub-build" && bad "сборка из $OLD_HUB_TAG уже знает эквалайзер: сверять не с чем" || ok "в лаунчере из $OLD_HUB_TAG эквалайзера нет"
for _ in $(seq 1 50); do STATE="$("$HUB" state)"; [ -n "$STATE" ] && break; sleep 0.1; done
[[ "$STATE" == *'"eq":'* ]] && ok "этот Микшер отдаёт ему состояние с полем eq" || bad "в состоянии нет поля eq: пара ничего не доказывает"
"$HUB" run "$OUT" "$(agent_pid)"

echo "     снимки: $OUT/png"
satellite_check_finish "ВКЛАДКА «МИКШЕР»"
