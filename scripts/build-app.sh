#!/bin/bash
# Собирает отдельную утилиту из Sources/Apps/<Имя>, Sources/Modules/<Имя> и Sources/Kit.
#   scripts/build-app.sh awake Awake 1.0.0 build/apps
# Пятый аргумент только для стендов: --test-seam — настройки в своём suite, состояние центра подставное;
# --test-seam-real-id — то же, но с настоящими id и меткой launchd (Tests/run-hub-e2e.sh).
#
# Всё особое для утилиты лежит в Sources/Apps/<Имя>/manifest.json, сам скрипт при новом модуле не меняется.
# Все ключи необязательны, неизвестный ключ — ошибка. Пути от корня репозитория.
#   sources       файлы и папки (из папки берутся *.swift) сверх трёх папок выше
#   frameworks    имена сверх SwiftUI и AppKit
#   linkerFlags   уходят линковщику как есть, каждый через -Xlinker
#   entitlements  файл разрешений
#   helpers       вложенные помощники, подписываются раньше внешнего бандла:
#     kind        swift-tool, c-tool или swift-app
#     path        Contents/MacOS/<файл> или Contents/Helpers/<имя>.app (у swift-app)
#     identifier  должен совпасть с таблицей установщика (helpers_of в install.sh)
#     sources, frameworks, linkerFlags  как выше; среди sources можно и .a
#     includes    только c-tool: папки заголовков
#     prepare     скрипт, который подготовит sources до проверки путей
#     executable, info  только и обязательно у swift-app: имя бинарника и его Info.plist
set -euo pipefail
# Установщик отвергает архив с файлами, доступными на запись группе или всем.
umask 022

