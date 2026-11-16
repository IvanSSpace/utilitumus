#!/bin/bash
# «Озвучка»: прочитанный текст не уходит из памяти чтения. По исходникам: нет сети, логов, записи на диск, буфера обмена и ⌘C.
# Вживую (подмены вместо звука, AX и сочетания): после чтения случайной строки её нет ни в состоянии для центра, ни в строке статуса,
# ни в контроллере, ни в тестовом suite настроек, ни в выводе проверки, ни в файлах подставного дома.
# Сборка со швом KIT_TEST_DEFAULTS, настоящие настройки не трогаются. Папка стенда: SPEAK_PRIVACY_DIR, иначе $TMPDIR/speak-privacy-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${SPEAK_PRIVACY_DIR:-${T%/}/speak-privacy-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.speak-privacy"
SOURCES=Sources/Modules/Speak

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
absent() { # что проверяем, строка, файлы или папки...
  local what="$1" needle="$2" status=0
  shift 2
  /usr/bin/grep -rqF -- "$needle" "$@" || status=$?
  case "$status" in
    0) bad "$what: текст нашёлся" ;;
    1) ok "$what" ;;
    *) bad "$what: grep завершился с кодом $status" ;;
  esac
}

echo "== Исходники $SOURCES"
none "нет сети" 'URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWBrowser|CFStream|CFSocket|import Network|\bsocket\(' "$SOURCES"
none "нет логов и печати" '\bprint\(|debugPrint\(|NSLog\(|fputs\(|os_log|Logger\(|PrivateLog|\bdump\(' "$SOURCES"
none "на диск ничего не пишется" 'FileManager|FileHandle|createFile|write\(to:|\.write\(|writeToFile|\.archive' "$SOURCES"
none "буфер обмена не читается, ⌘C не жмётся" 'NSPasteboard\.general|Kit\.pasteboard|generalPasteboard|kVK_ANSI_C\b|CGEvent\(keyboardEventSource' "$SOURCES"
# В настройки — только ключи SpeakKeys, и ни одна запись не берёт текст или сессию.
none "в Kit.defaults только ключи SpeakKeys" 'Kit\.defaults\.set\(.*forKey: [^S]' "$SOURCES"
none "в Kit.defaults не пишется текст" 'Kit\.defaults\.set\([^)]*(text|session|rest|raw)' "$SOURCES"

echo "== Вживую"
SECRET="Тайна-$(/usr/bin/uuidgen)"
TAIL="${SECRET#Тайна-}"
mkdir -p "$OUT/src" "$OUT/home"
cp Tests/SpeakPrivacyCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -D KIT_TEST_DEFAULTS -o "$OUT/check" "$OUT/src/main.swift" Tests/SpeakCheckStubs.swift \
  "$SOURCES"/*.swift "$SOURCES"/UI/*.swift \
  $(find Sources/Kit -name '*.swift' | LC_ALL=C sort)
# Подставной дом: если код что-то запишет в дом, оно окажется здесь и найдётся ниже.
status=0
env HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" SPEAK_SECRET="$SECRET" "$OUT/check" >"$OUT/stdout.txt" 2>"$OUT/stderr.txt" || status=$?
cat "$OUT/stdout.txt"
cat "$OUT/stderr.txt"
[ "$status" = 0 ] || bad "проверка в процессе: код $status"

defaults export "$KIT_TEST_SUITE" - >"$OUT/prefs.plist" 2>/dev/null || true
if /usr/bin/grep -qF 'Speak.Speed' "$OUT/prefs.plist"; then ok "тестовый suite прочитан: скорость в нём есть"; else bad "тестовый suite пуст: искали не там"; fi
for needle in "$SECRET" "$TAIL"; do
  absent "вывод проверки без текста" "$needle" "$OUT/stdout.txt" "$OUT/stderr.txt"
  absent "тестовый suite настроек без текста" "$needle" "$OUT/prefs.plist"
  absent "файлы подставного дома без текста" "$needle" "$OUT/home"
done

if [ "$FAILED" != 0 ]; then echo "ПРОВАЛ: есть замечания выше"; exit 1; fi
echo "ВСЁ ОК"
