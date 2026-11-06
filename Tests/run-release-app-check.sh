#!/bin/bash
# Сборка и выпуск утилит. Ничего не выкладывает: release-app.sh запускается только с --dry-run, install.sh ставит
# только в папку стенда; подставные репозиторий со своим origin, gh и launchctl; настоящий каталог не трогается.
# Sources/Apps/Awake — заготовка стенда, настоящая появится в следующей задаче.
# Папка стенда: RELEASE_APP_CHECK_DIR, иначе $TMPDIR/release-app-check. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

OUT="${RELEASE_APP_CHECK_DIR:-${TMPDIR:-/tmp}/release-app-check}"
FX="$OUT/repo"
ORIGIN="$OUT/origin.git"
FAKE="$OUT/fake"
NOCERT="$OUT/nocert"
GH_LOG="$OUT/gh.log"
CURL_LOG="$OUT/curl.log"
LAUNCHCTL_LOG="$OUT/launchctl.log"
SIGN_NAME="Utilitumus Signing"
LEAF="$(grep -oE '"[0-9a-f]{40}"' Sources/Kit/KitSigning.swift | head -1 | tr -d '"')"
RAW_CATALOG="$(grep -oE 'https://raw[^"]+catalog\.json' Sources/Kit/SatelliteCatalog.swift)"
SCRIPTS=(build.sh install.sh scripts/release.sh scripts/build-app.sh scripts/build-pilot.sh scripts/release-app.sh Tests/run-release-app-check.sh Tests/run-pilot-build-check.sh)

fails=0
pass() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; fails=$((fails + 1)); }
check() {
  local what="$1"
  shift
  if "$@"; then pass "$what"; else bad "$what"; fi
}
same() { # описание, что есть, что ждали
  if [ "$2" = "$3" ]; then pass "$1"; else bad "$1: «${2}», ждали «${3}»"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
refused() { # описание, шаблон в выводе, команда
  local what="$1" pattern="$2" output status=0
  shift 2
  output="$("$@" 2>&1 </dev/null)" || status=$?
  if [ "$status" -eq 0 ]; then
    bad "${what}: команда прошла"
    echo "$output"
  elif ! grep -qF -- "$pattern" <<<"$output"; then
    bad "${what}: нет «${pattern}» в выводе"
    echo "$output"
  else
    pass "$what"
  fi
}
finish() {
  if [ "$fails" -ne 0 ]; then
    echo "Провалов: $fails"
    exit 1
  fi
}

rm -rf "$OUT"
mkdir -p "$OUT/tmp" "$FAKE" "$NOCERT" "$OUT/home"
: > "$GH_LOG"; : > "$CURL_LOG"; : > "$LAUNCHCTL_LOG"

echo "== скрипты без запуска"
for script in "${SCRIPTS[@]}"; do
  if [ ! -f "$script" ]; then
    bad "нет $script"
    continue
  fi
  check "bash 3.2 -n $script" /bin/bash -n "$script"
  check "bash -n $script" bash -n "$script"
  # bash 5 в UTF-8 считает кириллицу и кавычки «» частью имени: рядом с ними только ${VAR}.
  found="$(LC_ALL=C grep -nE "\\\$[A-Za-z0-9_]+$(printf '[\200-\377]')" "$script" || true)"
  same "$script: нет \$VAR вплотную к не-ASCII" "$found" ""
done
check "release.sh передаёт --latest=true" has scripts/release.sh '--latest=true'
# Иначе утилита сочла бы центр старым, а центр не показал бы в каталоге ничего с minHub 0.6.0.
HUB_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Info.plist)"
ARBITER="$(sed -n 's/.*arbiterVersion = "\(.*\)".*/\1/p' Sources/Kit/SatelliteRole.swift)"
same "версия центра не младше версии арбитра ${ARBITER}" "$(printf '%s\n%s\n' "$ARBITER" "$HUB_VERSION" | sort -V | head -1)" "$ARBITER"
check "сборка центра не берёт Sources/Apps" has build.sh "-not -path 'Sources/Apps/*'"
check "install.sh: хэш тот же, что в KitSigning" has install.sh "$LEAF"
check "install.sh: адрес каталога тот же, что в SatelliteCatalog" has install.sh "$RAW_CATALOG"
if [ ! -f scripts/build-app.sh ] || [ ! -f scripts/release-app.sh ]; then
  finish
fi
check "release-app.sh: хэш тот же, что в KitSigning" has scripts/release-app.sh "$LEAF"

