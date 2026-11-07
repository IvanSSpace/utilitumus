#!/bin/bash
# Роль утилиты и её включённость: чистая логика, UserDefaults только в тестовом suite.
# Самообновление: настоящий текст из SatelliteHost.swift на стенде с подставной сетью (Tests/SelfUpdateHostStand.swift).
# --mutations: собрать сломанные варианты самообновления и показать, что проверка на них краснеет.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${SATELLITE_ROLE_CHECK_DIR:-${TMPDIR:-/tmp}/satellite-role-check}"
mkdir -p "$OUT"
# Инкрементальная сборка: кэш вне папки проверки. Подробности в Tests/lib/incremental.sh.
. Tests/lib/incremental.sh
CACHE="$(incremental_cache satellite-role KIT_TEST_DEFAULTS)"
HOST_CACHE="$(incremental_cache satellite-self-update KIT_TEST_DEFAULTS)"
mkdir -p "$CACHE/src" "$HOST_CACHE/src"
HOST=Sources/Kit/SatelliteHost.swift
SUITE=local.utilitumus.test.selfupdate
KIT=(Sources/Kit/KitDefaults.swift Sources/Kit/KitSigning.swift Sources/Kit/SatelliteCatalog.swift \
  Sources/Kit/SatelliteRole.swift Sources/Kit/SatelliteSelfUpdate.swift Sources/Kit/KitArchive.swift)
while IFS= read -r f; do KIT+=("$f"); done < <(find Sources/Kit/Link -name '*.swift' | sort)
# Пустые файлы от тестовых suite: removePersistentDomain оставляет их в Preferences.
# Домен стенда сперва через defaults: иначе cfprefsd допишет файл заново уже после rm.
trap 'defaults delete "$SUITE" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/local.utilitumus.test.role.plist" "$HOME/Library/Preferences/$SUITE.plist"' EXIT

copy_if_changed() { cmp -s "$1" "$2" || cp "$1" "$2"; }

# Вход в самообновление один, другой путь к каталогу обошёл бы то, что выполняет стенд.
same_count() { if [ "$2" != "$3" ]; then echo "ПРОВАЛ: $1: нашлось $2, ждали $3"; exit 1; fi; echo "ok   $1"; }
same_count "SatelliteHost: каталог читает одно место" "$(/usr/bin/grep -c 'URLSession' "$HOST")" 1
same_count "SatelliteHost: checkForUpdate зовут только таймер и запуск" "$(/usr/bin/grep -c 'checkForUpdate()' "$HOST")" 3
same_count "SatelliteHost: запуск проверок один" "$(/usr/bin/grep -c 'scheduleUpdateChecks()' "$HOST")" 2

# build_kit <exe> <кэш> <имя модуля> <главный файл> [ещё файл...]; замены файлов Kit в $REPLACE: путь=путь.
REPLACE=()
build_kit() {
  local exe="$1" cache="$2" name="$3"; shift 3
  local files=("$@" "${KIT[@]}") pair i
  for pair in ${REPLACE[@]+"${REPLACE[@]}"}; do
    for i in "${!files[@]}"; do if [ "${files[$i]}" = "${pair%%=*}" ]; then files[i]="${pair##*=}"; fi; done
  done
  incremental_flags "$cache" "${files[@]}"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name "$name" -o "$exe" "${files[@]}"
}

# Настоящий текст обоих методов, `private` снят: вызывает их стенд из другого файла. Нет метода — стенд не соберётся.
host_text() { # файл хоста, куда писать
  { echo 'import Foundation'
    echo 'extension HostStand {'
    sed -n '/private func scheduleUpdateChecks() {/,/private func restart() {/p' "$1" | sed '$d' | sed 's/private func /func /'
    echo '}'
  } > "$2.new"
  copy_if_changed "$2.new" "$2"
}

build_role() { # выход кэш
  mkdir -p "$2/src"
  copy_if_changed Tests/SatelliteRoleCheck.swift "$2/src/main.swift"
  build_kit "$1" "$2" SatelliteRoleCheck "$2/src/main.swift"
}

build_host() { # выход кэш файл-хоста
  mkdir -p "$2/src"
  copy_if_changed Tests/SelfUpdateHostStand.swift "$2/src/main.swift"
  host_text "$3" "$2/src/HostText.swift"
  build_kit "$1" "$2" SelfUpdateHostStand "$2/src/main.swift" "$2/src/HostText.swift"
}

