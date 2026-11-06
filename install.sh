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

# Помощники утилиты, «путь в бандле|identifier». Та же таблица, что KitSigning.helpers. Список здесь, а не в бандле:
# подделанный бандл не вычеркнет из него помощника.
helpers_of() {
  case "$1" in
    browser) echo 'Contents/Helpers/Utilitumus Links.app|local.utilitumus.links' ;;
    fans) echo 'Contents/MacOS/utilitumus-fan|local.utilitumus.fan' ;;
    voice) echo 'Contents/MacOS/utilitumus-voice|local.utilitumus.voice' ;;
  esac
}

# Утилита по каталогу. Каталог и архив недоверенные, как и GitHub выше: доверие держится на подписи.
CATALOG_URL="${CATALOG_URL:-https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/Catalog/catalog.json}"
fail() { echo "$1" >&2; exit 1; }
# Вне UTF-8: диапазон [a-z] не должен зависеть от языка системы.
matches() { local LC_ALL=C; [[ "$1" =~ $2 ]]; }
# На чистом Mac может не быть python3, а plutil есть всегда и читает JSON.
catalog_field() { plutil -extract "$1" raw -o - "$WORK/catalog.json" 2>/dev/null; }
info_field() { plutil -extract "$1" raw -o - "$2/Contents/Info.plist" 2>/dev/null; }

# Тот же номер, что KitSigning.securityEpoch. Новее своей можно, старее нет.
SECURITY_EPOCH=1
epoch_ok() { # бандл
  local FOUND
  FOUND="$(info_field UtilitumusSecurityEpoch "$1")" || return 1
  matches "$FOUND" '^[0-9]{1,18}$' && [ "$FOUND" -ge "$SECURITY_EPOCH" ]
}

require_runtime() { # путь, как назвать в сообщении
  # Через переменную: grep -q закрыл бы канал раньше времени, а при pipefail это выглядит как сбой.
  local DETAILS
  DETAILS="$(codesign -d --verbose=1 "$1" 2>&1)" || DETAILS=""
  matches "$DETAILS" 'flags=0x[0-9a-f]+\([^)]*runtime' || fail "$2 собран без hardened runtime — ничего не установлено."
}

# Правила те же, что у KitSigning.verifyHelper.
verify_helper() { # бандл, путь в нём, identifier
  local HELPER="$1/$2"
  if [ -L "$HELPER" ] || [ ! -e "$HELPER" ]; then
    fail "В архиве нет помощника $2 — ничего не установлено."
  fi
  case "$2" in
    *.app)
      verify_signature "$HELPER" "$3" || refuse "$2"
      epoch_ok "$HELPER" || fail "У помощника $2 нет метки выпуска ${SECURITY_EPOCH} или новее — ничего не установлено."
      ;;
    *)
      codesign --verify -R="identifier \"$3\" and certificate leaf = H\"$TRUSTED_LEAF_HASH\"" "$HELPER" >/dev/null 2>&1 || refuse "$2"
      ;;
  esac
  require_runtime "$HELPER" "Помощник $2"
}

# Состав архива до распаковки: ditto пишет на диск раньше любой проверки подписи, и ссылка внутри архива с файлом
# «через» неё увела бы запись за пределы папки. Имена: ни `..`, ни абсолютного пути, ни управляющих символов.
# Режимы из `unzip -Z`: только обычные файлы и каталоги.
vet_archive() { # архив
  local LISTING ENTRY
  LISTING="$(unzip -Z1 "$1" 2>/dev/null)" || fail "Скачанный файл — не zip."
  while IFS= read -r ENTRY; do
    case "/${ENTRY//\\//}/" in
      //* | */../*) fail "В архиве путь за пределы папки: ${ENTRY}" ;;
    esac
    # Вне UTF-8 и без locale: диапазон управляющих символов не зависит от языка системы.
    if LC_ALL=C grep -q '[[:cntrl:]]' <<<"$ENTRY"; then fail "В архиве управляющий символ в имени."; fi
  done <<<"$LISTING"
  if unzip -Z "$1" 2>/dev/null | LC_ALL=C grep -E '^[lcbpsD][-rwxsStTa]{6,9}[[:space:]]' >/dev/null; then
    fail "В архиве ссылка или особый файл — ничего не установлено."
  fi
}

# Сборка со стендовым швом подписана тем же ключом (KitSigning.testPeerEpoch) и не должна встать как настоящая.
# Образец собран из частей: целиком он был бы строкой в самом скрипте.
reject_seam() { # бандл
  local NEEDLE="local.utilitumus.""test." FOUND
  FOUND="$(find "$1/Contents" -type f \( -path '*/MacOS/*' -o -path '*/Helpers/*' -o -name Info.plist \) -exec grep -laF -e "$NEEDLE" {} + 2>/dev/null || true)"
  [ -z "$FOUND" ] || fail "В сборке следы тестового шва — ничего не установлено."
}

