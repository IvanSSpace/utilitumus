#!/bin/bash
# Ставит последнюю версию Utilitumus из GitHub Releases в /Applications и запускает.
#   curl -fsSL https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/install.sh | bash
#
# Скачивание через curl не ставит карантинный атрибут — Gatekeeper не блокирует
# первый запуск. Повторный запуск скрипта = обновление до последней версии.
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

echo "Скачиваю последнюю версию…"
curl -fsSL -o "$WORK/Utilitumus.zip" "$URL"
ditto -x -k "$WORK/Utilitumus.zip" "$WORK"
APP="$WORK/Utilitumus.app"

# GitHub — недоверенный источник: проверяем подпись автора по вшитому здесь хэшу
# листового сертификата, а не просто «подпись цела» (самоподписанную подделку
# codesign --verify без требования пропустил бы). Хэш — тот же, что в Updater.swift.
echo "SHA-256 архива: $(shasum -a 256 "$WORK/Utilitumus.zip" | cut -d' ' -f1)"
TRUSTED_LEAF_HASH="31e93f4b9e4ada7f6de82066c2194b35d92f7db4"
refuse() {
  echo "Подпись $1 не совпала с подписью автора Utilitumus — установка отменена." >&2
  echo "Архив не от автора (или повреждён); ничего не установлено." >&2
  exit 1
}
verify_signature() { # путь, identifier
  codesign --verify --deep --strict -R="identifier \"$2\" and certificate leaf = H\"$TRUSTED_LEAF_HASH\"" "$1" >/dev/null 2>&1
}
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
