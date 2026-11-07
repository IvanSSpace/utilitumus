#!/bin/bash
# Набор модулей дев-сборки: разбор (какие файлы чьи), стенд центра за экраном (x: -10000) с тремя наборами и обычная сборка
# на тех же настройках, след в бинарнике для scripts/check-no-seam.sh. Подпись не нужна.
# Настройки: Kit.defaults в своём suite, домен бинарника снят на выходе. Настоящих утилит и настроек стенд не видит.
# Папка: DEV_SCOPE_CHECK_DIR, иначе $TMPDIR/dev-scope-check. Снимки остаются в png/. INCREMENTAL_OFF=1 — собрать целиком.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${DEV_SCOPE_CHECK_DIR:-${TMPDIR:-/tmp}/dev-scope-check}"
BIN="dev-scope-stand"
SUITE="local.utilitumus.test.kit.dev-scope"
MARK="local.utilitumus.dev-""scope"
fail() { echo "ПРОВАЛ: $1"; exit 1; }
ok() { echo "ok   $1"; }
same() { [ "$2" = "$3" ] && ok "$1" || fail "$1: ждал «$3», вышло «$2»"; }

. Tests/lib/incremental.sh
CACHE="${DEV_SCOPE_CACHE:-$OUT-cache}"
rm -rf "$OUT"
mkdir -p "$OUT/png" "$OUT/work" "$CACHE/src" "$CACHE/scoped" "$CACHE/plain"

echo "== разбор: чьи файлы менялись"
APPS=" awake:Awake sound:Sound mouse:Mouse mixer:Mixer stash:Stash load:Load voice:Voice keyboard:Keyboard clipboard:Clipboard fans:Fans browser:Browser bots:Bots"
. scripts/dev-scope.sh
classify() { dev_scope_classify <<<"$1"; echo "build=${PICK[*]:-} screens=$SCREENS kit=$KIT"; }
same "файл утилиты: пересборка" "$(classify Sources/Apps/Mixer/main.swift)" "build=mixer screens= kit="
same "файл модуля: пересборка" "$(classify Sources/Modules/Load/LoadStore.swift)" "build=load screens= kit="
same "экран в центре: виден без пересборки" "$(classify Sources/App/Satellites/RemoteMixerPage.swift)" "build= screens=mixer kit="
same "модель экрана: то же" "$(classify Sources/App/Satellites/RemoteVoiceModel.swift)" "build= screens=voice kit="
same "и модуль, и экран: один раз там и там" "$(classify "Sources/Modules/Mixer/A.swift
Sources/Modules/Mixer/B.swift
Sources/App/Satellites/RemoteMixerPage.swift
Sources/App/Satellites/RemoteMixerModel.swift")" "build=mixer screens=mixer kit="
same "общие файлы экранов ничьи" "$(classify "Sources/App/Satellites/RemoteModules.swift
Sources/App/Satellites/RemoteModulePage.swift
Sources/App/Satellites/RemoteModuleSurface.swift
Sources/App/Satellites/SatelliteRegistry.swift
Sources/App/Satellites/BrowserSatelliteHooks.swift
Sources/App/ModuleManager.swift")" "build= screens= kit="
same "Kit не расширяет набор" "$(classify "Sources/Kit/Link/LinkProtocol.swift
Sources/Kit/Kit.swift")" "build= screens= kit=1"
same "помощники и Shared принадлежат своей утилите" "$(classify "Sources/VoiceHelper/main.c
Sources/FanHelper/main.swift
Sources/LinkHelper/main.swift
Sources/Shared/SMC.swift")" "build=voice fans browser screens= kit="
same "посторонние файлы не считаются" "$(classify "README.md
Tests/run-sidebar-check.sh
Sources/Apps/Unknown/main.swift")" "build= screens= kit="
same "строка: повторы убраны" "$(dev_scope_line mixer load mixer)" "$MARK=mixer,load"
same "строка: пусто" "$(dev_scope_line)" "$MARK="
same "строка: все" "$(dev_scope_line '*')" "$MARK=*"
[[ "$(dev_scope_swift mixer)" == *"static let line = \"$MARK=mixer\""* ]] && ok "файл набора" || fail "файл набора"

echo "== шов только на этапе компиляции"
# Обычные сборки флаг не передают, а имя определено только в папке разработки.
USERS="$(grep -rlE 'KIT_DEV_SCOPE|KitDevScope' Sources | LC_ALL=C sort | tr '\n' ' ')"
same "флаг и имя только в ModuleScope и в окне центра" "$USERS" "Sources/App/ModuleScope.swift Sources/App/UtilitumusApp.swift "
same "имя в окне центра не используется" "$(grep -c KitDevScope Sources/App/UtilitumusApp.swift || true)" "0"
if grep -rn 'enum KitDevScope' Sources >/dev/null; then fail "KitDevScope определён в исходниках"; fi
ok "KitDevScope в исходниках не определён"
FLAG_SCRIPTS="$({ grep -lE -- '-D KIT_DEV_SCOPE' build.sh release.sh scripts/* 2>/dev/null || true; } | LC_ALL=C sort | tr '\n' ' ')"
same "флаг передаёт только scripts/dev.sh" "$FLAG_SCRIPTS" "scripts/dev.sh "
if sed -n '/#if KIT_DEV_SCOPE/,/#endif/p' Sources/App/ModuleScope.swift Sources/App/UtilitumusApp.swift | grep -E 'UserDefaults|ProcessInfo|CommandLine|Bundle\.|getenv' >/dev/null; then
  fail "набор читается не из компиляции"
