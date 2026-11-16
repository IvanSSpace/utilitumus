#!/bin/bash
# «Озвучка»: меню «Службы» → «Прочитать вслух», проводка модуля (init ничего не запускает, start ставит провайдера, stop снимает)
# и мини-плеер. Синтезатор, чтение выделения и сочетание подменены; провайдер у системы не регистрируется, панель не показывается,
# общий буфер обмена не читается и не пишется: у каждого вызова свой именованный буфер. AX не трогается.
# Сборка со швом KIT_TEST_DEFAULTS, дом подставной. Папка стенда: SPEAK_SERVICE_DIR, иначе $TMPDIR/speak-service-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${SPEAK_SERVICE_DIR:-${T%/}/speak-service-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.speak-service"
PLIST=Sources/Apps/Speak/Info.plist

cleanup() {
  defaults delete "$KIT_TEST_SUITE" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$KIT_TEST_SUITE.plist"
}
trap cleanup EXIT
cleanup

FAILED=0
ok() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; FAILED=1; }
# grep: 0 — нашёл, 1 — пусто, больше — ошибка самого grep (её нельзя принять за «пусто»).
none() { # что проверяем, grep -E образец, где...
  local what="$1" pattern="$2" found status=0
  shift 2
  found="$(/usr/bin/grep -rnE -- "$pattern" "$@")" || status=$?
  case "$status" in
    0) bad "$what:"; echo "$found" ;;
    1) ok "$what" ;;
    *) bad "$what: grep завершился с кодом $status" ;;
  esac
}
plist() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || echo "<нет>"; }

echo "== Исходники"
none "служба и утилита не трогают общий буфер обмена" 'NSPasteboard\.general|Kit\.pasteboard|generalPasteboard' \
  Sources/Modules/Speak/SpeakService.swift Sources/Apps/Speak
none "служба без AX" 'AXIsProcess|AXUIElement|kAX|SelectionReading|reader\.' Sources/Modules/Speak/SpeakService.swift
none "мини-плеер без текста чтения и без AX" 'AXIsProcess|AXUIElement|\.text\b|session' Sources/Modules/Speak/SpeakPlayerPanel.swift

echo "== Info.plist"
[ "$(plist NSServices.0.NSMessage)" = readAloud ] && ok "NSMessage readAloud" || bad "NSMessage не readAloud: $(plist NSServices.0.NSMessage)"
[ "$(plist NSServices.0.NSPortName)" = "$(plist CFBundleName)" ] && [ "$(plist CFBundleName)" = Speak ] \
  && ok "NSPortName совпадает с именем приложения (Speak)" || bad "NSPortName $(plist NSServices.0.NSPortName), CFBundleName $(plist CFBundleName)"
[ "$(plist NSServices.0.NSMenuItem.default)" = "Прочитать вслух" ] && ok "пункт меню «Прочитать вслух»" || bad "пункт меню: $(plist NSServices.0.NSMenuItem.default)"
SEND="$(plist NSServices.0.NSSendTypes.0) $(plist NSServices.0.NSSendTypes.1)"
[ "$SEND" = "public.utf8-plain-text NSStringPboardType" ] && ok "принимает текст: $SEND" || bad "NSSendTypes: $SEND"
[ "$(plist NSServices.0.NSReturnTypes)" = "<нет>" ] && ok "ничего не возвращает в программу (нет NSReturnTypes)" || bad "есть NSReturnTypes"
[ "$(plist NSServices.1)" = "<нет>" ] && ok "служба одна" || bad "служб больше одной"

echo "== Вживую"
rm -rf "$OUT/src" "$OUT/home"
mkdir -p "$OUT/src" "$OUT/home"
cp Tests/SpeakServiceCheck.swift "$OUT/src/main.swift"
# Утилита целиком, кроме точки входа: модуль, служба, панель, экран и Kit.
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/main.swift" Tests/SpeakCheckStubs.swift \
  $(find Sources/Modules/Speak -name '*.swift' | LC_ALL=C sort) Sources/Apps/Speak/SpeakModule.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort)
SECRET="Тайна-$(/usr/bin/uuidgen)"
status=0
env HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" SPEAK_SECRET="$SECRET" "$OUT/check" >"$OUT/stdout.txt" 2>"$OUT/stderr.txt" || status=$?
cat "$OUT/stdout.txt"
/usr/bin/grep -v '^стенд отказал: панель озвучки$' "$OUT/stderr.txt" || true
[ "$status" = 0 ] || bad "проверка в процессе: код $status"
if /usr/bin/grep -qF "$SECRET" "$OUT/stdout.txt" "$OUT/stderr.txt"; then bad "текст службы попал в вывод"; else ok "текста службы нет в выводе"; fi
if /usr/bin/grep -rqF "$SECRET" "$OUT/home"; then bad "текст службы попал в файлы подставного дома"; else ok "текста службы нет в файлах подставного дома"; fi

if [ "$FAILED" != 0 ]; then echo "ПРОВАЛ: есть замечания выше"; exit 1; fi
echo "ВСЁ ОК"