# Подпись как в build.sh.
KC_PASSWORD_FILE="$HOME/.config/utilitumus/keychain-password"
KC="$HOME/Library/Keychains/utilitumus-signing.keychain-db"
if [ -f "$KC_PASSWORD_FILE" ] && [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$KC_PASSWORD_FILE")" "$KC"
fi
IDENTITIES="$(security find-identity -p codesigning)"
if [[ "$IDENTITIES" != *"\"$SIGN_NAME\""* ]]; then
  echo "ПРОВАЛ: нет сертификата «${SIGN_NAME}»"
  exit 1
fi

# Подставные программы. Настоящие launchctl и gh стенду недоступны: подмена раньше по PATH.
cat > "$FAKE/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$GH_LOG"
case "\$1 \$2" in
  "auth token") exit 1 ;;
  "release view") [ -n "\${GH_RELEASE_EXISTS:-}" ] ;;
esac
EOF
cat > "$FAKE/launchctl" <<EOF
#!/bin/bash
echo "launchctl \$*" >> "$LAUNCHCTL_LOG"
# Первые REFUSE_BOOTSTRAP вызовов bootstrap отказывают, счётчик в файле.
if [ "\$1" = bootstrap ] && [ -n "\${REFUSE_BOOTSTRAP:-}" ]; then
  count="\$(cat "\$REFUSE_COUNT" 2>/dev/null || echo 0)"
  echo "\$((count + 1))" > "\$REFUSE_COUNT"
  [ "\$count" -ge "\$REFUSE_BOOTSTRAP" ]
fi
EOF
# Отдаёт CURL_SERVES вместо скачивания и записывает адрес.
cat > "$OUT/curl-stub" <<EOF
#!/bin/bash
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) target="\$2"; shift 2 ;;
    --url) url="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
echo "\$url" >> "$CURL_LOG"
cp "\$CURL_SERVES" "\$target"
EOF
# Как на машине без сертификата: find-identity пуст, в CI так же.
cat > "$NOCERT/security" <<'EOF'
#!/bin/bash
[ "$1" = find-identity ] && echo "     0 valid identities found"
exit 0
EOF
chmod +x "$FAKE/gh" "$FAKE/launchctl" "$OUT/curl-stub" "$NOCERT/security"

# Подставной репозиторий с настоящим Kit и заготовкой утилиты: заготовка читает каталог настоящим SatelliteCatalog.
G=(/usr/bin/git -C "$FX" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.invalid)
mkdir -p "$FX/scripts" "$FX/Sources/Apps/Awake" "$FX/Sources/Modules/Awake" "$FX/Catalog" "$FX/Resources"
cp scripts/build-app.sh scripts/release-app.sh "$FX/scripts/"
cp install.sh "$FX/install.sh"
echo '{}' > "$FX/Sources/Apps/Awake/manifest.json"
cp -R Sources/Kit "$FX/Sources/Kit"
cp Info.plist "$FX/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$FX/Resources/"
cat > "$FX/Sources/Apps/Awake/main.swift" <<'EOF'
import Foundation

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(summary(try SatelliteCatalog.decode(data)))
EOF
cat > "$FX/Sources/Modules/Awake/Summary.swift" <<'EOF'
func summary(_ catalog: Catalog) -> String {
    catalog.apps.map { "\($0.id) \($0.version) \($0.minHub) \($0.sizeMB)" }.joined(separator: ", ")
}
EOF
cat > "$FX/Sources/Apps/Awake/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Awake</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>LSUIElement</key><true/>
<key>UtilitumusSecurityEpoch</key><string>1</string>
</dict></plist>
EOF
cat > "$FX/Catalog/catalog.json" <<'EOF'
{"schema":1,"apps":[
{"id":"other","version":"3.0.0","minHub":"0.6.0","url":"https://example.com/Other.zip","sha256":"aa","sizeMB":1},
{"id":"awake","version":"1.0.0","minHub":"0.7.0","url":"https://example.com/Old.zip","sha256":"bb","sizeMB":9}
]}
EOF
# Как после клона с umask 002: umask сборки должен это убрать.
chmod g+w "$FX/Sources/Apps/Awake/Info.plist"
[ -f "$FX/Resources/AppIcon.icns" ] && chmod g+w "$FX/Resources/AppIcon.icns"
/usr/bin/git init -q -b main "$FX"
"${G[@]}" add -A
"${G[@]}" commit -q -m fixture
/usr/bin/git init -q --bare -b main "$ORIGIN"
"${G[@]}" remote add origin "$ORIGIN"
"${G[@]}" push -q origin main
"${G[@]}" fetch -q origin

state() {
  "${G[@]}" rev-parse HEAD
  "${G[@]}" tag
  "${G[@]}" status --porcelain
  /usr/bin/git -C "$ORIGIN" rev-parse main
  /usr/bin/git -C "$ORIGIN" tag
  shasum -a 256 "$FX/Catalog/catalog.json"
}
REAL_CATALOG_BEFORE="$(shasum -a 256 "$ROOT/Catalog/catalog.json")"
REAL_STATUS_BEFORE="$(/usr/bin/git -C "$ROOT" status --porcelain -- Catalog)"