fi
ok "в коде фильтра нет настроек, окружения, аргументов и plist"

# Подставной файл с тем же содержимым не должен менять время изменения: иначе его перекомпилируют зря.
put() { cmp -s "$1" "$2" 2>/dev/null || cp "$1" "$2"; }
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$OUT/UtilitumusApp.swift"
put "$OUT/UtilitumusApp.swift" "$CACHE/src/UtilitumusApp.swift"
put Tests/DevScopeCheck.swift "$CACHE/src/main.swift"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' \
  -not -path 'Sources/Apps/*' -not -name UtilitumusApp.swift -not -name KitDefaults.swift | LC_ALL=C sort)
FRAMEWORKS=(-framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit)

# Сборка с набором: тот самый файл, что пишет dev.sh, и тот самый флаг. Смена набора пересобирает один файл и линковку.
build_scoped() {
  dev_scope_swift "$@" > "$OUT/DevScope.swift"
  put "$OUT/DevScope.swift" "$CACHE/src/DevScope.swift"
  local files=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift" "$CACHE/src/DevScope.swift" Sources/Kit/KitDefaults.swift ${SOURCES[@]+"${SOURCES[@]}"})
  incremental_flags "$CACHE/scoped" "${files[@]}"
  swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -D KIT_TEST_DEFAULTS -D KIT_DEV_SCOPE -module-name DevScopeStand -o "$OUT/$BIN" \
    "${files[@]}" "${FRAMEWORKS[@]}"
}

defaults delete "$BIN" >/dev/null 2>&1 || true
defaults delete "$SUITE" >/dev/null 2>&1 || true
trap 'defaults delete "$BIN" >/dev/null 2>&1 || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
run_stand() { (cd "$OUT" && KIT_TEST_SUITE="$SUITE" "./$BIN" "$OUT/work" "$OUT/png" "$1" "$2"); }

# Первым открывается «Не спать»: его экран не касается железа. Остальные встроенные модули в окне не открываются.
echo "== набор awake,load"
build_scoped awake load
run_stand "" seed
# Без strings в конвейере: grep -q закрывает его раньше, и pipefail считал бы это провалом.
grep -aqF "$MARK=awake,load" "$OUT/$BIN" && ok "строка набора в бинарнике" || fail "в бинарнике нет строки набора"
run_stand "awake,load" scoped

echo "== пустой набор (--hub)"
build_scoped
run_stand "" scoped

echo "== все (--all)"
build_scoped '*'
run_stand "*" scoped

echo "== обычная сборка: без флага, без файла набора"
# Как build.sh, только без -O: Kit.defaults — домен бинарника вместо настоящего, как в run-store-catalog-check.sh.
sed 's/Bundle\.main\.bundleIdentifier == hubBundleID/true/' Sources/Kit/KitDefaults.swift > "$OUT/KitDefaults.swift"
grep -q 'UserDefaults = true' "$OUT/KitDefaults.swift" || fail "подмена Kit.defaults не сработала"
put "$OUT/KitDefaults.swift" "$CACHE/src/KitDefaults.swift"
PLAIN_FILES=("$CACHE/src/main.swift" "$CACHE/src/UtilitumusApp.swift" "$CACHE/src/KitDefaults.swift" ${SOURCES[@]+"${SOURCES[@]}"})
incremental_flags "$CACHE/plain" "${PLAIN_FILES[@]}"
swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -target "$TARGET" -module-name DevScopeStand -o "$OUT/$BIN" "${PLAIN_FILES[@]}" "${FRAMEWORKS[@]}"

# Домен Kit у этой сборки — домен бинарника: значки переезжают туда, остальное уже там.
for id in sound mixer awake; do defaults write "$BIN" "MenuBarIcon.$id" -bool true; done
run_stand "*" plain

echo "== check-no-seam"
if grep -qF "$MARK" "$OUT/$BIN"; then fail "метка набора в обычной сборке"; fi
ok "метки набора в обычной сборке нет"
if nm -a "$OUT/$BIN" 2>/dev/null | grep -q KitDevScope; then fail "символ KitDevScope в обычной сборке"; fi
ok "кода фильтра в обычной сборке нет (символа KitDevScope нет)"
mkdir -p "$OUT/clean/X.app/Contents/MacOS" "$OUT/dirty/X.app/Contents/MacOS"
cp "$OUT/$BIN" "$OUT/clean/X.app/Contents/MacOS/X"
scripts/check-no-seam.sh "$OUT/clean/X.app" || fail "check-no-seam отверг обычную сборку"
ok "check-no-seam: обычная сборка проходит"
printf 'xx%s=mixer\nxx' "$MARK" > "$OUT/dirty/X.app/Contents/MacOS/X"
if scripts/check-no-seam.sh "$OUT/dirty/X.app" 2>/dev/null; then fail "check-no-seam пропустил метку набора"; fi
ok "check-no-seam: метка набора — отказ"
echo "ВСЁ ОК"
