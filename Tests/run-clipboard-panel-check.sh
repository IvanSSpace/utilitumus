#!/bin/bash
# Панель «Буфера»: клики, клавиши, категории через колбэки на временном хранилище, поиск, снимки вне экрана.
# Контроллер настоящий, но без запуска: ни опроса буфера, ни горячей клавиши. Хранилище во временной папке с выдуманным ключом,
# окно прозрачное и за экраном, настройки в своём suite. Настоящей вставки в другую программу проверка не делает.
# Снимки: CLIPBOARD_PANEL_PNG, иначе $TMPDIR/clipboard-panel-check/png.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${TMPDIR:-/tmp}/clipboard-panel-check"
PNG="${CLIPBOARD_PANEL_PNG:-$OUT/png}"
mkdir -p "$OUT" "$PNG"

fail() { echo "ПРОВАЛ: $*"; exit 1; }
absent() { # имя, шаблон, файлы...
  local name="$1" pattern="$2" found status=0; shift 2
  found="$(/usr/bin/grep -nE "$pattern" "$@")" || status=$?
  case "$status" in
    0) echo "$found"; fail "$name" ;;
    1) echo "ok   $name" ;;
    *) fail "grep завершился с кодом $status" ;;
  esac
}

absent "проверка не называет настоящую связку, каталог истории и общий буфер" \
  'SystemClipboardKeyring|ClipboardKeychain\.system|NSPasteboard\.general|Kit\.pasteboard|SecItem(Copy|Add|Delete|Update)|defaultDirectory|Application Support|history-key|\.paste\(' \
  Tests/ClipboardPanelCheck.swift Tests/ClipboardPanelFixture.swift

PANEL=(Sources/Modules/Clipboard/ClipboardPanel.swift Sources/Modules/Clipboard/ClipboardPanelCard.swift Sources/Modules/Clipboard/ClipboardPanelLogic.swift Sources/Modules/Clipboard/ClipboardPanelDrag.swift)
absent "панель не ходит в сеть: сайт не узнает, что скопировано" \
  'URLSession|URLRequest|LinkPresentation|LPMetadata|WKWebView|WebKit|AsyncImage|NSImage\(contentsOf|Data\(contentsOf|dataTask' "${PANEL[@]}"
absent "панель не активирует приложение и не открывает окон, которые могли бы" \
  'NSApp\.activate|NSRunningApplication\.current\.activate|\.popover\(|\.sheet\(|\.alert\(|runModal|setActivationPolicy' "${PANEL[@]}"
absent "выделение не ждёт двойного клика системы" 'onTapGesture\(count' "${PANEL[@]}"
absent "у выбора нет масштаба: карточка не дрожит" 'scaleEffect' "${PANEL[@]}"
absent "перетаскивание не пишет содержимое ни в буфер, ни во временные файлы" 'NSPasteboard|temporaryDirectory|NSTemporaryDirectory|\.write\(' Sources/Modules/Clipboard/ClipboardPanelDrag.swift
# Кнопки только через clipPanelButton: иначе у новой кнопки вернётся системная рамка фокуса. Проверка по исходникам:
# окно за экраном не ключевое и такого фокуса не показывает, обход клавиатуры в нём зелёный и без focusable(false).
BARE="$(/usr/bin/grep -n 'buttonStyle(.plain)' Sources/Modules/Clipboard/ClipboardPanel.swift | /usr/bin/grep -v 'buttonStyle(.plain).focusable(false)' || true)"
[ -z "$BARE" ] || { echo "$BARE"; fail "кнопка панели без focusable(false)"; }
echo "ok   все кнопки панели без клавиатурного фокуса"

# hide() до ⌘V: иначе клавиши ушли бы в саму панель.
HIDE="$(/usr/bin/grep -n 'ClipboardPanelHost.shared.hide()' Sources/Modules/Clipboard/ClipboardController.swift | tail -1 | cut -d: -f1)"
SEND="$(/usr/bin/grep -n 'asyncAfter.*sendPaste' Sources/Modules/Clipboard/ClipboardController.swift | cut -d: -f1)"
[ -n "$HIDE" ] && [ -n "$SEND" ] && [ "$HIDE" -lt "$SEND" ] || fail "paste: hide() должен идти до отправки ⌘V"
echo "ok   paste прячет панель до ⌘V"

. Tests/lib/incremental.sh
CACHE="$(incremental_cache clipboard-panel KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
for name in ClipboardPanelCheck ClipboardPanelFixture; do
  cmp -s "Tests/$name.swift" "$CACHE/src/$name.swift" || cp "Tests/$name.swift" "$CACHE/src/$name.swift"
done
export KIT_TEST_SUITE="local.utilitumus.test.kit.clipboardpanel"
trap 'defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"' EXIT
FILES=("$CACHE/src/ClipboardPanelCheck.swift" "$CACHE/src/ClipboardPanelFixture.swift")
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Modules/Clipboard Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
rm -f "$OUT/check"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name ClipboardPanelCheck -o "$OUT/check" "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CryptoKit -framework Security -framework Carbon \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfoSeam.plist
"$OUT/check" "$PNG"
echo "     снимки: $PNG"