echo "== build-app.sh"
BA="$FX/scripts/build-app.sh"
for shell_bin in /bin/bash "$(command -v bash)"; do
  # Перевод строки в конце: grep и $ в других языках такое пропускают.
  refused "$shell_bin: id с переводом строки" "id" "$shell_bin" "$BA" $'awake\n' Awake 1.2.3 "$OUT/x"
  refused "$shell_bin: id с заглавной" "id" "$shell_bin" "$BA" Awake Awake 1.2.3 "$OUT/x"
  refused "$shell_bin: id с кириллицей" "id" "$shell_bin" "$BA" "бодрость" Awake 1.2.3 "$OUT/x"
done
refused "id со слэшем" "id" "$BA" a/b Awake 1.2.3 "$OUT/x"
refused "id c .. в начале" "id" "$BA" ../x Awake 1.2.3 "$OUT/x"
refused "имя вне папки" "имя" "$BA" awake ../Evil 1.2.3 "$OUT/x"
refused "имя с пробелом" "имя" "$BA" awake "My App" 1.2.3 "$OUT/x"
refused "версия с мусором" "верси" "$BA" awake Awake 1.2.x "$OUT/x"
refused "версия, которая не влезает в число" "верси" "$BA" awake Awake 1.9999999999999999999 "$OUT/x"
refused "нет исходников" "Sources/Apps/Nope" "$BA" nope Nope 1.2.3 "$OUT/x"
refused "мало аргументов" "build-app.sh" "$BA" awake Awake
mv "$FX/Sources/Apps/Awake/manifest.json" "$OUT/manifest.keep"
refused "нет манифеста" "manifest.json" "$BA" awake Awake 1.2.3 "$OUT/x"
mv "$OUT/manifest.keep" "$FX/Sources/Apps/Awake/manifest.json"
check "после отказов папка вывода не создана" test ! -e "$OUT/x"

# Относительный путь — от вызывающего, чужое в папке вывода цело, umask вызывающего не важен.
mkdir -p "$OUT/built"
echo keep > "$OUT/built/neighbour"
(cd "$OUT" && umask 000 && "$BA" awake Awake 1.2.3 built) > "$OUT/build-app.log" 2>&1 || { cat "$OUT/build-app.log"; bad "build-app.sh не собрал"; finish; }
APP="$OUT/built/Awake.app"
check "собран бандл" test -x "$APP/Contents/MacOS/Awake"
check "чужой файл в папке вывода цел" test -f "$OUT/built/neighbour"
same "CFBundleIdentifier" "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" local.utilitumus.app.awake
same "CFBundleShortVersionString" "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" 1.2.3
same "CFBundleExecutable" "$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist")" Awake
same "LSUIElement из Info.plist утилиты" "$(plutil -extract LSUIElement raw -o - "$APP/Contents/Info.plist")" true
same "LSMinimumSystemVersion как у центра" \
  "$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist")" \
  "$(plutil -extract LSMinimumSystemVersion raw -o - Info.plist)"
same "minos бинарника" "$(vtool -show-build "$APP/Contents/MacOS/Awake" | awk '/minos/{print $2}')" \
  "$(plutil -extract LSMinimumSystemVersion raw -o - Info.plist)"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
check "hardened runtime" grep -qE 'flags=.*runtime' <<<"$SIGNATURE"
check "подпись: точный identifier и хэш" codesign --verify --deep --strict \
  -R="identifier \"local.utilitumus.app.awake\" and certificate leaf = H\"$LEAF\"" "$APP"
same "нет записи для группы и всех" "$(find "$APP" ! -type l \( -perm -020 -o -perm -002 \))" ""
same "Kit, модуль и Apps собраны вместе" \
  "$("$APP/Contents/MacOS/Awake" "$FX/Catalog/catalog.json")" "other 3.0.0 0.6.0 1, awake 1.0.0 0.7.0 9"

(PATH="$NOCERT:$PATH" "$BA" awake Awake 1.2.3 "$OUT/adhoc") > "$OUT/adhoc.log" 2>&1 || { cat "$OUT/adhoc.log"; bad "без сертификата build-app.sh не собрал"; }
check "без сертификата — ad-hoc с предупреждением" has "$OUT/adhoc.log" "ad-hoc"
check "без сертификата — подпись ad-hoc" grep -q 'Signature=adhoc' <<<"$(codesign -dvv "$OUT/adhoc/Awake.app" 2>&1)"

echo "== release-app.sh --dry-run"
RA="$FX/scripts/release-app.sh"
dry() { env PATH="$FAKE:$PATH" TMPDIR="$OUT/tmp" "$RA" "$@"; }

