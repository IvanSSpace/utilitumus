#!/bin/bash
# Передача модуля от центра утилите: таблица решений, ModuleManager, опрос и очередь установщика в SatelliteRegistry.
# launchctl, загрузка и связь подставные, пути в папке теста, настройки в своём suite. FnSystemAction настоящий, но со швом
# KIT_TEST_DEFAULTS: AppleFnUsageType, горячие клавиши и применение настроек подменены, nm ниже проверяет, что записи в систему нет.
# Папка: MODULE_HANDOVER_CHECK_DIR, иначе $TMPDIR/module-handover-check.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MODULE_HANDOVER_CHECK_DIR:-${TMPDIR:-/tmp}/module-handover-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.module-handover"
cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
cleanup

# Ни один тест не имеет права дотянуться до настоящих путей и настоящей связи.
status=0
# Ищем `Тип.live` и `liveИмя`, а не поле `state.live` и слова вроде keepalive. `liveVerify` проверяет подпись переданного
# бандла из папки теста и настоящих путей не трогает. `BotsMonitor.liveProbe(getpid())` читает libproc про сам тест, и только с getpid().
found="$(grep -rnE '[A-Z][A-Za-z]*\.live\b|\blive[A-Z]' Tests --include='*.swift' | grep -vE 'SatelliteInstaller\.liveVerify|BotsMonitor\.liveProbe\(getpid\(\)\)')" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: настоящие замыкания и пути в тестах:"; echo "$found"; exit 1 ;;
  1) echo "ok   настоящие замыкания и пути в тестах: нет" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache module-handover "$TARGET" KIT_TEST_DEFAULTS)"
rm -rf "$OUT"
mkdir -p "$OUT/src"

cp Tests/ModuleHandoverCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
cmp -s "$OUT/src/main.swift" "$CACHE/src/main.swift" || cp "$OUT/src/main.swift" "$CACHE/src/main.swift"
FILES=("$CACHE/src/main.swift" $(find Sources/Kit -name '*.swift' | sort) \
  Sources/App/ModuleManager.swift Sources/App/ModuleScope.swift Sources/App/ModuleReset.swift Sources/Modules/Keyboard/UI/FnSystemAction.swift \
  Sources/App/SidebarLayout.swift Tests/HubLinkStubs.swift \
  Sources/App/Satellites/ModuleHandover.swift Sources/App/Satellites/SatelliteRegistry.swift \
  Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteAgent.swift Sources/App/Satellites/ModuleMigration.swift Sources/App/Design/DashState.swift)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name ModuleHandoverCheck -o "$OUT/module-handover-check" \
  "${FILES[@]}" -framework SwiftUI -framework AppKit -framework Carbon

# Настоящий AppleFnUsageType не должен быть достижим ни из одного сценария.
if nm -u "$OUT/module-handover-check" | grep -E '_CFPreferencesSetAppValue'; then echo "ПРОВАЛ: проверка умеет менять систему"; exit 1; fi
echo "ok   запись настроек системы в бинарнике: нет"

"$OUT/module-handover-check" "$OUT/work"
