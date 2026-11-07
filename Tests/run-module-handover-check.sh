#!/bin/bash
# Передача модуля от центра утилите: таблица решений, ModuleManager, опрос и очередь установщика в SatelliteRegistry.
# launchctl, загрузка и связь подставные, пути в папке теста, настройки в своём suite.
# Папка: MODULE_HANDOVER_CHECK_DIR, иначе $TMPDIR/module-handover-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MODULE_HANDOVER_CHECK_DIR:-${TMPDIR:-/tmp}/module-handover-check}"

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
CACHE="$(incremental_cache module-handover "$TARGET")"
rm -rf "$OUT"
mkdir -p "$OUT/src"

# Код Kit вне центра читал бы настоящий домен local.utilitumus: здесь Kit.defaults — домен самого бинарника.
sed 's/Bundle\.main\.bundleIdentifier == hubBundleID/true/' Sources/Kit/KitDefaults.swift > "$OUT/src/KitDefaults.swift"
if ! grep -q 'UserDefaults = true' "$OUT/src/KitDefaults.swift"; then
  echo "ПРОВАЛ: подмена Kit.defaults не сработала"
  exit 1
fi

cp Tests/ModuleHandoverCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift KitDefaults.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
FILES=("$CACHE/src/main.swift" "$CACHE/src/KitDefaults.swift" $(find Sources/Kit -name '*.swift' -not -name KitDefaults.swift | sort) \
  Sources/App/ModuleManager.swift Sources/App/ModuleScope.swift Sources/App/ModuleReset.swift Sources/Modules/Keyboard/InputSources.swift \
  Sources/App/SidebarLayout.swift Tests/HubLinkStubs.swift \
  Sources/App/Satellites/ModuleHandover.swift Sources/App/Satellites/SatelliteRegistry.swift \
  Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteAgent.swift Sources/App/Satellites/ModuleMigration.swift Sources/App/Design/DashState.swift)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -module-name ModuleHandoverCheck -o "$OUT/module-handover-check" \
  "${FILES[@]}" -framework SwiftUI -framework AppKit -framework Carbon

"$OUT/module-handover-check" "$OUT/work"
