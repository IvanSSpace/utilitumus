#!/bin/bash
# Запуск внешних программ в «Нагрузке»: снятие ответственности, вывод, сокет tmux.
# Папка стенда: TOOL_CHECK_DIR, иначе $TMPDIR/tool-spawn-check. Настоящий tmux пользователя не трогается: у стенда свой сокет.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TOOL_CHECK_DIR:-${TMPDIR:-/tmp}/tool-spawn-check}"
rm -rf "$OUT"
mkdir -p "$OUT/work"

cat >"$OUT/child.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
int main(void) {
    pid_t (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    if (!responsible) return 2;
    printf("%d %d\n", getpid(), responsible(getpid()));
    return 0;
}
C
clang -o "$OUT/child" "$OUT/child.c"
cp Tests/ToolSpawnCheck.swift "$OUT/main.swift"
swiftc -o "$OUT/check" "$OUT/main.swift" Sources/Modules/Load/Native/Core/Tool.swift Sources/Modules/Load/Native/Sessions/MuxProbe.swift Sources/Modules/Load/UI/Native/Sessions/MuxTypes.swift
# Hardened runtime, как у приложения: dlsym и снятие ответственности должны работать и под ним.
codesign --force --options runtime --sign - "$OUT/check" 2>/dev/null
"$OUT/check" "$OUT/child" "$OUT/work"