if [ "${1:-}" != --mutations ]; then
  build_role "$OUT/check" "$CACHE"
  "$OUT/check"
  build_host "$OUT/host-stand" "$HOST_CACHE" "$HOST"
  KIT_TEST_SUITE="$SUITE" "$OUT/host-stand"
  exit 0
fi

# mutate <имя> <файл> <было> <стало> <какая проверка должна покраснеть>: поломка в копии, настоящие исходники не меняются.
MUT="$OUT-mut"
mutate() {
  local name="$1" file="$2" old="$3" new="$4" expect="$5"
  local copy="$MUT/copy/$(basename "$file")" status=0
  mkdir -p "$MUT/copy"
  /usr/bin/python3 -I - "$file" "$copy" "$old" "$new" <<'PY'
import sys
source, target, old, new = sys.argv[1:]
text = open(source, encoding="utf-8").read()
assert old in text, "нет места для поломки: " + old
open(target, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  local host="$HOST"
  REPLACE=()
  if [ "$file" = "$HOST" ]; then host="$copy"; else REPLACE=("$file=$copy"); fi
  build_role "$MUT/role" "$MUT/role-cache" 2>"$MUT/build.log" && build_host "$MUT/stand" "$MUT/stand-cache" "$host" 2>>"$MUT/build.log" \
    || { echo "ПРОВАЛ: поломка «${name}» не собралась, $MUT/build.log"; /usr/bin/tail -5 "$MUT/build.log"; exit 1; }
  : > "$MUT/run.log"
  "$MUT/role" >> "$MUT/run.log" 2>&1 || status=$?
  KIT_TEST_SUITE="$SUITE" "$MUT/stand" >> "$MUT/run.log" 2>&1 || status=$?
  if [ "$status" = 0 ]; then echo "ПРОВАЛ: поломка «${name}» не замечена"; exit 1; fi
  /usr/bin/grep -F "FAIL" "$MUT/run.log" | /usr/bin/grep -F "$expect" | head -3 > "$MUT/hits" || true
  if [ ! -s "$MUT/hits" ]; then echo "ПРОВАЛ: поломка «${name}»: ждали красную «${expect}»"; /usr/bin/grep -F FAIL "$MUT/run.log" | head -5; exit 1; fi
  echo "ok   поломка «${name}» краснеет:"; sed 's/^/       /' "$MUT/hits"
}

UPDATE=Sources/Kit/SatelliteSelfUpdate.swift
CATALOG=Sources/Kit/SatelliteCatalog.swift
mutate "без запрета совсем" "$UPDATE" \
  'static func mayUpdateItself(id: String) -> Bool { !SatelliteCatalog.personOnly.contains(id) }' \
  'static func mayUpdateItself(id: String) -> Bool { true }' \
  "fans: новая версия не скачивается"
mutate "каталог читается зря" "$HOST" \
  'guard SatelliteSelfUpdate.mayUpdateItself(id: id) else { return }' \
  '' \
  "fans: каталог не читается"
mutate "без запрета в newer" "$UPDATE" \
  'guard mayUpdateItself(id: id) else { return nil }' \
  '' \
  "обновление: fans"
mutate "отметка каталога не смотрится" "$UPDATE" \
  '$0.id == id && !$0.manualUpdate && ' \
  '$0.id == id && ' \
  "отметка"
mutate "в списке нет Вентиляторов" "$CATALOG" \
  'static let personOnly: Set<String> = ["fans", "clipboard"]' \
  'static let personOnly: Set<String> = ["clipboard"]' \
  "fans"
mutate "в списке нет Буфера" "$CATALOG" \
  'static let personOnly: Set<String> = ["fans", "clipboard"]' \
  'static let personOnly: Set<String> = ["fans"]' \
  "clipboard"
mutate "запрет на всех" "$UPDATE" \
  'static func mayUpdateItself(id: String) -> Bool { !SatelliteCatalog.personOnly.contains(id) }' \
  'static func mayUpdateItself(id: String) -> Bool { false }' \
  "другие утилиты"
echo "ВСЕ ПОЛОМКИ ЗАМЕЧЕНЫ"