BEFORE="$(state)"
PLAN="$OUT/plan.txt"
dry awake Awake 1.2.3 --dry-run > "$PLAN" 2>&1 || { cat "$PLAN"; bad "--dry-run упал"; finish; }
cat "$PLAN"
same "--dry-run не изменил репозиторий, теги и origin" "$(state)" "$BEFORE"
check "gh не выкладывал" lacks "$GH_LOG" "release create"
check "gh не догружал" lacks "$GH_LOG" "release upload"
check "в плане --latest=false" has "$PLAN" "--latest=false"
check "в плане тег" has "$PLAN" "awake-v1.2.3"
check "в плане ассет" has "$PLAN" "Awake.zip"
check "в плане репозиторий" has "$PLAN" "-R IvanSSpace/utilitumus"
first() { grep -nF -- "$1" "$PLAN" | head -1 | cut -d: -f1; }
CREATE="$(first 'gh release create')"
COMMIT="$(first 'git commit')"
PUSH_MAIN="$(first 'git push -q origin HEAD:main')"
if [ -n "$CREATE" ] && [ -n "$COMMIT" ] && [ -n "$PUSH_MAIN" ] && [ "$CREATE" -lt "$COMMIT" ] && [ "$COMMIT" -lt "$PUSH_MAIN" ]; then
  pass "порядок: выкладка, коммит каталога, push"
else
  bad "порядок: выкладка ${CREATE:-нет}, коммит ${COMMIT:-нет}, push ${PUSH_MAIN:-нет}"
fi

NEW_CATALOG="$(sed -n 's/^Каталог: //p' "$PLAN")"
ZIP="$(sed -n 's/^Архив: //p' "$PLAN")"
if [ ! -f "$NEW_CATALOG" ] || [ ! -f "$ZIP" ]; then
  bad "в плане нет путей к каталогу и архиву"
  finish
fi
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
field() { plutil -extract "$1" raw -o - "$NEW_CATALOG"; }
same "каталог: version" "$(field apps.1.version)" 1.2.3
same "каталог: url" "$(field apps.1.url)" "https://github.com/IvanSSpace/utilitumus/releases/download/awake-v1.2.3/Awake.zip"
same "каталог: sha256 архива" "$(field apps.1.sha256)" "$SHA"
same "каталог: minHub записи сохранён" "$(field apps.1.minHub)" 0.7.0
same "каталог: другая запись цела" "$(field apps.0.version) $(field apps.0.sha256)" "3.0.0 aa"
same "каталог: записей столько же" "$(field apps)" 2
same "каталог: schema" "$(field schema)" 1
SIZE_MB="$(field apps.1.sizeMB)"
if [ "$SIZE_MB" -ge 1 ] 2>/dev/null; then pass "каталог: sizeMB $SIZE_MB"; else bad "каталог: sizeMB «${SIZE_MB}»"; fi
same "каталог читается настоящим SatelliteCatalog.decode" \
  "$("$APP/Contents/MacOS/Awake" "$NEW_CATALOG")" "other 3.0.0 0.6.0 1, awake 1.2.3 0.7.0 $SIZE_MB"
same "имя файла в архиве" "$(unzip -Z1 "$ZIP" | cut -d/ -f1 | sort -u)" Awake.app

# Первый выпуск: без minHub и sizeMB каталог не прочитает ни один центр.
FRESH_PLAN="$OUT/fresh.txt"
dry fresh Awake 2.0.0 --dry-run > "$FRESH_PLAN" 2>&1 || { cat "$FRESH_PLAN"; bad "--dry-run нового id упал"; finish; }
FRESH_CATALOG="$(sed -n 's/^Каталог: //p' "$FRESH_PLAN")"
FRESH_ZIP="$(sed -n 's/^Архив: //p' "$FRESH_PLAN")"
FRESH_SIZE="$(plutil -extract apps.2.sizeMB raw -o - "$FRESH_CATALOG")"
same "новый id дописан со всеми полями" \
  "$("$APP/Contents/MacOS/Awake" "$FRESH_CATALOG")" "other 3.0.0 0.6.0 1, awake 1.0.0 0.7.0 9, fresh 2.0.0 0.6.0 $FRESH_SIZE"
same "новый id: sha256" "$(plutil -extract apps.2.sha256 raw -o - "$FRESH_CATALOG")" "$(shasum -a 256 "$FRESH_ZIP" | cut -d' ' -f1)"
same "новый id: url" "$(plutil -extract apps.2.url raw -o - "$FRESH_CATALOG")" "https://github.com/IvanSSpace/utilitumus/releases/download/fresh-v2.0.0/Awake.zip"

