#!/bin/bash
# Модули читают настройки только через Kit.defaults: в утилите `.standard` — чужой пустой домен,
# и это выглядело бы как потеря настроек с последующей перезаписью при первом сохранении.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

# Помощник ссылок собирается без Kit, а эта строка делает то же, что Kit.defaults. Других исключений нет.
ALLOWED='^Sources/Modules/Browser/UI/BrowserCatalog\.swift:[0-9]+:        return Bundle\.main\.bundleIdentifier == defaultsDomain \? \.standard : \(UserDefaults\(suiteName: defaultsDomain\) \?\? \.standard\)$'

# Шире, чем `UserDefaults.standard` и `= .standard`: `from: .standard` и `?? .standard` тоже дают чужой домен.
# grep: 0 — нашёл, 1 — пусто, больше — ошибка самого grep (её нельзя принять за «пусто»).
status=0
FOUND="$(grep -rnE '\.standard\b|\bUserDefaults\(\)' --include='*.swift' Sources/Modules)" || status=$?
case "$status" in
  0|1) ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

status=0
BAD="$(grep -vE "$ALLOWED" <<<"$FOUND")" || status=$?
case "$status" in
  0) if [ -n "$BAD" ]; then echo "ПРОВАЛ: настройки модуля мимо Kit.defaults:"; echo "$BAD"; exit 1; fi ;;
  1) ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

echo "Настройки модулей: OK"