SWIFT_FLAGS=()
TEST_ID=""
if [ $# -eq 5 ] && [ "$5" = "--test-seam" ]; then
  SWIFT_FLAGS=(-D KIT_TEST_DEFAULTS)
  TEST_ID=1
elif [ $# -eq 5 ] && [ "$5" = "--test-seam-real-id" ]; then
  SWIFT_FLAGS=(-D KIT_TEST_DEFAULTS -D KIT_TEST_REAL_ID)
elif [ $# -ne 4 ]; then
  echo "Использование: scripts/build-app.sh <id> <Имя> <версия> <каталог-вывода> [--test-seam|--test-seam-real-id]" >&2
  exit 1
fi
ID="$1"
NAME="$2"
VERSION="$3"
OUT_DIR="$4"

fail() { echo "$1" >&2; exit 1; }
# Вне UTF-8: диапазон [a-z] не должен зависеть от языка системы.
matches() { local LC_ALL=C; [[ "$1" =~ $2 ]]; }

# Те же правила, что у SatelliteCatalog.isValidID и isValidVersion: иначе каталог не прочитается.
matches "$ID" '^[a-z0-9][a-z0-9.-]*$' || fail "Недопустимый id: ${ID}"
matches "$VERSION" '^[0-9]{1,18}(\.[0-9]{1,18})*$' || fail "Недопустимая версия: ${VERSION}"
# Имя становится именем модуля swiftc, путём и именем ассета: GitHub заменяет в нём пробелы и не-ASCII.
matches "$NAME" '^[A-Za-z][A-Za-z0-9]*$' || fail "Недопустимое имя: ${NAME}"

# Относительный путь — от папки вызывающего, а не от корня репозитория.
case "$OUT_DIR" in
  /*) ;;
  *) OUT_DIR="$PWD/$OUT_DIR" ;;
esac
cd "$(dirname "$0")/.."

MANIFEST="Sources/Apps/$NAME/manifest.json"
for path in "Sources/Apps/$NAME/Info.plist" "$MANIFEST" "Sources/Modules/$NAME" Sources/Kit; do
  [ -e "$path" ] || fail "Нет ${path}"
done

# Без метки выпуска центр и служба вентиляторов не примут утилиту (KitSigning.peerRequirement).
EPOCH="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -n "$EPOCH" ] || fail "Нет securityEpoch в Sources/Kit/KitSigning.swift"
require_epoch() {
  # xml1: raw не отличил бы строку от числа, а требование подписи ждёт строку.
  local found
  found="$(plutil -extract UtilitumusSecurityEpoch xml1 -o - "$1" 2>/dev/null)" || found=""
  [[ "$found" == *"<string>$EPOCH</string>"* ]] || fail "${1}: нет UtilitumusSecurityEpoch со значением ${EPOCH}"
}
require_epoch "Sources/Apps/$NAME/Info.plist"

# --- Манифест. Только чтение через plutil: файл не исполняется.
# plutil -lint понимает только plist, JSON читает лишь -p и -extract. Список или строка сверху прошли бы как пустой манифест.
PARSED="$(plutil -p "$MANIFEST" 2>/dev/null)" || fail "${MANIFEST}: не JSON-объект"
[[ "$PARSED" == "{"* ]] || fail "${MANIFEST}: не JSON-объект"

mf() { plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null; }
# Опечатка в ключе иначе молча дала бы сборку без разрешения или помощника.
only_keys() { # где, ключи построчно, разрешённые через пробел
  local key
  while IFS= read -r key; do
    [ -z "$key" ] || [[ " $3 " == *" $key "* ]] || fail "${MANIFEST}: неизвестный ключ «${key}» в ${1}"
  done <<<"$2"
}
# Элементы списка — в LIST. Нет ключа — пустой список.
read_list() {
  LIST=()
  local count i=0
  count="$(mf "$1")" || return 0
  matches "$count" '^[0-9]+$' || fail "${MANIFEST}: ${1} — не список"
  while [ "$i" -lt "$count" ]; do
    LIST+=("$(mf "$1.$i")")
    i=$((i + 1))
  done
}
# Внутри репозитория: манифест не должен тащить в подписанную сборку файлы снаружи.
check_path() {
  case "/$1/" in
    //* | */../* | /-*) fail "${MANIFEST}: недопустимый путь «${1}»" ;;
  esac
  [ -e "$1" ] || fail "${MANIFEST}: нет «${1}»"
}
# Списки фреймворков и флагов линковщика — в ARGS для swiftc или clang.
framework_args() {
  read_list "$1"
  ARGS=()
  local item
  for item in ${LIST[@]+"${LIST[@]}"}; do
    matches "$item" '^[A-Za-z][A-Za-z0-9]*$' || fail "${MANIFEST}: недопустимый фреймворк «${item}»"
    ARGS+=(-framework "$item")
  done
  read_list "$2"
  for item in ${LIST[@]+"${LIST[@]}"}; do
    ARGS+=(-Xlinker "$item")
  done
}
# Файлы как есть, из папки — *.swift. Результат в FILES.
source_files() {
  read_list "$1"
  FILES=()
  local item found
  for item in ${LIST[@]+"${LIST[@]}"}; do
    check_path "$item"
    if [ -d "$item" ]; then
      while IFS= read -r found; do
        FILES+=("$found")
      done < <(find "$item" -name '*.swift')
    else
      FILES+=("$item")
    fi
  done
}

TOP_KEYS="$(sed -n 's/^  "\([^"]*\)" =>.*/\1/p' <<<"$PARSED")"
only_keys "манифесте" "$TOP_KEYS" "sources frameworks linkerFlags entitlements helpers"

source_files sources
EXTRA_SOURCES=(${FILES[@]+"${FILES[@]}"})
framework_args frameworks linkerFlags
EXTRA_LINK=(${ARGS[@]+"${ARGS[@]}"})

ENTITLEMENT_ARGS=()
if ENTITLEMENTS="$(mf entitlements)"; then
  check_path "$ENTITLEMENTS"
  plutil -lint -s "$ENTITLEMENTS" >/dev/null || fail "${ENTITLEMENTS}: не plist"
  # Такие разрешения снимают защиту hardened runtime, ради которой подпись и проверяется.
  if matches "$(plutil -p "$ENTITLEMENTS")" '"com\.apple\.security\.(cs\.|get-task-allow)'; then
    fail "${ENTITLEMENTS}: разрешение снимает защиту hardened runtime"
  fi
  ENTITLEMENT_ARGS=(--entitlements "$ENTITLEMENTS")
fi

HELPER_COUNT="$(mf helpers || echo 0)"
matches "$HELPER_COUNT" '^[0-9]+$' || fail "${MANIFEST}: helpers — не список"

check_helper() {
  local h="helpers.$1" kind path identifier allowed="kind path identifier sources frameworks linkerFlags prepare" prepare
  kind="$(mf "$h.kind")" || fail "${MANIFEST}: ${h}: нет kind"
  path="$(mf "$h.path")" || fail "${MANIFEST}: ${h}: нет path"
  identifier="$(mf "$h.identifier")" || fail "${MANIFEST}: ${h}: нет identifier"
  matches "$identifier" '^local\.utilitumus\.[a-z0-9.-]+$' || fail "${MANIFEST}: недопустимый identifier «${identifier}»"
  case "$kind" in
    swift-tool) matches "$path" '^Contents/MacOS/[A-Za-z0-9.-]+$' || fail "${MANIFEST}: недопустимый path «${path}»" ;;
    c-tool)
      matches "$path" '^Contents/MacOS/[A-Za-z0-9.-]+$' || fail "${MANIFEST}: недопустимый path «${path}»"
      allowed+=" includes"
      ;;
    swift-app)
      matches "$path" '^Contents/Helpers/[A-Za-z0-9 .-]+\.app$' || fail "${MANIFEST}: недопустимый path «${path}»"
      allowed+=" executable info"
      local executable info
      executable="$(mf "$h.executable")" || fail "${MANIFEST}: ${h}: нет executable"
      matches "$executable" '^[A-Za-z][A-Za-z0-9]*$' || fail "${MANIFEST}: недопустимый executable «${executable}»"
      info="$(mf "$h.info")" || fail "${MANIFEST}: ${h}: нет info"
      check_path "$info"
      require_epoch "$info"
      [ "$(plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null)" = "$identifier" ] \
        || fail "${info}: CFBundleIdentifier не ${identifier}"
      [ "$(plutil -extract CFBundleExecutable raw -o - "$info" 2>/dev/null)" = "$executable" ] \
        || fail "${info}: CFBundleExecutable не ${executable}"
      ;;
    *) fail "${MANIFEST}: неизвестный kind «${kind}»" ;;
  esac
  [ "$path" != "Contents/MacOS/$NAME" ] || fail "${MANIFEST}: ${path} — это сама утилита"
  only_keys "$h" "$(mf "$h")" "$allowed"
  if prepare="$(mf "$h.prepare")"; then
    check_path "$prepare"
    "./$prepare"
  fi
  source_files "$h.sources"
  [ "${#FILES[@]}" -gt 0 ] || fail "${MANIFEST}: ${h}: нет sources"
  read_list "$h.includes"
  local item
  for item in ${LIST[@]+"${LIST[@]}"}; do check_path "$item"; done
  framework_args "$h.frameworks" "$h.linkerFlags"
  DECLARED="${DECLARED}${path}|${identifier}"$'\n'
}