: > "$GH_LOG"
BEFORE="$(state)"
refused "опечатка в --dry-run не выкладывает" "--dryrun" dry awake Awake 1.2.3 --dryrun
refused "--dry-run первым аргументом" "аргумент" dry --dry-run awake Awake 1.2.3
refused "лишний аргумент" "release-app.sh" dry awake Awake 1.2.3 --dry-run extra
refused "мало аргументов" "release-app.sh" dry awake Awake
refused "id с переводом строки" "id" dry $'awake\n' Awake 1.2.3 --dry-run
refused "версия с мусором" "верси" dry awake Awake 1.2.x --dry-run
refused "выпуск уже есть" "уже есть" env GH_RELEASE_EXISTS=1 PATH="$FAKE:$PATH" TMPDIR="$OUT/tmp" "$RA" awake Awake 1.2.3 --dry-run
refused "неподписанную сборку не выкладывает" "не подписана" env PATH="$NOCERT:$FAKE:$PATH" TMPDIR="$OUT/tmp" "$RA" awake Awake 1.2.3 --dry-run
same "отказы не изменили репозиторий" "$(state)" "$BEFORE"

echo untracked > "$FX/untracked"
refused "новый файл в дереве — отказ" "незакоммиченные" dry awake Awake 1.2.3 --dry-run
rm "$FX/untracked"
echo changed >> "$FX/Catalog/catalog.json"
refused "изменённый файл в дереве — отказ" "незакоммиченные" dry awake Awake 1.2.3 --dry-run
"${G[@]}" checkout -q -- Catalog/catalog.json
"${G[@]}" commit -q --allow-empty -m ahead
refused "HEAD не совпадает с origin/main — отказ" "не совпадает" dry awake Awake 1.2.3 --dry-run
"${G[@]}" reset -q --hard origin/main
check "gh не выкладывал и при отказах" lacks "$GH_LOG" "release create"

same "настоящий каталог не изменён" "$(shasum -a 256 "$ROOT/Catalog/catalog.json")" "$REAL_CATALOG_BEFORE"
same "настоящий каталог: статус git" "$(/usr/bin/git -C "$ROOT" status --porcelain -- Catalog)" "$REAL_STATUS_BEFORE"

echo "== install.sh <id> --dry-run"
# inst <каталог> <аргументы>: всё, что могло бы записать, смотрит в папку стенда.
inst() {
  local catalog="$1"
  shift
  env PATH="$FAKE:$PATH" HOME="$OUT/home" INSTALL_DIR="$OUT/inst" CATALOG_URL="file://$catalog" "$ROOT/install.sh" "$@"
}
# catalog_for <файл> <id> <версия> <архив> [sha]: каталог из одной записи.
catalog_for() {
  local sha="${5:-$(shasum -a 256 "$4" | cut -d' ' -f1)}"
  printf '{"schema":1,"apps":[{"id":"%s","version":"%s","minHub":"0.6.0","url":"file://%s","sha256":"%s","sizeMB":1}]}\n' "$2" "$3" "$4" "$sha" > "$1"
}
# Выпущенный архив и его каталог: архив release-app.sh проходит проверки install.sh.
GOOD_CATALOG="$OUT/good.json"
sed "s|https://github.com/IvanSSpace/utilitumus/releases/download/awake-v1.2.3/Awake.zip|file://$ZIP|" "$NEW_CATALOG" > "$GOOD_CATALOG"
INST_LOG="$OUT/inst.txt"
inst "$GOOD_CATALOG" awake --dry-run > "$INST_LOG" 2>&1 || { cat "$INST_LOG"; bad "install.sh awake --dry-run упал"; finish; }
cat "$INST_LOG"
check "проверки пройдены" has "$INST_LOG" "Проверка пройдена"
check "путь из имени в архиве" has "$INST_LOG" "$OUT/inst/Utilitumus/Awake.app"
sed -n '/^<?xml/,/^<\/plist>/p' "$INST_LOG" > "$OUT/agent.plist"
check "плист агента читается" plutil -lint -s "$OUT/agent.plist"
# Те же ключи, что у SatelliteAgent.
check "плист агента: ровно нужные ключи" python3 -I -c '
import plistlib, sys
agent = plistlib.load(open(sys.argv[1], "rb"))
sys.exit(agent != {
    "Label": "local.utilitumus.app.awake",
    "ProgramArguments": [sys.argv[2] + "/Utilitumus/Awake.app/Contents/MacOS/Awake"],
    "RunAtLoad": True,
    "KeepAlive": False,
    "MachServices": {"local.utilitumus.app.awake.xpc": True},
})' "$OUT/agent.plist" "$OUT/inst"
check "--dry-run не вызвал launchctl" test ! -s "$LAUNCHCTL_LOG"
check "--dry-run не создал папку установки" test ! -e "$OUT/inst"
same "--dry-run не создал LaunchAgents" "$(ls -A "$OUT/home")" ""

