#!/bin/bash
# Обёртка для общего прогона: снимок настоящих мест до и после любой команды.
#   Tests/with-stand-snapshot.sh Tests/run-xxx-check.sh [аргументы]
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source Tests/stand-snapshot.sh
SNAP="$(mktemp -t stand-before)"
stand_snapshot_take "$SNAP"
"$@"
rc=$?
if ! stand_snapshot_compare "$SNAP" && [ "$rc" -eq 0 ]; then rc=1; fi
rm -f "$SNAP"
exit "$rc"