# launchd отпускает метку не сразу после bootout.
load_agent() {
  local ATTEMPT=1
  until launchctl bootstrap "gui/$UID" "$1" 2>/dev/null; do
    [ "$ATTEMPT" -lt 10 ] || return 1
    ATTEMPT=$((ATTEMPT + 1))
    sleep 0.3
  done
}

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
  matches "$VERSION" '^[0-9]{1,18}(\.[0-9]{1,18})*$' || fail "В каталоге недопустимая версия: ${VERSION}"

  echo "Скачиваю ${ID} ${VERSION}…"
  local ZIP="$WORK/app.zip"
  curl -fsSL -o "$ZIP" --url "$URL" || fail "Архив не скачался."
  if [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" != "$(echo "$SHA" | tr '[:upper:]' '[:lower:]')" ]; then
    fail "Контрольная сумма архива не совпала с каталогом — ничего не установлено."
  fi

  vet_archive "$ZIP"
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
  epoch_ok "$APP" || fail "У ${NAME}.app нет метки выпуска ${SECURITY_EPOCH} или новее — ничего не установлено."
  reject_seam "$APP"
  local HELPER_PATH HELPER_ID
  while IFS='|' read -r HELPER_PATH HELPER_ID; do
    [ -z "$HELPER_PATH" ] || verify_helper "$APP" "$HELPER_PATH" "$HELPER_ID"
  done <<<"$(helpers_of "$ID")"

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
  # Прошлый запуск мог сорваться на возврате: бандла нет, а .old — единственная копия. Удалять её нельзя.
  if [ -e "$DEST.old" ] && [ ! -e "$DEST" ]; then
    mv "$DEST.old" "$DEST" || fail "Не удалось вернуть прежнюю версию ${NAME}: она лежит в ${DEST}.old"
  fi
  rm -rf -- "$DEST.new" "$DEST.old"
  ditto "$APP" "$DEST.new"
  local OLD_AGENT="$WORK/old-agent.plist"
  if [ -f "$AGENT" ]; then cp "$AGENT" "$OLD_AGENT"; fi
  local HAD_OLD=""
  if [ -e "$DEST" ]; then HAD_OLD=1; fi
  # Отказ — обычно значит «не был загружен»; настоящий сбой покажет bootstrap.
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  if { [ -z "$HAD_OLD" ] || mv "$DEST" "$DEST.old"; } && mv "$DEST.new" "$DEST" && cp "$WORK/agent.plist" "$AGENT" && load_agent "$AGENT"; then
    # Новая версия уже работает: остаток .old уберёт следующий запуск.
    rm -rf -- "$DEST.old" || true
    echo "$NAME $VERSION установлен в $DEST."
    return
  fi

  # Сорвалось после снятия старой версии: вернуть её, иначе у человека не осталось бы ничего.
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  # Старая версия могла и не уехать в .old: тогда она всё ещё на месте и удалять её нельзя.
  if [ -z "$HAD_OLD" ] || [ -e "$DEST.old" ]; then rm -rf -- "$DEST" || true; fi
  rm -rf -- "$DEST.new" || true
  # Сначала бандл: сбой уборки при set -e не должен оставить его в .old. Под остатком mv положил бы копию внутрь.
  if [ -e "$DEST.old" ]; then
    if [ -e "$DEST" ] || ! mv "$DEST.old" "$DEST"; then
      fail "$NAME $VERSION не установлен, и прежнюю версию вернуть не удалось: она лежит в ${DEST}.old"
    fi
  fi
  rm -f -- "$AGENT" || true
  if [ -f "$OLD_AGENT" ]; then
    { cp "$OLD_AGENT" "$AGENT" && load_agent "$AGENT"; } \
      || fail "$NAME $VERSION не установлен, и прежнюю версию launchd не загрузил: ${AGENT}"
  fi
  if [ -n "$HAD_OLD" ]; then fail "$NAME $VERSION не установлен. Прежняя версия возвращена."; fi
  fail "$NAME $VERSION не установлен: не удалось положить приложение или загрузить ${LABEL}."
}

# Для scripts/build-app.sh: манифест утилиты не должен расходиться с тем, что проверяет установщик.
if [ $# -eq 2 ] && [ "$1" = "--helpers" ]; then
  helpers_of "$2"
  exit 0
fi

if [ $# -gt 0 ]; then
  install_app "$@"
  exit 0
fi

echo "Скачиваю последнюю версию…"
curl -fsSL -o "$WORK/Utilitumus.zip" "$URL"
vet_archive "$WORK/Utilitumus.zip"
ditto -x -k "$WORK/Utilitumus.zip" "$WORK"
APP="$WORK/Utilitumus.app"

echo "SHA-256 архива: $(shasum -a 256 "$WORK/Utilitumus.zip" | cut -d' ' -f1)"
verify_signature "$APP" "local.utilitumus" || refuse "Utilitumus.app"
# Старые сборки автора (до 0.5) подписаны тем же ключом, но без метки выпуска и hardened runtime: подпись они проходят.
epoch_ok "$APP" || fail "У Utilitumus.app нет метки выпуска ${SECURITY_EPOCH} или новее — ничего не установлено."
require_runtime "$APP" "Utilitumus.app"
reject_seam "$APP"
# Помощники, если они есть в архиве: те же правила, что у KitSigning.verifyHelper. Битая ссылка тоже «есть».
for HELPER in 'Contents/Helpers/Utilitumus Links.app|local.utilitumus.links' \
  'Contents/MacOS/utilitumus-fan|local.utilitumus.fan' 'Contents/MacOS/utilitumus-voice|local.utilitumus.voice'; do
  if [ -e "$APP/${HELPER%%|*}" ] || [ -L "$APP/${HELPER%%|*}" ]; then
    verify_helper "$APP" "${HELPER%%|*}" "${HELPER##*|}"
  fi
done
# Режимы файлов подпись не запечатывает.
WRITABLE="$(find "$APP" ! -type l \( -perm -020 -o -perm -002 \))"
[ -z "$WRITABLE" ] || fail "В архиве запись разрешена группе или всем: ${WRITABLE}"
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
