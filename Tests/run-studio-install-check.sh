#!/bin/bash
# scripts/install-personal.sh: установка личной утилиты. Всё во временной папке: места назначения, сборка и launchctl подменены
# (настоящие /Applications, ~/Library/LaunchAgents, связка ключей и launchd не трогаются), бандл подписан ad-hoc прямо в проверке.
# Что проверяется: бандл и агент на месте, плист байт в байт по смыслу как у SatelliteAgent.plist, обновление заменяет,
# сбой bootstrap возвращает прежнее, после работы нет промежуточных папок, отказы на чужом id, частичной подмене и негодном бандле.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${STUDIO_INSTALL_DIR:-${T%/}/studio-install-check}"
# rm -rf разрешён только внутри папки, созданной mktemp под $TMPDIR прямо здесь.
WORK="$(mktemp -d "${T%/}/studio-install-check.XXXXXX")"
case "$WORK" in "${T%/}"/studio-install-check.*) ;; *) echo "ПРОВАЛ: странная рабочая папка $WORK"; exit 1 ;; esac
trap 'chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

fail() { echo "ПРОВАЛ: $1"; exit 1; }
ok() { echo "ok   $1"; }
same() { [ "$2" = "$3" ] && ok "$1" || fail "$1: ждал «$3», вышло «$2»"; }

APPS="$WORK/apps/Utilitumus"
AGENTS="$WORK/agents"
LOG="$WORK/launchctl.log"
AGENT="$AGENTS/local.utilitumus.app.studio.plist"
BUNDLE="$APPS/Studio.app"

# Настоящие места: снимок до и после. Скрипт получает подмену, но проверка ещё и сверяет, что настоящее осталось как было.
real_snapshot() { stat -f '%m %z %N' /Applications/Utilitumus/Studio.app "$HOME/Library/LaunchAgents/local.utilitumus.app.studio.plist" 2>&1 || true; }
REAL_BEFORE="$(real_snapshot)"

# Подставная сборка: бандл подписан ad-hoc (без связки ключей), содержимое по STUB_MARK.
cat > "$WORK/build.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
id="$1"; name="$2"; version="$3"; out="$4"
app="$out/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "local.utilitumus.app.$id" "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string "$name" "$app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -insert UtilitumusSecurityEpoch -string "1" "$app/Contents/Info.plist"
cp /usr/bin/true "$app/Contents/MacOS/$name"
printf '%s' "${STUB_MARK:-1}" > "$app/Contents/Resources/mark"
[ -z "${STUB_SEAM:-}" ] || printf 'local.utilitumus.%s' "test.x" >> "$app/Contents/MacOS/$name"
[ -n "${STUB_UNSIGNED:-}" ] || codesign --force --sign - --identifier "local.utilitumus.app.$id" "$app" >/dev/null 2>&1
STUB
cat > "$WORK/launchctl.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
if [ "${1:-}" = bootstrap ] && [ -n "${STUB_SLEEP:-}" ]; then sleep "$STUB_SLEEP"; fi
if [ "${1:-}" = bootstrap ] && [ -n "${STUB_FAIL_BOOTSTRAP:-}" ]; then exit 5; fi
exit 0
STUB
chmod +x "$WORK/build.sh" "$WORK/launchctl.sh"

install() { # переменные окружения добавляет вызывающий
  UTILITUMUS_PERSONAL_APPS_DIR="$APPS" UTILITUMUS_PERSONAL_AGENTS_DIR="$AGENTS" \
  UTILITUMUS_PERSONAL_BUILD="$WORK/build.sh" UTILITUMUS_PERSONAL_LAUNCHCTL="$WORK/launchctl.sh" STUB_LOG="$LOG" \
    scripts/install-personal.sh "$@"
}
mark() { cat "$BUNDLE/Contents/Resources/mark"; }
leftovers() { find "$APPS" -mindepth 1 -maxdepth 1 -name '.*' 2>/dev/null | wc -l | tr -d ' '; }
agent_json() { plutil -convert json -r -o - "$1"; }

echo "== Образец: плист установщика центра"
mkdir -p "$WORK/ref"
cp Tests/StudioAgentPlist.swift "$WORK/ref/main.swift"
swiftc -target "$TARGET" -o "$WORK/ref/plist" "$WORK/ref/main.swift" Sources/App/Satellites/SatelliteAgent.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort) -framework SwiftUI -framework AppKit 2>"$WORK/ref/build.log" \
  || { /usr/bin/tail -20 "$WORK/ref/build.log"; fail "образец не собрался"; }