# Как при установке через «curl | bash»: команды не должны съесть остаток скрипта со stdin.
# У пользователя bash из PATH может быть и пятым, а в UTF-8 тот читает кириллицу как часть имени.
PIPE_LOG="$OUT/pipe.txt"
for shell_bin in /bin/bash "$(command -v bash)"; do
  env LC_ALL=en_US.UTF-8 PATH="$FAKE:$PATH" HOME="$OUT/home" INSTALL_DIR="$OUT/inst" CATALOG_URL="file://$GOOD_CATALOG" \
    "$shell_bin" -s -- awake --dry-run < install.sh > "$PIPE_LOG" 2>&1 || cat "$PIPE_LOG"
  check "$shell_bin -s работает так же" has "$PIPE_LOG" "Проверка пройдена"
done

MISSING="$OUT/no-such-catalog.json"
for bad_id in AWAKE ../x a/b -rf "" .hidden $'awake\n' "бодрость"; do
  refused "id «${bad_id}» отвергнут до обращения к сети" "Недопустимый id" inst "$MISSING" "$bad_id" --dry-run
done
check "неверный id: скачивать не пытался" test ! -s "$CURL_LOG"
refused "опечатка в --dry-run не ставит" "--dryrun" inst "$GOOD_CATALOG" awake --dryrun
refused "id нет в каталоге" "нет в каталоге" inst "$GOOD_CATALOG" nope --dry-run
refused "каталог не скачался" "Каталог" inst "$MISSING" awake --dry-run
EMPTY="$OUT/empty.json"
echo '{"schema":1,"apps":[]}' > "$EMPTY"
refused "пустой каталог, как сейчас" "нет в каталоге" inst "$EMPTY" awake --dry-run

SCHEMA2="$OUT/schema2.json"
sed 's/"schema" *: *1/"schema":2/' "$GOOD_CATALOG" > "$SCHEMA2"
refused "каталог новее" "формат" inst "$SCHEMA2" awake --dry-run

C="$OUT/case.json"
catalog_for "$C" awake 1.2.3 "$ZIP" "$(printf 'a%.0s' {1..64})"
refused "неверный sha256" "Контрольная сумма" inst "$C" awake --dry-run
catalog_for "$C" awake 9.9.9 "$ZIP"
refused "версия в каталоге другая" "версия" inst "$C" awake --dry-run
catalog_for "$C" fresh 1.2.3 "$ZIP"
refused "чужой identifier: архив awake под id fresh" "Подпись" inst "$C" fresh --dry-run
BAD_VERSION="$OUT/badversion.json"
catalog_for "$BAD_VERSION" awake 1.x "$ZIP"
refused "версия с мусором в каталоге" "версия" inst "$BAD_VERSION" awake --dry-run
catalog_for "$BAD_VERSION" awake 1.9999999999999999999 "$ZIP"
refused "версия, которая не влезает в число" "версия" inst "$BAD_VERSION" awake --dry-run

# variant <дело>: копия хорошего бандла в своей папке.
variant() {
  mkdir -p "$OUT/v/$1"
  ditto "$APP" "$OUT/v/$1/Awake.app"
  echo "$OUT/v/$1/Awake.app"
}
pack() { ditto -c -k --keepParent "$OUT/v/$1/Awake.app" "$OUT/v/$1.zip"; }

V="$(variant adhoc)"
codesign --force --options runtime --sign - --identifier local.utilitumus.app.awake "$V" 2>/dev/null
pack adhoc
catalog_for "$C" awake 1.2.3 "$OUT/v/adhoc.zip"
refused "подпись ad-hoc" "Подпись" inst "$C" awake --dry-run

V="$(variant wrongid)"
codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus.app.other "$V" 2>/dev/null
pack wrongid
catalog_for "$C" awake 1.2.3 "$OUT/v/wrongid.zip"
refused "наш сертификат, чужой identifier" "Подпись" inst "$C" awake --dry-run

V="$(variant writable)"
chmod g+w "$V/Contents/MacOS/Awake"
pack writable
catalog_for "$C" awake 1.2.3 "$OUT/v/writable.zip"
refused "файл доступен группе на запись" "запись" inst "$C" awake --dry-run

V="$(variant outlink)"
ln -s /etc/hosts "$V/Contents/Resources/outlink"
codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus.app.awake "$V" 2>/dev/null || true
pack outlink
catalog_for "$C" awake 1.2.3 "$OUT/v/outlink.zip"
refused "ссылка за пределы бандла" "Подпись" inst "$C" awake --dry-run

python3 -I -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../Evil.app/Contents/Info.plist", "x")' "$OUT/v/dotdot.zip"
catalog_for "$C" awake 1.2.3 "$OUT/v/dotdot.zip"
refused "архив с ../" "за пределы" inst "$C" awake --dry-run

