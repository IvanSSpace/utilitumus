#!/bin/bash
# Ставит последнюю версию Utilitumus из GitHub Releases в /Applications и запускает.
#   curl -fsSL https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/install.sh | bash
#
# Скачивание через curl не ставит карантинный атрибут — Gatekeeper не блокирует
# первый запуск. Повторный запуск скрипта = обновление до последней версии.
#
# Отдельная утилита по каталогу, с той же проверкой подписи:
#   curl -fsSL https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/install.sh | bash -s -- awake
# С --dry-run после id проверяет всё и останавливается до записи на диск и launchctl.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
URL="https://github.com/IvanSSpace/utilitumus/releases/latest/download/Utilitumus.zip"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Utilitumus работает только на Mac с Apple Silicon (M1 и новее)." >&2
  exit 1
fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
MINOR=$(sw_vers -productVersion | cut -d. -f2)
if [ "$MAJOR" -lt 14 ] || { [ "$MAJOR" -eq 14 ] && [ "${MINOR:-0}" -lt 2 ]; }; then
  echo "Нужна macOS 14.2 или новее, у тебя $(sw_vers -productVersion)." >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# GitHub — недоверенный источник: проверяем подпись автора по вшитому здесь хэшу
# листового сертификата, а не просто «подпись цела» (самоподписанную подделку
# codesign --verify без требования пропустил бы). Хэш — тот же, что в Sources/Kit/KitSigning.swift.
TRUSTED_LEAF_HASH="31e93f4b9e4ada7f6de82066c2194b35d92f7db4"
refuse() {
  echo "Подпись $1 не совпала с подписью автора Utilitumus — установка отменена." >&2
  echo "Архив не от автора (или повреждён); ничего не установлено." >&2
  exit 1
}
verify_signature() { # путь, identifier
  codesign --verify --deep --strict -R="identifier \"$2\" and certificate leaf = H\"$TRUSTED_LEAF_HASH\"" "$1" >/dev/null 2>&1
}

# Утилита по каталогу. Каталог и архив недоверенные, как и GitHub выше: доверие держится на подписи.
CATALOG_URL="${CATALOG_URL:-https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/Catalog/catalog.json}"
fail() { echo "$1" >&2; exit 1; }
# Вне UTF-8: диапазон [a-z] не должен зависеть от языка системы.
matches() { local LC_ALL=C; [[ "$1" =~ $2 ]]; }
# На чистом Mac может не быть python3, а plutil есть всегда и читает JSON.
catalog_field() { plutil -extract "$1" raw -o - "$WORK/catalog.json" 2>/dev/null; }
info_field() { plutil -extract "$1" raw -o - "$2/Contents/Info.plist" 2>/dev/null; }

