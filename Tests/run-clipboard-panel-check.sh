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
  Tests/ClipboardPanelCheck.swift Tests/ClipboardPanelFixture.swift Tests/ClipboardPanelFilm.swift

PANEL=(Sources/Modules/Clipboard/ClipboardPanel.swift Sources/Modules/Clipboard/ClipboardPanelCard.swift Sources/Modules/Clipboard/ClipboardPanelLogic.swift Sources/Modules/Clipboard/ClipboardPanelDrag.swift)
# Приёмник категории проходит те же стражи сети и активации. В страже масштаба его нет: страж про карточку, а масштаб категории под переносом задан.
DROP=Sources/Modules/Clipboard/ClipboardPanelDrop.swift
absent "панель не ходит в сеть: сайт не узнает, что скопировано" \
  'URLSession|URLRequest|LinkPresentation|LPMetadata|WKWebView|WebKit|AsyncImage|NSImage\(contentsOf|Data\(contentsOf|dataTask' "${PANEL[@]}" "$DROP"
absent "панель не активирует приложение и не открывает окон, которые могли бы" \
  'NSApp\.activate|NSRunningApplication\.current\.activate|\.popover\(|\.sheet\(|\.alert\(|runModal|setActivationPolicy' "${PANEL[@]}" "$DROP"
absent "выделение не ждёт двойного клика системы" 'onTapGesture\(count' "${PANEL[@]}"
absent "у выбора нет масштаба: карточка не дрожит" 'scaleEffect' "${PANEL[@]}"
# Движения панели только из одной таблицы (ClipMotion): разные пружины в разных местах были главной причиной странных анимаций.
absent "движения панели только из таблицы ClipMotion" '\.spring\(|\.easeOut\(|\.easeIn\(|\.easeInOut\(|\.linear\(|\.smooth\(|\.bouncy|\.snappy|matchedGeometry' "${PANEL[@]}"
DIRECT="$(/usr/bin/grep -nE '\.animation\(' "${PANEL[@]}" | /usr/bin/grep -vE 'value: model\.stripIdentity|\.opacity\.animation\(ClipMotion\.fade\)' || true)"
[ -z "$DIRECT" ] || { echo "$DIRECT"; fail "анимация высоко в дереве задевает всех детей: разрешена только смена ленты"; }
echo "ok   в панели нет .animation на дереве, кроме смены ленты"
absent "подсказки карточки не называют содержимое" 'help\(.*(item\.(text|filePaths|host|imageFile)|linkTitle|caption)' Sources/Modules/Clipboard/ClipboardPanelCard.swift
absent "перетаскивание не пишет содержимое ни в буфер, ни во временные файлы" 'NSPasteboard|temporaryDirectory|NSTemporaryDirectory|\.write\(' Sources/Modules/Clipboard/ClipboardPanelDrag.swift
# Кнопки только через clipPanelButton: иначе у новой кнопки вернётся системная рамка фокуса. Проверка по исходникам:
# окно за экраном не ключевое и такого фокуса не показывает, обход клавиатуры в нём зелёный и без focusable(false).
BARE="$(/usr/bin/grep -n 'buttonStyle(.plain)' Sources/Modules/Clipboard/ClipboardPanel.swift | /usr/bin/grep -v 'buttonStyle(.plain).focusable(false)' || true)"
[ -z "$BARE" ] || { echo "$BARE"; fail "кнопка панели без focusable(false)"; }
echo "ok   все кнопки панели без клавиатурного фокуса"

# ⌘V только через завершение ухода панели: иначе клавиши ушли бы в саму панель. Само поведение проверяет checkPasteAfterLeaving.
SENDS="$(/usr/bin/grep -c 'sendPaste' Sources/Modules/Clipboard/ClipboardController.swift)"
/usr/bin/grep -q 'pasteAfterLeaving(ClipboardPanelHost.shared, send: Self.sendPaste)' Sources/Modules/Clipboard/ClipboardController.swift \
  && /usr/bin/grep -q 'send: @escaping @MainActor () -> Void = ClipboardController.sendPaste' Sources/Modules/Clipboard/ClipboardController.swift \
  && [ "$SENDS" = 3 ] || fail "paste: ⌘V должен уходить только через pasteAfterLeaving и pasteSequence"
echo "ok   paste шлёт ⌘V только после ухода панели"