mkdir -p "$OUT/v/two"
ditto "$APP" "$OUT/v/two/Awake.app"
ditto "$APP" "$OUT/v/two/Other.app"
ditto -c -k "$OUT/v/two" "$OUT/v/two.zip"
catalog_for "$C" awake 1.2.3 "$OUT/v/two.zip"
refused "два .app в архиве" "один .app" inst "$C" awake --dry-run

mkdir -p "$OUT/v/noapp/Awake"
echo x > "$OUT/v/noapp/Awake/file"
ditto -c -k --keepParent "$OUT/v/noapp/Awake" "$OUT/v/noapp.zip"
catalog_for "$C" awake 1.2.3 "$OUT/v/noapp.zip"
refused "в архиве не .app" "один .app" inst "$C" awake --dry-run

mkdir -p "$OUT/v/badname"
ditto "$APP" "$OUT/v/badname/My App.app"
ditto -c -k --keepParent "$OUT/v/badname/My App.app" "$OUT/v/badname.zip"
catalog_for "$C" awake 1.2.3 "$OUT/v/badname.zip"
refused "имя .app с пробелом" "один .app" inst "$C" awake --dry-run

echo not a zip > "$OUT/v/garbage.zip"
catalog_for "$C" awake 1.2.3 "$OUT/v/garbage.zip"
refused "не zip" "не zip" inst "$C" awake --dry-run

check "launchctl не вызывался ни разу" test ! -s "$LAUNCHCTL_LOG"
check "папка установки не появилась" test ! -e "$OUT/inst"

echo "== install.sh <id>: запись и откат"
# Всё в папке стенда, launchctl подставной: настоящие /Applications и launchd не задействованы.
REAL="$OUT/inst/Utilitumus/Awake.app"
REAL_AGENT="$OUT/home/Library/LaunchAgents/local.utilitumus.app.awake.plist"
REFUSE_COUNT="$OUT/refuse.count"
export REFUSE_COUNT
: > "$LAUNCHCTL_LOG"
inst "$GOOD_CATALOG" awake > "$OUT/inst-write.txt" 2>&1 || { cat "$OUT/inst-write.txt"; bad "install.sh awake упал"; }
check "первая установка: бандл на месте" test -d "$REAL"
check "первая установка: подпись цела" codesign --verify --deep --strict "$REAL"
check "первая установка: плист на месте" test -f "$REAL_AGENT"
check "первая установка: агент загружен" has "$LAUNCHCTL_LOG" "bootstrap"
same "первая установка: рядом ничего" "$(ls -A "$OUT/inst/Utilitumus")" "Awake.app"

# Отличие старой версии от новой: метка внутри бандла и плиста.
echo старая > "$REAL/Contents/old-marker"
echo "<!-- старый -->" >> "$REAL_AGENT"
: > "$LAUNCHCTL_LOG"
rm -f "$REFUSE_COUNT"
# Десять отказов: новая версия не загрузилась, откат загрузил старую одиннадцатой попыткой.
REFUSE_BOOTSTRAP=10 refused "launchd отказал: установка сорвалась" "Прежняя версия возвращена" inst "$GOOD_CATALOG" awake
check "отказ launchd: старый бандл вернулся" test -f "$REAL/Contents/old-marker"
check "отказ launchd: старый плист вернулся" has "$REAL_AGENT" "<!-- старый -->"
same "отказ launchd: рядом ничего" "$(ls -A "$OUT/inst/Utilitumus")" "Awake.app"
same "отказ launchd: старый агент загружен, всего попыток" "$(grep -c bootstrap "$LAUNCHCTL_LOG")" "11"

# mv отказывает при переносе новой версии на место: старая версия возвращается.
mkdir -p "$OUT/mv-refuses"
cat > "$OUT/mv-refuses/mv" <<'EOF'
#!/bin/bash
case "$1" in *.new) echo "mv: отказ" >&2; exit 1 ;; esac
exec /bin/mv "$@"
EOF
chmod +x "$OUT/mv-refuses/mv"
: > "$LAUNCHCTL_LOG"
refused "mv отказал: установка сорвалась" "Прежняя версия возвращена" \
  env PATH="$OUT/mv-refuses:$FAKE:$PATH" HOME="$OUT/home" INSTALL_DIR="$OUT/inst" CATALOG_URL="file://$GOOD_CATALOG" "$ROOT/install.sh" awake
check "отказ mv: старый бандл вернулся" test -f "$REAL/Contents/old-marker"
check "отказ mv: старый плист вернулся" has "$REAL_AGENT" "<!-- старый -->"
same "отказ mv: рядом ничего" "$(ls -A "$OUT/inst/Utilitumus")" "Awake.app"

