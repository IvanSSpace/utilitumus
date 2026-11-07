#!/bin/bash
# Модель, связь и экран модуля «Буфер». Только поддельная модель и выдуманные записи: контроллер, хранилище,
# Связка ключей и буфер обмена не создаются и не читаются. Окно за экраном и прозрачное, настроек стенд не пишет.
# Экран «до» — ClipboardView из коммита перед переходом на модель, на такой же подделке.
# Папка стенда: CLIPBOARD_WIRE_DIR, иначе $TMPDIR/clipboard-wire-check.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${CLIPBOARD_WIRE_DIR:-${TMPDIR:-/tmp}/clipboard-wire-check}"
BEFORE=509cdb3

# Страж обещания выше: grep 0 — нашёл, 1 — пусто, больше — ошибка самого grep.
status=0
FOUND="$(grep -nE 'ClipboardController|ClipboardKeychain|ClipboardStore|NSPasteboard|SecItem|index\.bin|\.shared\.(start|togglePanel)' Tests/ClipboardWireCheck.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: проверка трогает настоящий модуль:"; echo "$FOUND"; exit 1 ;;
  1) echo "ok   проверка не упоминает контроллер, хранилище, ключ и буфер" ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

rm -rf "$OUT/src"
mkdir -p "$OUT/src" "$OUT/png"
cp Tests/ClipboardWireCheck.swift "$OUT/src/ClipboardWireCheck.swift"
/usr/bin/git show "$BEFORE:Sources/Modules/Clipboard/ClipboardView.swift" \
  | sed 's/ClipboardController\.shared/LegacyFakeController.shared/; s/ClipboardView/LegacyClipboardView/; s/SpaceRow/LegacySpaceRow/' \
  > "$OUT/src/LegacyClipboardView.swift"
grep -q ClipboardController "$OUT/src/LegacyClipboardView.swift" \
  && { echo "ПРОВАЛ: старый экран всё ещё смотрит на настоящий контроллер"; exit 1; }
sed '/^@main$/d' Sources/App/UtilitumusApp.swift > "$OUT/src/UtilitumusApp.swift"

# Инкрементальная сборка: кэш и копии подставных файлов вне папки стенда. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
. Tests/lib/incremental-sync.sh
CACHE="$(incremental_cache clipboard-wire KIT_TEST_DEFAULTS)"
incremental_sync "$OUT/src" "$CACHE/src"
FILES=("$CACHE/src/ClipboardWireCheck.swift" "$CACHE/src/LegacyClipboardView.swift" "$CACHE/src/UtilitumusApp.swift")
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/VoiceHelper/*' -not -path 'Sources/Apps/*' -not -name UtilitumusApp.swift | sort)
incremental_flags "$CACHE" "${FILES[@]}"
# Файл стенда не оставляем: компоновку с другим Tests/EmbeddedInfoSeam.plist инкрементальная сборка сама не заметит.
rm -f "$OUT/check"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name ClipboardWireCheck -o "$OUT/check" \
  "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfoSeam.plist
"$OUT/check" "$OUT"