install_app() {
  local ID="$1" DRY_RUN=""
  # id подставляется в требование подписи и в путь к плисту. Те же правила, что у SatelliteCatalog.isValidID.
  matches "$ID" '^[a-z0-9][a-z0-9.-]*$' || fail "Недопустимый id: ${ID}"
  case "$#:${2-}" in
    1:) ;;
    2:--dry-run) DRY_RUN=1 ;;
    # Опечатка в --dry-run не должна превращаться в настоящую установку.
    *) fail "Неизвестный аргумент: ${2-}" ;;
  esac
  # launchd не загрузит плист, доступный на запись группе.
  umask 022

  echo "Читаю каталог…"
  curl -fsSL -o "$WORK/catalog.json" --url "$CATALOG_URL" || fail "Каталог не скачался."
  local SCHEMA COUNT INDEX=0 VERSION="" URL="" SHA=""
  SCHEMA="$(catalog_field schema)" || fail "Каталог не читается."
  [ "$SCHEMA" = 1 ] || fail "Каталог другого формата (${SCHEMA}): этот скрипт устарел."
  COUNT="$(catalog_field apps)" || fail "Каталог не читается."
  # [ -lt ], а не (( )): арифметика bash выполнила бы подстановку из недоверенной строки.
  while [ "$INDEX" -lt "$COUNT" ]; do
    if [ "$(catalog_field "apps.$INDEX.id")" = "$ID" ]; then
      VERSION="$(catalog_field "apps.$INDEX.version")" || fail "Запись ${ID} в каталоге неполная."
      URL="$(catalog_field "apps.$INDEX.url")" || fail "Запись ${ID} в каталоге неполная."
      SHA="$(catalog_field "apps.$INDEX.sha256")" || fail "Запись ${ID} в каталоге неполная."
      break
    fi
    INDEX=$((INDEX + 1))
  done
  [ -n "$URL" ] || fail "Утилиты ${ID} нет в каталоге."
  matches "$VERSION" '^[0-9]+(\.[0-9]+)*$' || fail "В каталоге недопустимая версия: ${VERSION}"

  echo "Скачиваю ${ID} ${VERSION}…"
  local ZIP="$WORK/app.zip"
  curl -fsSL -o "$ZIP" --url "$URL" || fail "Архив не скачался."
  if [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" != "$(echo "$SHA" | tr '[:upper:]' '[:lower:]')" ]; then
    fail "Контрольная сумма архива не совпала с каталогом — ничего не установлено."
  fi

  # ditto молча убирает `..` и начальный `/`, и такой архив выглядел бы обычным: смотреть надо до распаковки.
  local LISTING ENTRY
  LISTING="$(unzip -Z1 "$ZIP" 2>/dev/null)" || fail "Скачанный файл — не zip."
  while IFS= read -r ENTRY; do
    case "/${ENTRY//\\//}/" in
      //* | */../*) fail "В архиве путь за пределы папки: ${ENTRY}" ;;
    esac
  done <<<"$LISTING"
  ditto -x -k "$ZIP" "$WORK/unpacked"

  # Имя станет путём в /Applications и попадёт в плист, поэтому правила те же, что у build-app.sh.
  local TOP NAME APP LABEL="local.utilitumus.app.$ID"
  TOP="$(ls -A "$WORK/unpacked")"
  matches "$TOP" '^[A-Za-z][A-Za-z0-9]*\.app$' || fail "В архиве должен быть один .app, внутри: ${TOP}"
  NAME="${TOP%.app}"
  APP="$WORK/unpacked/$TOP"
  if [ -L "$APP" ] || [ ! -d "$APP" ]; then
    fail "${TOP} в архиве — не папка."
  fi
  # Режимы файлов подпись не запечатывает.
  local WRITABLE
  WRITABLE="$(find "$APP" ! -type l \( -perm -020 -o -perm -002 \))"
  [ -z "$WRITABLE" ] || fail "В архиве запись разрешена группе или всем: ${WRITABLE}"

  verify_signature "$APP" "$LABEL" || refuse "$NAME.app"

  # Сверка с каталогом уже после подписи: Info.plist ею запечатан.
  local ACTUAL
  ACTUAL="$(info_field CFBundleIdentifier "$APP" || true)"
  [ "$ACTUAL" = "$LABEL" ] || fail "В бандле другой identifier: ${ACTUAL}"
  ACTUAL="$(info_field CFBundleShortVersionString "$APP" || true)"
  [ "$ACTUAL" = "$VERSION" ] || fail "В бандле версия ${ACTUAL}, в каталоге ${VERSION}."
  ACTUAL="$(info_field CFBundleExecutable "$APP" || true)"
  if [ "$ACTUAL" != "$NAME" ] || [ ! -x "$APP/Contents/MacOS/$NAME" ]; then
    fail "В бандле нет исполняемого файла ${NAME}."
  fi

  local DEST="$INSTALL_DIR/Utilitumus/$NAME.app"
  local AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
  # Те же ключи, что у SatelliteAgent в центре.
  cat > "$WORK/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<false/>
	<key>Label</key>
	<string>$LABEL</string>
	<key>MachServices</key>
	<dict>
		<key>$LABEL.xpc</key>
		<true/>
	</dict>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/$NAME</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST

  if [ -n "$DRY_RUN" ]; then
    echo "Проверка пройдена: $NAME $VERSION встал бы в $DEST, агент в $AGENT:"
    cat "$WORK/agent.plist"
    return
  fi

  # Рядом и переносом: пока копия не готова, старая версия цела и работает.
  mkdir -p "$INSTALL_DIR/Utilitumus" "$HOME/Library/LaunchAgents"
  rm -rf -- "$DEST.new"
  ditto "$APP" "$DEST.new"
  # Отказ — обычно значит «не был загружен»; настоящий сбой покажет bootstrap.
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -rf -- "$DEST"
  mv "$DEST.new" "$DEST"
  cp "$WORK/agent.plist" "$AGENT"
  # launchd отпускает метку не сразу после bootout.
  local ATTEMPT=1
  until launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null; do
    [ "$ATTEMPT" -lt 10 ] || fail "launchd не загрузил ${LABEL}: ${AGENT}"
    ATTEMPT=$((ATTEMPT + 1))
    sleep 0.3
  done
  echo "$NAME $VERSION установлен в $DEST."
}

if [ $# -gt 0 ]; then
  install_app "$@"
  exit 0
fi

echo "Скачиваю последнюю версию…"
curl -fsSL -o "$WORK/Utilitumus.zip" "$URL"
ditto -x -k "$WORK/Utilitumus.zip" "$WORK"
APP="$WORK/Utilitumus.app"

echo "SHA-256 архива: $(shasum -a 256 "$WORK/Utilitumus.zip" | cut -d' ' -f1)"
verify_signature "$APP" "local.utilitumus" || refuse "Utilitumus.app"
LINKS="$APP/Contents/Helpers/Utilitumus Links.app"
if [ -d "$LINKS" ]; then
  verify_signature "$LINKS" "local.utilitumus.links" || refuse "Utilitumus Links.app"
fi
VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)

# Запущенную версию закрываем штатно: она вернёт вентиляторы в «Авто».
if pgrep -qf "$INSTALL_DIR/Utilitumus.app/Contents/MacOS/Utilitumus"; then
  osascript -e 'quit app "Utilitumus"' || true
  sleep 2
fi

if [ -d "$INSTALL_DIR/Utilitumus.app" ]; then
  rm -rf -- "$INSTALL_DIR/Utilitumus.app"
fi
ditto "$APP" "$INSTALL_DIR/Utilitumus.app"
echo "Utilitumus $VERSION установлен в $INSTALL_DIR."

if [ -z "${NO_OPEN:-}" ]; then
  open "$INSTALL_DIR/Utilitumus.app"
fi
