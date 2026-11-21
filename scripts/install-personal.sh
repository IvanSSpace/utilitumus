#!/bin/bash
# Ставит личную утилиту (Module.isPersonal) на этот Mac: собирает, подписывает как build-app.sh, кладёт бандл и агента так же,
# как установщик центра (SatelliteInstaller.install), только без скачивания. Никакой публикации: в каталог и в выпуски
# личные утилиты не входят (scripts/release-all.sh их пропускает).
#   scripts/install-personal.sh studio
# Порядок как у установщика: сборка во временную папку → проверка подписи → копия рядом с местом назначения (тот же том) →
# остановка прежней утилиты → замена бандла → плист агента (тот же, что SatelliteAgent.plist) → launchctl bootstrap.
# Не вышло после начала замены — всё возвращается назад. Центр после этого видит бандл: опрос находит Info.plist, утилита
# отвечает по метке launchd, модуль появляется в панели и Сторе при следующем запуске центра (ModuleScope), выключенным.
#
# Только для проверок (Tests/run-studio-install-check.sh): подмена мест назначения и сборки. Задаются все четыре сразу
# и абсолютными путями, иначе отказ: частичная подмена могла бы смешать настоящее место с подставным.
#   UTILITUMUS_PERSONAL_APPS_DIR   вместо /Applications/Utilitumus
#   UTILITUMUS_PERSONAL_AGENTS_DIR вместо ~/Library/LaunchAgents
#   UTILITUMUS_PERSONAL_BUILD      вместо scripts/build-app.sh
#   UTILITUMUS_PERSONAL_LAUNCHCTL  вместо /bin/launchctl
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."

fail() { echo "$1" >&2; exit 1; }