echo "== Первая установка"
install studio >"$WORK/out1.log" 2>&1 || { cat "$WORK/out1.log"; fail "установка не вышла"; }
[ -d "$BUNDLE" ] && ok "бандл на месте" || fail "нет бандла"
same "в бандле нужная сборка" "$(mark)" "1"
[ -f "$AGENT" ] && ok "плист агента на месте" || fail "нет плиста"
"$WORK/ref/plist" "$BUNDLE/Contents/MacOS/Studio" > "$WORK/ref/expected.plist"
same "плист как у установщика центра" "$(agent_json "$AGENT")" "$(agent_json "$WORK/ref/expected.plist")"
same "launchctl: сначала bootout, потом bootstrap" "$(cat "$LOG" | sed -E 's#gui/[0-9]+#gui/UID#' | tr '\n' ';')" \
  "bootout gui/UID/local.utilitumus.app.studio;bootstrap gui/UID $AGENT;"
same "в папке программ нет промежуточного" "$(leftovers)" "0"
same "в папке агентов нет промежуточного" "$(find "$AGENTS" -mindepth 1 -name '.*' | wc -l | tr -d ' ')" "0"
codesign --verify --deep --strict "$BUNDLE" 2>/dev/null && ok "подпись бандла цела после установки" || fail "подпись не проходит"

echo "== Обновление поверх"
: > "$LOG"
STUB_MARK=2 install studio >"$WORK/out2.log" 2>&1 || { cat "$WORK/out2.log"; fail "обновление не вышло"; }
same "новая сборка на месте" "$(mark)" "2"
same "плист прежний по смыслу" "$(agent_json "$AGENT")" "$(agent_json "$WORK/ref/expected.plist")"
same "launchctl при обновлении тот же порядок" "$(sed -E 's#gui/[0-9]+#gui/UID#' "$LOG" | tr '\n' ';')" \
  "bootout gui/UID/local.utilitumus.app.studio;bootstrap gui/UID $AGENT;"
same "промежуточного нет и после обновления" "$(leftovers)" "0"
same "кроме бандла в папке программ ничего" "$(ls -A "$APPS")" "Studio.app"

echo "== Сбой bootstrap при обновлении: прежнее возвращается"
BEFORE_PLIST="$(shasum -a 256 < "$AGENT")"
: > "$LOG"
if STUB_MARK=3 STUB_FAIL_BOOTSTRAP=1 install studio >"$WORK/out3.log" 2>&1; then fail "сбой bootstrap принят за успех"; fi
same "бандл прежний" "$(mark)" "2"
same "плист прежний байт в байт" "$(shasum -a 256 < "$AGENT")" "$BEFORE_PLIST"
same "промежуточного нет" "$(leftovers)" "0"
grep -q "^bootstrap " "$LOG" && ok "прежний агент загружен обратно" || fail "прежний агент не возвращён"

echo "== Сбой замены бандла (mv не вышел): прежнее цело"
BEFORE_PLIST="$(shasum -a 256 < "$AGENT")"
chflags uchg "$BUNDLE"
: > "$LOG"
if STUB_MARK=4 install studio >"$WORK/out3b.log" 2>&1; then chflags nouchg "$BUNDLE"; fail "сбой замены принят за успех"; fi
chflags nouchg "$BUNDLE"
same "бандл прежний, не вложенный в себя" "$(mark)" "2"
[ ! -e "$BUNDLE/Studio.app" ] && ok "новый бандл внутрь старого не лёг" || fail "новый бандл лёг внутрь старого"
same "плист прежний" "$(shasum -a 256 < "$AGENT")" "$BEFORE_PLIST"
same "промежуточного нет" "$(leftovers)" "0"
grep -q "^bootstrap " "$LOG" && ok "прежний агент загружен обратно" || fail "прежний агент не возвращён"