DECLARED=""
i=0
while [ "$i" -lt "$HELPER_COUNT" ]; do
  check_helper "$i"
  i=$((i + 1))
done

# Проверяют сборку install.sh и KitSigning.helpers. Помощник, о котором они не знают, ушёл бы без проверки подписанта,
# а тот, которого нет в манифесте, все установщики отвергли бы как пропавший. Тестовый id установщику не известен.
if [ -z "$TEST_ID" ]; then
  EXPECTED="$(bash install.sh --helpers "$ID")"
  if [ "$(LC_ALL=C sort <<<"$DECLARED" | sed '/^$/d')" != "$(LC_ALL=C sort <<<"$EXPECTED" | sed '/^$/d')" ]; then
    fail "${MANIFEST}: помощники расходятся с установщиком. В манифесте: «${DECLARED}», в install.sh: «${EXPECTED}»"
  fi
fi

MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
TARGET="arm64-apple-macos$MIN_SYSTEM"

# Подпись как в build.sh: нет сертификата (CI) — ad-hoc. Выкладывать такое не даст release-app.sh.
SIGN_NAME="Utilitumus Signing"
KC_PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KC="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
if [ -f "$KC_PASSWORD_FILE" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$KC_PASSWORD_FILE")" "$KC"
fi
if [[ "$(security find-identity -p codesigning)" == *"\"$SIGN_NAME\""* ]]; then
  SIGN_ID="$SIGN_NAME"
else
  SIGN_ID="-"
  echo "⚠️  Сертификата «${SIGN_NAME}» нет — подпись ad-hoc." >&2
fi

# Только сам бандл: в папке вывода может лежать чужое.
APP="$OUT_DIR/$NAME.app"
rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Без -parse-as-library: точка входа утилиты — Sources/Apps/<Имя>/main.swift.
swiftc -O -target "$TARGET" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
  -o "$APP/Contents/MacOS/$NAME" \
  $(find "Sources/Apps/$NAME" "Sources/Modules/$NAME" Sources/Kit -name '*.swift') \
  ${EXTRA_SOURCES[@]+"${EXTRA_SOURCES[@]}"} \
  -framework SwiftUI -framework AppKit ${EXTRA_LINK[@]+"${EXTRA_LINK[@]}"}

# Бинарник и Info.plist на месте; подпись — последней, после неё помощник ставить нельзя.
build_helper() {
  local h="helpers.$1" kind path identifier target
  kind="$(mf "$h.kind")"
  path="$(mf "$h.path")"
  identifier="$(mf "$h.identifier")"
  source_files "$h.sources"
  framework_args "$h.frameworks" "$h.linkerFlags"
  target="$APP/$path"
  case "$kind" in
    swift-tool)
      mkdir -p "$(dirname "$target")"
      # -wmo убирает всё, что не вызывается: помощнику не нужно лишнее из общих файлов.
      swiftc -O -wmo -target "$TARGET" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -o "$target" "${FILES[@]}" ${ARGS[@]+"${ARGS[@]}"}
      ;;
    c-tool)
      mkdir -p "$(dirname "$target")"
      read_list "$h.includes"
      local includes=() item
      for item in ${LIST[@]+"${LIST[@]}"}; do includes+=(-I "$item"); done
      clang -O2 -Wall -target "$TARGET" ${includes[@]+"${includes[@]}"} -o "$target" "${FILES[@]}" ${ARGS[@]+"${ARGS[@]}"}
      ;;
    swift-app)
      local executable info
      executable="$(mf "$h.executable")"
      info="$target/Contents/Info.plist"
      mkdir -p "$target/Contents/MacOS" "$target/Contents/Resources"
      swiftc -O -wmo -target "$TARGET" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -o "$target/Contents/MacOS/$executable" "${FILES[@]}" ${ARGS[@]+"${ARGS[@]}"}
      cp "$(mf "$h.info")" "$info"
      plutil -replace CFBundleShortVersionString -string "$VERSION" "$info"
      plutil -replace CFBundleVersion -string "$VERSION" "$info"
      plutil -replace LSMinimumSystemVersion -string "$MIN_SYSTEM" "$info"
      if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$target/Contents/Resources/"; fi
      ;;
  esac
  # identifier явно: установщики сверяют именно его.
  codesign --force --options runtime --sign "$SIGN_ID" --identifier "$identifier" "$target"
}

i=0
while [ "$i" -lt "$HELPER_COUNT" ]; do
  build_helper "$i"
  i=$((i + 1))
done

INFO="$APP/Contents/Info.plist"
cp "Sources/Apps/$NAME/Info.plist" "$INFO"
# -replace, а не Set из PlistBuddy: добавит ключ, которого нет.
plutil -replace CFBundleIdentifier -string "local.utilitumus.app.$ID" "$INFO"
plutil -replace CFBundleExecutable -string "$NAME" "$INFO"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO"
plutil -replace CFBundleVersion -string "$VERSION" "$INFO"
plutil -replace LSMinimumSystemVersion -string "$MIN_SYSTEM" "$INFO"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  plutil -replace CFBundleIconFile -string AppIcon "$INFO"
fi

codesign --force --options runtime --sign "$SIGN_ID" --identifier "local.utilitumus.app.$ID" ${ENTITLEMENT_ARGS[@]+"${ENTITLEMENT_ARGS[@]}"} "$APP"

echo "Собрано: $APP"
