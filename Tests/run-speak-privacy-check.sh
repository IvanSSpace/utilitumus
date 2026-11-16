#!/bin/bash
# «Озвучка»: прочитанный текст не уходит из памяти чтения. По исходникам: нет сети, логов и записи на диск; общий буфер обмена
# и синтетическое ⌘C — только в SpeakCopyFallback.swift (запасной путь, когда программа не отдаёт выделенное через AX), и там
# же видно, что буфер берётся из шва Kit.pasteboard (в стенде — именованный тестовый) и возвращается, а ⌘C стенд отказывает.
# Во всём остальном модуле, в экране и у центра их нет.
# Вживую (подмены вместо звука, AX и сочетания): после чтения случайной строки её нет ни в состоянии для центра, ни в строке статуса,
# ни в контроллере, ни в тестовом suite настроек, ни в выводе проверки, ни в файлах подставного дома; то же для текста, взятого через ⌘C.
# Сборка со швом KIT_TEST_DEFAULTS, настоящие настройки не трогаются. Папка стенда: SPEAK_PRIVACY_DIR, иначе $TMPDIR/speak-privacy-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
T="${TMPDIR:-/tmp}"; OUT="${SPEAK_PRIVACY_DIR:-${T%/}/speak-privacy-check}"
export KIT_TEST_SUITE="local.utilitumus.test.kit.speak-privacy"
SOURCES=Sources/Modules/Speak
# Единственное место модуля с общим буфером обмена и синтетическим ⌘C.
COPY="$SOURCES/SpeakCopyFallback.swift"
# Всё остальное: ядро, служба, плеер, экран, утилита и модель центра.
OTHERS=()
while IFS= read -r f; do OTHERS+=("$f"); done < <(find "$SOURCES" Sources/Apps/Speak -name '*.swift' ! -path "$COPY" | LC_ALL=C sort)
OTHERS+=(Sources/App/Satellites/RemoteSpeakModel.swift Sources/App/Satellites/RemoteSpeakPage.swift)

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
has() { # что проверяем, grep -E образец, файл: строка обязана найтись
  local what="$1" pattern="$2" file="$3" status=0
  /usr/bin/grep -qE -- "$pattern" "$file" || status=$?
  case "$status" in
    0) ok "$what" ;;
    1) bad "$what: не нашлось" ;;
    *) bad "$what: grep завершился с кодом $status" ;;
  esac
}
times() { # что проверяем, grep -E образец, файл, сколько раз ровно
  local what="$1" pattern="$2" file="$3" want="$4" got
  got="$(/usr/bin/grep -cE -- "$pattern" "$file" || true)"
  [ "$got" = "$want" ] && ok "$what" || bad "$what: $got раз вместо $want"
}
line_of() { { /usr/bin/grep -nE -- "$1" "$2" || true; } | head -1 | cut -d: -f1; } # нет строки — пусто, не выход по set -e
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
[ -f "$COPY" ] && ok "есть $COPY" || bad "нет $COPY"
# Служба читает только буфер, который ей передала система, — поэтому запрещено не слово NSPasteboard, а общий буфер и запись.
none "вне $COPY общий буфер не читается и не пишется, ⌘C не жмётся" \
  'NSPasteboard\.general|NSPasteboard\(name|withUniqueName|Kit\.pasteboard|generalPasteboard|clearContents|writeObjects|setString\(|setData\(|kVK_ANSI_C\b|CGEvent|\.post\(tap' \
  "${OTHERS[@]}"

echo "== $COPY"
none "в нём нет журналов, печати и сети" \
  '\bprint\(|debugPrint\(|NSLog\(|fputs\(|os_log|Logger\(|PrivateLog|\bdump\(|URLSession|URLRequest|NWConnection|import Network|\bsocket\(' "$COPY"
none "в нём нет настроек: ни текст, ни что-либо ещё в Kit.defaults не пишется" 'Kit\.defaults|UserDefaults|AppStorage' "$COPY"
# Буфер берётся только из шва Kit.pasteboard: в стенде это именованный тестовый буфер, а не буфер автора.
none "в нём общий буфер не берётся мимо шва" 'NSPasteboard\.general|NSPasteboard\(name|withUniqueName|generalPasteboard' "$COPY"
times "буфер из шва — в одном месте" 'Kit\.pasteboard' "$COPY" 1
GENERAL="$(line_of 'static func general\(\) -> SpeakSystemPasteboard \{$' "$COPY")"
SEAM="$(line_of 'SpeakSystemPasteboard \{ Kit\.pasteboard \}$' "$COPY")"
if [ -n "$GENERAL" ] && [ "$SEAM" = "$((GENERAL + 1))" ]; then
  ok "шов Kit.pasteboard — тело general() (строка $SEAM)"
else
  bad "шов Kit.pasteboard не тело general(): general() ${GENERAL:-нет}, шов ${SEAM:-нет}"
fi
times "событие клавиши отправляется в одном месте" '\.post\(tap' "$COPY" 1
has "⌘C только после отказа стенда" 'if Kit\.standRefuses\("⌘C в переднюю программу"\) \{ return \}' "$COPY"
has "флаги ⌘C ровно ⌘" 'event\?\.flags = \.maskCommand$' "$COPY"
has "возвращённое помечается org.nspasteboard.TransientType" 'static let transientType = "org\.nspasteboard\.TransientType"' "$COPY"
has "TransientType ставится на возвращённый элемент" 'item\.setData\(Data\(\), forType: transient\)' "$COPY"
DEFER="$(line_of 'defer \{ pasteboard\.restore\(saved\) \}' "$COPY")"
READ="$(line_of 'pasteboard\.string\(\)' "$COPY")"
SEND="$(line_of 'key\.sendCopy\(\)' "$COPY")"
if [ -n "$DEFER" ] && [ -n "$READ" ] && [ -n "$SEND" ] && [ "$SEND" -lt "$DEFER" ] && [ "$DEFER" -lt "$READ" ]; then
  ok "возврат буфера стоит в defer после ⌘C и до чтения строки (строки $SEND, $DEFER, $READ)"
else
  bad "возврат буфера не в defer между ⌘C и чтением: ⌘C ${SEND:-нет}, defer ${DEFER:-нет}, чтение ${READ:-нет}"
fi
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