echo "== Прерывание посреди установки: прежнее возвращается"
: > "$LOG"
( STUB_MARK=5 STUB_SLEEP=2 install studio >"$WORK/out3c.log" 2>&1 ) &
SPID=$!
for _ in $(seq 1 100); do grep -q "^bootstrap " "$LOG" && break; sleep 0.2; done
grep -q "^bootstrap " "$LOG" || { kill "$SPID" 2>/dev/null || true; fail "установка не дошла до bootstrap"; }
pkill -TERM -P "$SPID" -f install-personal.sh 2>/dev/null || kill -TERM "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null && fail "прерванная установка принята за успех" || ok "прерванная установка завершилась с отказом"
same "бандл прежний" "$(mark)" "2"
same "плист прежний" "$(shasum -a 256 < "$AGENT")" "$BEFORE_PLIST"
same "промежуточного нет" "$(leftovers)" "0"

echo "== Сбой первой установки: ничего не остаётся"
/bin/rm -rf "$WORK/apps" "$WORK/agents"
if STUB_FAIL_BOOTSTRAP=1 install studio >"$WORK/out4.log" 2>&1; then fail "сбой первой установки принят за успех"; fi
[ ! -e "$BUNDLE" ] && ok "бандла нет" || fail "бандл остался"
[ ! -e "$AGENT" ] && ok "плиста нет" || fail "плист остался"
[ ! -e "$APPS" ] && ok "папку программ, которую создали мы, убрали" || fail "папка программ осталась: $(ls -A "$APPS")"

echo "== Отказы"
if install nope >"$WORK/o.log" 2>&1; then fail "чужой id принят"; fi; ok "чужой id отвергнут"
if install >"$WORK/o.log" 2>&1; then fail "без id принято"; fi; ok "без id отвергнуто"
if UTILITUMUS_PERSONAL_APPS_DIR="$APPS" scripts/install-personal.sh studio >"$WORK/o.log" 2>&1; then fail "частичная подмена принята"; fi
grep -q "целиком" "$WORK/o.log" && ok "частичная подмена отвергнута" || fail "частичная подмена: нет понятного отказа"
if UTILITUMUS_PERSONAL_APPS_DIR="relative/apps" UTILITUMUS_PERSONAL_AGENTS_DIR="$AGENTS" UTILITUMUS_PERSONAL_BUILD="$WORK/build.sh" \
  UTILITUMUS_PERSONAL_LAUNCHCTL="$WORK/launchctl.sh" scripts/install-personal.sh studio >"$WORK/o.log" 2>&1; then fail "относительный путь принят"; fi
ok "относительный путь отвергнут"
if UTILITUMUS_PERSONAL_APPS_DIR="$WORK/with space/apps" UTILITUMUS_PERSONAL_AGENTS_DIR="$AGENTS" UTILITUMUS_PERSONAL_BUILD="$WORK/build.sh" \
  UTILITUMUS_PERSONAL_LAUNCHCTL="$WORK/launchctl.sh" scripts/install-personal.sh studio >"$WORK/o.log" 2>&1; then fail "путь с пробелом принят"; fi
ok "путь с пробелом отвергнут"
if UTILITUMUS_PERSONAL_APPS_DIR="$WORK/../apps" UTILITUMUS_PERSONAL_AGENTS_DIR="$AGENTS" UTILITUMUS_PERSONAL_BUILD="$WORK/build.sh" \
  UTILITUMUS_PERSONAL_LAUNCHCTL="$WORK/launchctl.sh" scripts/install-personal.sh studio >"$WORK/o.log" 2>&1; then fail "путь с .. принят"; fi
ok "путь с «..» отвергнут"
/bin/rm -rf "$WORK/apps" "$WORK/agents"
if STUB_UNSIGNED=1 install studio >"$WORK/o.log" 2>&1; then fail "бандл без подписи принят"; fi
[ ! -e "$BUNDLE" ] && [ ! -e "$AGENT" ] && ok "бандл без подписи: ничего не установлено" || fail "бандл без подписи оставил следы"
if STUB_SEAM=1 install studio >"$WORK/o.log" 2>&1; then fail "бандл со следами шва принят"; fi
[ ! -e "$BUNDLE" ] && [ ! -e "$AGENT" ] && ok "бандл со следами тестового шва: ничего не установлено" || fail "бандл со швом оставил следы"

echo "== Настоящее не тронуто"
same "настоящие /Applications и LaunchAgents как были" "$(real_snapshot)" "$REAL_BEFORE"
echo "Установка личной утилиты: OK"
