#!/bin/bash
# Передача модуля от центра утилите: таблица решений, ModuleManager, опрос и очередь установщика в SatelliteRegistry.
# launchctl, загрузка и связь подставные, пути в папке теста, настройки в своём suite.
# Папка: MODULE_HANDOVER_CHECK_DIR, иначе $TMPDIR/module-handover-check.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${MODULE_HANDOVER_CHECK_DIR:-${TMPDIR:-/tmp}/module-handover-check}"

# Ни один тест не имеет права дотянуться до настоящих путей и настоящей связи.
status=0
# Ищем `Тип.live` и `liveИмя`, а не поле `state.live` и слова вроде keepalive. `liveVerify` проверяет подпись переданного
# бандла из папки теста и настоящих путей не трогает.
found="$(grep -rnE '[A-Z][A-Za-z]*\.live\b|\blive[A-Z]' Tests --include='*.swift' | grep -v 'SatelliteInstaller\.liveVerify')" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: настоящие замыкания и пути в тестах:"; echo "$found"; exit 1 ;;
  1) echo "ok   настоящие замыкания и пути в тестах: нет" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT/src"

# Код Kit вне центра читал бы настоящий домен local.utilitumus: здесь Kit.defaults — домен самого бинарника.
sed 's/Bundle\.main\.bundleIdentifier == hubBundleID/true/' Sources/Kit/KitDefaults.swift > "$OUT/src/KitDefaults.swift"
if ! grep -q 'UserDefaults = true' "$OUT/src/KitDefaults.swift"; then
  echo "ПРОВАЛ: подмена Kit.defaults не сработала"
  exit 1
fi

cp Tests/ModuleHandoverCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -module-name ModuleHandoverCheck -o "$OUT/module-handover-check" "$OUT/src/main.swift" "$OUT/src/KitDefaults.swift" \
  $(find Sources/Kit -name '*.swift' -not -name KitDefaults.swift) \
  Sources/App/ModuleManager.swift Sources/App/ModuleReset.swift Sources/Modules/Keyboard/InputSources.swift \
  Sources/App/Satellites/ModuleHandover.swift Sources/App/Satellites/SatelliteRegistry.swift \
  Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteAgent.swift Sources/App/Satellites/ModuleMigration.swift Sources/App/Design/DashState.swift \
  -framework SwiftUI -framework AppKit -framework Carbon

"$OUT/module-handover-check" "$OUT/work"
