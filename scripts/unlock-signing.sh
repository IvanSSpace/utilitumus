#!/bin/bash
# Разблокирует связку с сертификатом «Utilitumus Signing». Единственное место, где пароль связки читается.
# Пароль идёт в `security -i` по stdin из встроенной printf: в argv ни одного процесса его нет, и в трассе
# (`bash -x`) тоже: -x здесь выключен, а встроенные команды в вызывающем скрипте трассируются без значений.
# Нет файла пароля или связки (CI) — ничего не делает: дальше подпись ad-hoc.
#   scripts/unlock-signing.sh
set +x
set -euo pipefail
{ set +x; } 2>/dev/null

PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KEYCHAIN="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
[ -f "$PASSWORD_FILE" ] && [ -f "$KEYCHAIN" ] || exit 0

# Очередь сборок подставляет свой `security` в PATH: он не знает -i и сам берёт пароль у себя.
if [ "$(command -v security)" != /usr/bin/security ]; then
  security unlock-keychain "$KEYCHAIN"
  exit 0
fi

# $(<файл) — встроенное чтение, без cat.
PASSWORD="$(<"$PASSWORD_FILE")"
case "$PASSWORD" in
  *$'\n'* | '') echo "Пароль связки пуст или многострочный." >&2; exit 1 ;;
esac
# В командах `security -i` пароль в двойных кавычках, внутри них \ и " экранируются.
PASSWORD="${PASSWORD//\\/\\\\}"
PASSWORD="${PASSWORD//\"/\\\"}"
# Ошибку `security -i` выводит текстом и выходит с 0, поэтому смотрим на вывод.
if ! OUTPUT="$(printf 'unlock-keychain -p "%s" "%s"\n' "$PASSWORD" "$KEYCHAIN" | /usr/bin/security -i 2>&1)" \
  || [[ "$OUTPUT" == *"security:"* ]]; then
  echo "Связка подписи не разблокировалась." >&2
  exit 1
fi