# mv отказывает и при возврате: единственная копия остаётся в .old, человек видит, где она.
mkdir -p "$OUT/mv-stuck"
cat > "$OUT/mv-stuck/mv" <<'EOF'
#!/bin/bash
case "$1" in *.new|*.old) echo "mv: отказ" >&2; exit 1 ;; esac
exec /bin/mv "$@"
EOF
chmod +x "$OUT/mv-stuck/mv"
refused "возврат не удался: причина по-русски" "прежнюю версию вернуть не удалось" \
  env PATH="$OUT/mv-stuck:$FAKE:$PATH" HOME="$OUT/home" INSTALL_DIR="$OUT/inst" CATALOG_URL="file://$GOOD_CATALOG" "$ROOT/install.sh" awake
check "возврат не удался: бандла на месте нет" test ! -e "$REAL"
check "возврат не удался: копия цела в .old" test -f "$REAL.old/Contents/old-marker"
check "возврат не удался: плист не снят" has "$REAL_AGENT" "<!-- старый -->"
# Следующий запуск новую версию не загрузит: откат вернёт старую, только если .old пережил начало запуска.
rm -f "$REFUSE_COUNT"
REFUSE_BOOTSTRAP=10 refused "следующий запуск: копия из .old не удалена" "Прежняя версия возвращена" inst "$GOOD_CATALOG" awake
check "следующий запуск: старый бандл на месте" test -f "$REAL/Contents/old-marker"
same "следующий запуск: рядом ничего" "$(ls -A "$OUT/inst/Utilitumus")" "Awake.app"

# cp отказывает при возврате плиста: бандл уже вернулся, причина по-русски.
mkdir -p "$OUT/cp-stuck"
cat > "$OUT/cp-stuck/cp" <<'EOF'
#!/bin/bash
case "$1" in *old-agent.plist) echo "cp: отказ" >&2; exit 1 ;; esac
exec /bin/cp "$@"
EOF
chmod +x "$OUT/cp-stuck/cp"
refused "возврат плиста не удался: причина по-русски" "прежнюю версию launchd не загрузил" \
  env PATH="$OUT/cp-stuck:$OUT/mv-refuses:$FAKE:$PATH" HOME="$OUT/home" INSTALL_DIR="$OUT/inst" CATALOG_URL="file://$GOOD_CATALOG" "$ROOT/install.sh" awake
check "возврат плиста не удался: старый бандл вернулся" test -f "$REAL/Contents/old-marker"

: > "$LAUNCHCTL_LOG"
inst "$GOOD_CATALOG" awake > "$OUT/inst-write.txt" 2>&1 || { cat "$OUT/inst-write.txt"; bad "обновление install.sh упало"; }
check "обновление: метки старой версии нет" test ! -e "$REAL/Contents/old-marker"
check "обновление: старый плист заменён" lacks "$REAL_AGENT" "<!-- старый -->"
same "обновление: рядом ничего" "$(ls -A "$OUT/inst/Utilitumus")" "Awake.app"

# Первая установка, launchd отказал: возвращать нечего, от утилиты не остаётся ничего.
rm -rf "$OUT/inst" "$OUT/home/Library/LaunchAgents"
rm -f "$REFUSE_COUNT"
REFUSE_BOOTSTRAP=99 refused "первая установка, launchd отказал" "не установлен" inst "$GOOD_CATALOG" awake
same "отказ при первой установке: бандла нет" "$(ls -A "$OUT/inst/Utilitumus")" ""
check "отказ при первой установке: плиста нет" test ! -e "$REAL_AGENT"
rm -rf "$OUT/inst"
rm -rf "$OUT/home/Library"

echo "== install.sh без аргумента"
# Архив с подписью ad-hoc: скрипт останавливается на проверке подписи, до записи в INSTALL_DIR.
mkdir -p "$OUT/v/hub" "$OUT/curl"
ditto "$APP" "$OUT/v/hub/Utilitumus.app"
codesign --force --sign - --identifier local.utilitumus "$OUT/v/hub/Utilitumus.app" 2>/dev/null
ditto -c -k --keepParent "$OUT/v/hub/Utilitumus.app" "$OUT/v/hub.zip"
cp "$OUT/curl-stub" "$OUT/curl/curl"
: > "$CURL_LOG"
refused "без аргумента — проверка подписи центра" "Подпись Utilitumus.app" \
  env PATH="$OUT/curl:$FAKE:$PATH" CURL_SERVES="$OUT/v/hub.zip" HOME="$OUT/home" INSTALL_DIR="$OUT/inst" "$ROOT/install.sh"
same "без аргумента — адрес последнего выпуска" "$(cat "$CURL_LOG")" \
  "https://github.com/IvanSSpace/utilitumus/releases/latest/download/Utilitumus.zip"
check "без аргумента — в INSTALL_DIR ничего" test ! -e "$OUT/inst"

finish
rm -rf "$OUT"
echo "Сборка и выпуск утилит: OK"