# id:Имя. Список один с Module.isPersonal и PERSONAL в scripts/release-all.sh.
PERSONAL="studio:Studio"
ID="${1:-}"
NAME=""
for pair in $PERSONAL; do [ "${pair%%:*}" = "$ID" ] && NAME="${pair##*:}"; done
[ $# -eq 1 ] && [ -n "$NAME" ] || fail "Использование: scripts/install-personal.sh <id>. Личные утилиты: $(for p in $PERSONAL; do printf '%s ' "${p%%:*}"; done)"

APPS_DIR="${UTILITUMUS_PERSONAL_APPS_DIR:-}"
AGENTS_DIR="${UTILITUMUS_PERSONAL_AGENTS_DIR:-}"
BUILD="${UTILITUMUS_PERSONAL_BUILD:-}"
LAUNCHCTL="${UTILITUMUS_PERSONAL_LAUNCHCTL:-}"
if [ -n "$APPS_DIR$AGENTS_DIR$BUILD$LAUNCHCTL" ]; then
  [ -n "$APPS_DIR" ] && [ -n "$AGENTS_DIR" ] && [ -n "$BUILD" ] && [ -n "$LAUNCHCTL" ] \
    || fail "Подмена задаётся целиком: APPS_DIR, AGENTS_DIR, BUILD и LAUNCHCTL."
  for value in "$APPS_DIR" "$AGENTS_DIR" "$BUILD" "$LAUNCHCTL"; do
    case "$value" in /*) ;; *) fail "Подмена: нужны абсолютные пути (${value})." ;; esac
  done
  [ -x "$BUILD" ] && [ -x "$LAUNCHCTL" ] || fail "Подмена: BUILD и LAUNCHCTL должны быть исполняемыми файлами."
else
  APPS_DIR="/Applications/Utilitumus"
  AGENTS_DIR="$HOME/Library/LaunchAgents"
  BUILD="scripts/build-app.sh"
  LAUNCHCTL="/bin/launchctl"
fi
# Путь попадает в плист и в аргументы launchctl: латиница, цифры и . _ - /.
for value in "$APPS_DIR" "$AGENTS_DIR"; do
  [[ "$value" =~ ^/[A-Za-z0-9/._-]+$ ]] || fail "Пути назначения: только латиница, цифры и . _ - / (${value})."
done
[[ "$APPS_DIR" != *..* && "$AGENTS_DIR" != *..* ]] || fail "Пути назначения без «..»."


INFO="Sources/Apps/$NAME/Info.plist"
[ -f "$INFO" ] || fail "Нет $INFO"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUNDLE_ID="local.utilitumus.app.$ID"
BUNDLE="$APPS_DIR/$NAME.app"
AGENT="$AGENTS_DIR/$BUNDLE_ID.plist"
DOMAIN="gui/$(id -u)"

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/install-personal.XXXXXX")"
STAGE=""
cleanup() {
  [ -z "$STAGE" ] || rm -rf -- "$STAGE"
  rm -rf -- "$BUILD_DIR"
}
trap cleanup EXIT

echo "== Сборка $NAME $VERSION"
"$BUILD" "$ID" "$NAME" "$VERSION" "$BUILD_DIR/out" >"$BUILD_DIR/build.log" 2>&1 || { tail -20 "$BUILD_DIR/build.log" >&2; fail "Сборка не вышла."; }
BUILT="$BUILD_DIR/out/$NAME.app"
[ -d "$BUILT" ] || fail "Сборка не оставила $NAME.app."

echo "== Проверка"
codesign --verify --deep --strict "$BUILT" 2>/dev/null || fail "Подпись бандла не проходит проверку."
# Вывод сначала в переменную: `grep -q` в конце конвейера закрывает его рано, codesign ловит SIGPIPE, и под pipefail проверка
# сама по себе краснела бы через раз.
SIGNATURE="$(codesign -dvv "$BUILT" 2>&1)" || fail "Подпись бандла не читается."
grep -qx "Identifier=$BUNDLE_ID" <<<"$SIGNATURE" || fail "Подписан не как $BUNDLE_ID."
[ "$(plutil -extract CFBundleIdentifier raw -o - "$BUILT/Contents/Info.plist")" = "$BUNDLE_ID" ] || fail "CFBundleIdentifier не $BUNDLE_ID."
[ -n "$(plutil -extract UtilitumusSecurityEpoch raw -o - "$BUILT/Contents/Info.plist" 2>/dev/null || true)" ] || fail "У бандла нет метки выпуска."
EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$BUILT/Contents/Info.plist")"
# Имя идёт в плист агента: только безопасные символы, как у путей назначения.
[[ "$EXECUTABLE" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Недопустимое имя исполняемого файла: ${EXECUTABLE}."
[ -x "$BUILT/Contents/MacOS/$EXECUTABLE" ] || fail "В бандле нет исполняемого файла $EXECUTABLE."
scripts/check-no-seam.sh "$BUILT" || fail "В бандле следы тестового шва: в таком виде он не ставится."

echo "== Установка в $APPS_DIR"
CREATED_APPS=""
[ -d "$APPS_DIR" ] || CREATED_APPS=1
mkdir -p "$APPS_DIR" "$AGENTS_DIR"
# Рядом с местом назначения: тот же том, поэтому mv ниже — переименование, а не копия.
STAGE="$(mktemp -d "$APPS_DIR/.install-$ID.XXXXXX")"
ditto "$BUILT" "$STAGE/$NAME.app"
# Плист тот же, что у SatelliteAgent.plist: метка, запуск при входе, без перезапуска, службы центра и копии из Finder.
# Путь в плисте — только из безопасных символов (проверен выше), в XML ему нечего экранировать.
NEWAGENT="$STAGE/agent.plist"
cat > "$NEWAGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<false/>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>MachServices</key>
	<dict>
		<key>$BUNDLE_ID.self.xpc</key>
		<true/>
		<key>$BUNDLE_ID.xpc</key>
		<true/>
	</dict>
	<key>ProgramArguments</key>
	<array>
		<string>$BUNDLE/Contents/MacOS/$EXECUTABLE</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST
plutil -lint "$NEWAGENT" >/dev/null || fail "Плист агента не собрался."

HAD_BUNDLE=""; HAD_AGENT=""
[ ! -e "$BUNDLE" ] || HAD_BUNDLE=1
[ ! -e "$AGENT" ] || HAD_AGENT=1
[ -z "$HAD_AGENT" ] || cp -p "$AGENT" "$STAGE/previous-agent.plist"

# С этого места прерывание (Ctrl-C, SIGTERM) возвращает прежнее, а не оставляет полдела.
INSTALLING=1
# Нет такого агента или он не загружен — это не ошибка.
"$LAUNCHCTL" bootout "$DOMAIN/$BUNDLE_ID" >/dev/null 2>&1 || true

REPLACED=""
rollback() {
  INSTALLING=""
  echo "Не вышло, возвращаю прежнее." >&2
  "$LAUNCHCTL" bootout "$DOMAIN/$BUNDLE_ID" >/dev/null 2>&1 || true
  if [ -n "$REPLACED" ]; then
    rm -rf -- "$BUNDLE"
    if [ -n "$HAD_BUNDLE" ]; then mv "$STAGE/previous.app" "$BUNDLE"; fi
  fi
  if [ -n "$HAD_AGENT" ]; then
    cp -p "$STAGE/previous-agent.plist" "$AGENT" && "$LAUNCHCTL" bootstrap "$DOMAIN" "$AGENT" >/dev/null 2>&1 || true
  else
    rm -f -- "$AGENT"
  fi
  # Папку программ убираем, только если создали её мы и в ней больше ничего нет (rmdir, не rm -r).
  rm -rf -- "$STAGE"; STAGE=""
  [ -z "$CREATED_APPS" ] || rmdir "$APPS_DIR" 2>/dev/null || true
}

# Вызывается как условие `if !`, где `set -e` не действует: каждый шаг проверяется сам.
install_all() {
  if [ -n "$HAD_BUNDLE" ]; then mv "$BUNDLE" "$STAGE/previous.app" || return 1; fi
  REPLACED=1
  # mv в существующую папку положил бы новый бандл внутрь старого.
  [ ! -e "$BUNDLE" ] || return 1
  mv "$STAGE/$NAME.app" "$BUNDLE" || return 1
  # Плист рядом с местом назначения и mv: читателю не попадётся недописанный файл.
  cp "$NEWAGENT" "$AGENTS_DIR/.$BUNDLE_ID.plist.new" || return 1
  mv "$AGENTS_DIR/.$BUNDLE_ID.plist.new" "$AGENT" || return 1
  # launchd отпускает метку не сразу после bootout: как у установщика, до 10 попыток через 0.3 с.
  local attempt=0
  until "$LAUNCHCTL" bootstrap "$DOMAIN" "$AGENT" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] || return 1
    sleep 0.3
  done
}
on_signal() {
  trap '' INT TERM HUP
  [ -z "$INSTALLING" ] || rollback
  exit 1
}
trap on_signal INT TERM HUP
if ! install_all; then
  rollback
  fail "Установка не вышла: launchctl bootstrap не принял агента. Прежнее возвращено."
fi
INSTALLING=""
echo "Готово: $BUNDLE $VERSION. Центр увидит модуль при следующем запуске; включённым он не станет."
