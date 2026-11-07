#!/bin/bash
# Замок на группу проверок: проверки одной группы делят ресурс и идут по одной, разные группы идут одновременно.
#   Tests/with-check-lock.sh команда... Tests/run-xxx-check.sh [аргументы]
# Группу задаёт первый аргумент вида run-*.sh. Замок берётся раньше команды, поэтому очередь ставится внутрь:
#   Tests/with-check-lock.sh buildq build bash Tests/run-mouse-remote-check.sh
# так ожидание замка не занимает место сборки. Почему группы такие: у каждой ниже свой общий ресурс в коде.
# Папка замков общая на все копии проекта: одна и та же проверка из двух рабочих деревьев тоже идёт по одной,
# у неё в каждой копии те же метка launchd, suite, домен бинарника и папка $OUT.
set -euo pipefail

check_group() {
  case "$1" in
    # Метка local.utilitumus.test.awake у app и remote; общий suite local.utilitumus.test.kit у app, settings, e2e и role:
    # role пишет туда Test.HubBundleID, а app его читает.
    run-awake-app-check | run-awake-remote-check | run-awake-settings-check | run-hub-e2e | run-satellite-role-check) echo awake ;;
    # grep метки test.fan в run-fan-helper-check находит и test.fans.
    run-fan-helper-check | run-fans-remote-check) echo fans ;;
    # Журнал utilitumus-keyboard-test.log во временной папке один на стенд и утилиту под launchd.
    run-keyboard-remote-check | run-keyboard-wire-check) echo keyboard ;;
    # Именованный буфер Kit.pasteboard один на все сборки со швом: pure сверяет, что он не менялся, пишет в него вставка Голоса.
    run-voice-remote-check | run-voice-remote-pure-check | run-voice-wire-check) echo voice ;;
    *) echo "$1" ;;
  esac
}

name=""
for arg in "$@"; do
  case "$arg" in
    *run-*.sh) name="$(basename "$arg" .sh)"; break ;;
  esac
done
[ -n "$name" ] || { echo "with-check-lock: нет аргумента вида run-*.sh" >&2; exit 2; }

dir="${CHECK_LOCK_DIR:-${TMPDIR:-/tmp}/utilitumus-check-locks}"
mkdir -p "$dir"
exec 8>"$dir/$(check_group "$name").lock"
/usr/bin/python3 -I -c 'import fcntl; fcntl.flock(8, fcntl.LOCK_EX)'
# Замок держит только этот процесс: потомок без дескриптора не продлит его, если переживёт проверку.
"$@" 8>&-
