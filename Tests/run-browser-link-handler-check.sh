#!/bin/bash
# Обработчик ссылок «Браузера»: включённость, выбор копии, установка, обновление и удаление утилиты, шаг и статус.
# Подставной LaunchServices; подпись не нужна. Настоящий local.utilitumus.links, http и https не трогаются.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
# Подпапка: скрипт чистит $OUT, а в SATELLITE_CHECK_DIR лежат стенды модулей, идущие рядом.
OUT="${SATELLITE_CHECK_DIR:-${TMPDIR:-/tmp}}/browser-link-handler-check"

# Ни проверка, ни её запуск не имеют права дотянуться до настоящего LaunchServices.
status=0
found="$(grep -nE 'LSRegisterURL|LSSetDefault|setDefaultApplication|lsregister|\.live|live[A-Z]' Tests/BrowserLinkHandlerCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: настоящий LaunchServices в проверке:"; echo "$found"; exit 1 ;;
  1) echo "ok   в проверке нет вызовов настоящего LaunchServices" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Ключи в помощнике — строки, а центр пишет их своим кодом: сверяем с первоисточником.
grep -q '"ModuleOn.\\(module.rawValue)"' Sources/App/ModuleManager.swift && echo "ok   ModuleManager пишет ModuleOn.<id>" || { echo "ПРОВАЛ: ключ ModuleOn в центре изменился"; exit 1; }

# Установщик и хуки браузера не зовут setDefaultApplication: назначает обработчик только человек.
status=0
found="$(grep -nE 'setDefault' Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/BrowserSatelliteHooks.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: установщик назначает обработчик:"; echo "$found"; exit 1 ;;
  1) echo "ok   установка и обновление не назначают обработчик" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

# Инкрементальная сборка: кэш вне папки проверки (её чистят). Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache browser-link-handler "$TARGET" KIT_TEST_DEFAULTS)"
rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/work"
cp Tests/BrowserLinkHandlerCheck.swift "$OUT/src/main.swift"
# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
mkdir -p "$CACHE/src"
for f in main.swift; do cmp -s "$OUT/src/$f" "$CACHE/src/$f" || cp "$OUT/src/$f" "$CACHE/src/$f"; done
FILES=("$CACHE/src/main.swift" $(find Sources/Kit Sources/Modules/Browser -name '*.swift' | sort) \
  Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteAgent.swift Sources/App/Satellites/ModuleHandover.swift \
  Sources/App/Satellites/BrowserSatelliteHooks.swift Sources/Apps/Browser/BrowserModule.swift Sources/Modules/Clipboard/ClipboardKeyring.swift Sources/Modules/Clipboard/ClipboardStore.swift Sources/Modules/Clipboard/ClipboardModels.swift)
incremental_flags "$CACHE" "${FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name BrowserLinkHandlerCheck -o "$OUT/check" \
  "${FILES[@]}" -framework SwiftUI -framework AppKit

# Свои настройки проверки: домен local.utilitumus.test.browserlink.
"$OUT/check" "$OUT/work"
