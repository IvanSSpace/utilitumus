#!/bin/bash
# Показ панели «Буфера» автору: отдельное приложение во временной папке, панель настоящая, записи выдуманные.
# Без истории, ключа, настроек, горячей клавиши и слежения за буфером. Клик вставки только пишет «Вставил бы: …», системный буфер не тронут.
# Настоящую вставку в другую программу этот показ не проверяет. Скрипт только собирает и печатает команду запуска, сам ничего не открывает.
# Папка: CLIPBOARD_PANEL_PREVIEW_DIR, иначе $TMPDIR/clipboard-panel-preview.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
TMP="${TMPDIR:-/tmp}"
OUT="${CLIPBOARD_PANEL_PREVIEW_DIR:-${TMP%/}/clipboard-panel-preview}"
APP="$OUT/ClipboardPanelPreview.app"
mkdir -p "$OUT"

# Страж обещания выше: grep 0 — нашёл, 1 — пусто, больше — ошибка самого grep.
status=0
FOUND="$(/usr/bin/grep -nE 'ClipboardController|ClipboardStore|ClipboardKeychain|Keyring|NSPasteboard|Kit\.pasteboard|Kit\.defaults|UserDefaults|RegisterEventHotKey|CGEvent' Tests/ClipboardPanelPreview.swift Tests/ClipboardPanelFixture.swift)" || status=$?
case "$status" in
  0) echo "ПРОВАЛ: показ трогает настоящий модуль:"; echo "$FOUND"; exit 1 ;;
  1) ;;
  *) echo "ПРОВАЛ: grep завершился с кодом $status"; exit 1 ;;
esac

. Tests/lib/incremental.sh
CACHE="$(incremental_cache clipboard-panel-preview KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
for name in ClipboardPanelPreview ClipboardPanelFixture; do
  cmp -s "Tests/$name.swift" "$CACHE/src/$name.swift" || cp "Tests/$name.swift" "$CACHE/src/$name.swift"
done
FILES=("$CACHE/src/ClipboardPanelPreview.swift" "$CACHE/src/ClipboardPanelFixture.swift")
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Modules/Clipboard Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Сборка со швом: даже чтение темы и палитры идёт в тестовый домен настроек, настоящий недоступен.
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name ClipboardPanelPreview \
  -o "$APP/Contents/MacOS/ClipboardPanelPreview" "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CryptoKit -framework Security -framework Carbon
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClipboardPanelPreview</string>
<key>CFBundleIdentifier</key><string>local.utilitumus.test.clipboardpanelpreview</string>
<key>CFBundleName</key><string>ClipboardPanelPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null

echo "Собрано: $APP"
echo "Запуск (цветная тема):  open -n \"$APP\""
echo "Запуск (Графит):        open -n \"$APP\" --args graphite"
echo "Выход: Esc при закрытом поиске и окошке."