# Прогрев панели — один отложенный вызов, без повторяющихся таймеров. Повторяющихся в модуле ровно два: опрос буфера
# (только пока утилита запущена) и шаг переноса (только пока несут карточку). Сам прогрев окно ключевым не делает,
# мониторов не ставит и номер показа не трогает, а на экран выводит только прозрачным, мимо мыши и с уходом в том же
# вызове; поведение проверяет checkPrewarm.
REPEATS="$(cat Sources/Modules/Clipboard/*.swift Sources/Modules/Clipboard/UI/*.swift | /usr/bin/grep -cE 'repeats: *true|scheduledTimer|makeTimerSource')" || true
[ "$REPEATS" = 2 ] || fail "повторяющихся таймеров в модуле $REPEATS, а должно быть 2: опрос буфера и шаг переноса"
echo "ok   повторяющихся таймеров в модуле только два, прогрев не из них"
PREWARM="$(/usr/bin/awk '/func prewarm\(/,/^    }$/' Sources/Modules/Clipboard/ClipboardPanel.swift)"
[ -n "$PREWARM" ] || fail "не нашёл func prewarm в ClipboardPanel.swift"
FOUND="$(printf '%s\n' "$PREWARM" | /usr/bin/grep -nE 'makeKey|orderFrontRegardless|activate|installMonitors|presentation|alphaValue = [^0]|ignoresMouseEvents = false|asyncAfter|main\.async' || true)"
[ -z "$FOUND" ] || { echo "$FOUND"; fail "прогрев делает окно ключевым, видимым, ловящим мышь или откладывает уход"; }
printf '%s\n' "$PREWARM" | /usr/bin/awk '/alphaValue = 0/{a=NR} /ignoresMouseEvents = true/{m=NR} /orderFront\(nil\)/{f=NR} /orderOut\(nil\)/{o=NR}
  END { exit !(a && m && f && o && a < f && m < f && f < o) }' \
  || fail "прогрев: альфа 0 и мимо мыши до orderFront, orderOut после него в том же вызове"
echo "ok   прогрев выводит окно только прозрачным и мимо мыши и убирает в том же вызове"
/usr/bin/grep -q 'DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelPrepareDelay)' Sources/Modules/Clipboard/ClipboardController.swift \
  || fail "прогрев панели должен запускаться одним отложенным вызовом"
echo "ok   прогрев запускается одним отложенным вызовом"

. Tests/lib/incremental.sh
CACHE="$(incremental_cache clipboard-panel KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src"
for name in ClipboardPanelCheck ClipboardPanelFixture ClipboardPanelFilm; do
  cmp -s "Tests/$name.swift" "$CACHE/src/$name.swift" || cp "Tests/$name.swift" "$CACHE/src/$name.swift"
done
export KIT_TEST_SUITE="local.utilitumus.test.kit.clipboardpanel"
# Тестовые домены local.utilitumus.test.* — это сам шов, их стенд пишет по праву (Tests/stand-snapshot.sh, Kit.standForbiddenRoot).
# Поэтому из настоящего ~/Library/Preferences удаляется только точное имя такого домена: без масок, каталогов и «..».
# Имя не прошло проверку — ничего не удаляем, предупреждаем и проверку не роняем.
cleanup_test_defaults() {
  local suite="${KIT_TEST_SUITE:-}" prefix="local.utilitumus.test."
  case "$suite" in
    "$prefix"*) ;;
    # Фигурные скобки обязательны: bash 3.2 в UTF-8 читает первый байт «»» как часть имени переменной.
    *) echo "ПРЕДУПРЕЖДЕНИЕ: KIT_TEST_SUITE=«${suite}» не начинается с ${prefix} — тестовые настройки не удаляю" >&2; return 0 ;;
  esac
  case "${suite#"$prefix"}" in
    "" | .* | *..* | *[![:alnum:]._-]*)
      echo "ПРЕДУПРЕЖДЕНИЕ: в KIT_TEST_SUITE=«${suite}» пустой хвост, «..» или знак кроме букв, цифр, «.», «_», «-» — тестовые настройки не удаляю" >&2
      return 0 ;;
  esac
  defaults delete "$suite" 2>/dev/null || true
  case "${HOME:-}" in
    /*) rm -f -- "$HOME/Library/Preferences/${suite}.plist" ;;
    *) echo "ПРЕДУПРЕЖДЕНИЕ: HOME=«${HOME:-}» не абсолютный путь — файл ${suite}.plist не удаляю" >&2 ;;
  esac
}
trap cleanup_test_defaults EXIT
FILES=("$CACHE/src/ClipboardPanelCheck.swift" "$CACHE/src/ClipboardPanelFixture.swift" "$CACHE/src/ClipboardPanelFilm.swift")
while IFS= read -r f; do FILES+=("$f"); done < <(find Sources/Modules/Clipboard Sources/Kit -name '*.swift' | sort)
incremental_flags "$CACHE" "${FILES[@]}"
rm -f "$OUT/check"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name ClipboardPanelCheck -o "$OUT/check" "${FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CryptoKit -framework Security -framework Carbon \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tests/EmbeddedInfoSeam.plist
"$OUT/check" "$PNG"
echo "     снимки: $PNG"
