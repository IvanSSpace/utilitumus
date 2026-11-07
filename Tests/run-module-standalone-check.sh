#!/bin/bash
# Каждая папка Sources/Modules/<X> компилируется с одним Sources/Kit и записанными здесь дополнительными исходниками.
# Без аргументов — все модули; можно назвать отдельные: Tests/run-module-standalone-check.sh Fans Voice
set -uo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

# Дополнительные исходники модуля вне его папки и Kit. Их должен взять и манифест сборки утилиты.
extras() {
  case "$1" in
    Fans) echo Sources/Shared/SMC.swift Sources/Shared/FanLink.swift ;;
  esac
}

if [ $# -gt 0 ]; then
  MODULES=("$@")
else
  MODULES=()
  for dir in Sources/Modules/*/; do MODULES+=("$(basename "$dir")"); done
fi
[ ${#MODULES[@]} -gt 0 ] || { echo "ПРОВАЛ: нет модулей"; exit 1; }

# Инкрементальная сборка: у каждого модуля свой кэш. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh

failed=0
for module in "${MODULES[@]}"; do
  [ -d "Sources/Modules/$module" ] || { echo "ПРОВАЛ $module: нет папки"; failed=$((failed + 1)); continue; }
  # shellcheck disable=SC2046 # пути без пробелов, как и в остальных проверках
  files=($(find "Sources/Modules/$module" Sources/Kit -name '*.swift' | sort) $(extras "$module"))
  incremental_flags "$(incremental_cache "module-standalone-$module" "$TARGET")" "${files[@]}"
  # У -typecheck нет объектов, поэтому и нечего переиспользовать: в инкрементальном режиме объекты собираются, но не компонуются.
  mode=(-typecheck)
  [ -n "${INCREMENTAL_OFF:-}" ] || mode=(-c "${INC_FLAGS[@]}" -module-name "Standalone$module")
  if log="$(swiftc "${mode[@]}" -parse-as-library -target "$TARGET" "${files[@]}" 2>&1)"; then
    echo "ok     $module"
  else
    echo "ПРОВАЛ $module"
    grep -E 'error:' <<<"$log" | grep -E '^/|^Sources' | sed "s|^$PWD/||" | sort -u | head -20
    failed=$((failed + 1))
  fi
done

if [ "$failed" -gt 0 ]; then
  echo "ПРОВАЛ: не компилируются отдельно: $failed"
  exit 1
fi
echo "Модули по отдельности: OK (${#MODULES[@]})"
