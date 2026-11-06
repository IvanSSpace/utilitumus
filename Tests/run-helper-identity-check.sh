#!/bin/bash
# Личность вложенных помощников: SatelliteInstaller.liveVerify, SatelliteSelfUpdate.install, install.sh <id>.
# Внешняя подпись во всех отказах настоящая и бандл ею запечатан: отказать должна проверка помощника.
# launchctl, download и связь подставные, все пути в папке стенда. Бинарники стенда пустые, ни один не запускается.
# Папка стенда (удаляется): HELPER_IDENTITY_CHECK_DIR, иначе $TMPDIR/helper-identity-check.noindex. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${HELPER_IDENTITY_CHECK_DIR:-${TMPDIR:-/tmp}/helper-identity-check.noindex}"
F="$OUT/fixtures"
SIGN_NAME="Utilitumus Signing"

# Подписанные нашим сертификатом бинарники с боевыми identifier не оставляем.
trap 'rm -rf "$OUT"' EXIT

scripts/unlock-signing.sh
security find-identity -p codesigning | grep -q "\"$SIGN_NAME\"" || { echo "ПРОВАЛ: нет сертификата «${SIGN_NAME}»"; exit 1; }

rm -rf "$OUT"
mkdir -p "$F" "$OUT/src" "$OUT/work"
echo 'int main(void) { return 0; }' | clang -x c -target "$TARGET" -o "$F/exe" -

plist() { # файл identifier исполняемый версия [без-метки]
  {
    echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    echo "<key>CFBundleIdentifier</key><string>$2</string>"
    echo "<key>CFBundleExecutable</key><string>$3</string>"
    echo "<key>CFBundleShortVersionString</key><string>$4</string>"
    [ -n "${5:-}" ] || echo '<key>UtilitumusSecurityEpoch</key><string>1</string>'
    echo '</dict></plist>'
  } > "$1"
}
sign() { codesign --force --options runtime --sign "$SIGN_NAME" --identifier "$2" "$1" 2>/dev/null; }

# shell <дело> <Имя> <id> <версия> [без-метки]: неподписанный внешний бандл без помощника. Печатает путь.
shell_app() {
  local app="$F/$1/$2.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$F/exe" "$app/Contents/MacOS/$2"
  plist "$app/Contents/Info.plist" "local.utilitumus.app.$3" "$2" "$4" "${5:-}"
  echo "$app"
}
finish() { # внешний бандл id: внешняя подпись настоящая, архив как у выпуска
  sign "$1" "local.utilitumus.app.$2"
  ditto -c -k --keepParent "$1" "$F/$(basename "$(dirname "$1")").zip"
}

# tool <дело> <Имя> <id> <файл> <identifier> <режим> [версия] [без-метки]: помощник-бинарник и внешний бандл
tool() {
  local app helper="$4"
  app="$(shell_app "$1" "$2" "$3" "${7:-2.0.0}" "${8:-}")"
  local path="$app/Contents/MacOS/$helper"
  cp "$F/exe" "$path"
  case "$6" in
    good) sign "$path" "$5" ;;
    adhoc) codesign --force --options runtime --sign - --identifier "$5" "$path" 2>/dev/null ;;
    wrong-id) sign "$path" "$5.evil" ;;
    no-runtime) codesign --force --sign "$SIGN_NAME" --identifier "$5" "$path" 2>/dev/null ;;
    link)
      mv "$path" "$app/Contents/Resources/$helper"
      sign "$app/Contents/Resources/$helper" "$5"
      ln -s "../Resources/$helper" "$path"
      ;;
    missing) rm "$path" ;;
    *) echo "неизвестный режим $6"; exit 1 ;;
  esac
  finish "$app" "$3"
}
# nested <дело> <режим> [версия]: Browser.app с Utilitumus Links.app. Обработчиков http и html в копии нет.
nested() {
  local app links
  app="$(shell_app "$1" Browser browser "${3:-2.0.0}")"
  links="$app/Contents/Helpers/Utilitumus Links.app"
  mkdir -p "$links/Contents/MacOS"
  cp "$F/exe" "$links/Contents/MacOS/UtilitumusLinks"
  plist "$links/Contents/Info.plist" local.utilitumus.links UtilitumusLinks 2.0.0 "$([ "$2" = no-epoch ] && echo 1 || true)"
  case "$2" in
    good | no-epoch) sign "$links" local.utilitumus.links ;;
    adhoc) codesign --force --options runtime --sign - --identifier local.utilitumus.links "$links" 2>/dev/null ;;
    wrong-id) sign "$links" local.utilitumus.links.evil ;;
    no-runtime) codesign --force --sign "$SIGN_NAME" --identifier local.utilitumus.links "$links" 2>/dev/null ;;
    missing) rm -rf "$links" ;;
    *) echo "неизвестный режим $2"; exit 1 ;;
  esac
  finish "$app" browser
}

for mode in good adhoc wrong-id no-runtime link missing; do
  tool "fans-$mode" Fans fans utilitumus-fan local.utilitumus.fan "$mode"
  tool "voice-$mode" Voice voice utilitumus-voice local.utilitumus.voice "$mode"
done
tool fans-v1 Fans fans utilitumus-fan local.utilitumus.fan good 1.0.0
tool voice-v1 Voice voice utilitumus-voice local.utilitumus.voice good 1.0.0
tool fans-no-epoch Fans fans utilitumus-fan local.utilitumus.fan good 2.0.0 1
for mode in good adhoc wrong-id no-runtime no-epoch missing; do
  nested "browser-$mode" "$mode"
done
nested browser-v1 good 1.0.0

cp Tests/HelperIdentityCheck.swift "$OUT/src/main.swift"
swiftc -target "$TARGET" -module-name HelperIdentityCheck -o "$OUT/check" "$OUT/src/main.swift" \
  Sources/Kit/KitSigning.swift Sources/Kit/KitDefaults.swift Sources/Kit/SatelliteCatalog.swift Sources/Kit/SatelliteSelfUpdate.swift Sources/Kit/KitArchive.swift \
  $(find Sources/Kit/Link -name '*.swift') Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteAgent.swift

"$OUT/check" verify "$F" "$OUT/work"

fails=0
ok() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; fails=$((fails + 1)); }

echo "== таблицы установщиков"
TABLE="$("$OUT/check" table)"
OWN_EPOCH="$("$OUT/check" epoch)"
SCRIPT_EPOCH="$(sed -n 's/^SECURITY_EPOCH=//p' install.sh)"
[ "$OWN_EPOCH" = "$SCRIPT_EPOCH" ] && ok "метка выпуска в install.sh как в KitSigning: $OWN_EPOCH" || bad "метка: install.sh $SCRIPT_EPOCH, KitSigning $OWN_EPOCH"
SWIFT_IDS="$(cut -d' ' -f1 <<<"$TABLE" | LC_ALL=C sort -u)"
SCRIPT_IDS="$(sed -n '/^helpers_of()/,/^}/p' install.sh | sed -nE 's/^    ([a-z0-9.-]+)\).*/\1/p' | LC_ALL=C sort -u)"
[ "$SWIFT_IDS" = "$SCRIPT_IDS" ] && ok "одни и те же утилиты в обеих таблицах: $(tr '\n' ' ' <<<"$SWIFT_IDS")" || bad "утилиты: KitSigning «${SWIFT_IDS}», install.sh «${SCRIPT_IDS}»"
while read -r id entry; do
  [ "$(bash install.sh --helpers "$id")" = "$entry" ] && ok "$id: «${entry}» в обеих таблицах" || bad "$id: KitSigning «${entry}», install.sh «$(bash install.sh --helpers "$id")»"
done <<<"$TABLE"
[ -z "$(bash install.sh --helpers awake)" ] && ok "у Не спать помощников нет" || bad "у Не спать появились помощники"

echo "== install.sh <id>"
FAKE="$OUT/fake"
LAUNCHCTL_LOG="$OUT/launchctl.log"
mkdir -p "$FAKE" "$OUT/home"
printf '#!/bin/bash\necho "launchctl $*" >> "%s"\n' "$LAUNCHCTL_LOG" > "$FAKE/launchctl"
chmod +x "$FAKE/launchctl"

catalog() { # id версия архив
  printf '{"schema":1,"apps":[{"id":"%s","version":"%s","minHub":"0.6.0","url":"file://%s","sha256":"%s","sizeMB":1}]}\n' \
    "$1" "$2" "$3" "$(shasum -a 256 "$3" | cut -d' ' -f1)" > "$OUT/catalog.json"
}
inst() { # id версия архив; вывод в $OUT/inst.log
  catalog "$1" "$2" "$3"
  env PATH="$FAKE:$PATH" HOME="$OUT/home" INSTALL_DIR="$OUT/inst" CATALOG_URL="file://$OUT/catalog.json" bash install.sh "$1" > "$OUT/inst.log" 2>&1
}
for row in "fans Fans" "voice Voice" "browser Browser"; do
  read -r id name <<<"$row"
  DEST="$OUT/inst/Utilitumus/$name.app"
  AGENT="$OUT/home/Library/LaunchAgents/local.utilitumus.app.$id.plist"
  inst "$id" 1.0.0 "$F/$id-v1.zip" || { cat "$OUT/inst.log"; bad "$id: 1.0.0 не поставилась"; continue; }
  echo установленная > "$DEST/Contents/marker"
  AGENT_BEFORE="$(shasum -a 256 "$AGENT")"
  if [ "$id" = browser ]; then cases="adhoc:Подпись wrong-id:Подпись no-runtime:hardened no-epoch:метки missing:нет"; else cases="adhoc:Подпись wrong-id:Подпись no-runtime:hardened link:ссылка missing:нет"; fi
  [ "$id" = fans ] && cases="$cases no-epoch:метки"
  for item in $cases; do
    mode="${item%%:*}" pattern="${item#*:}"
    : > "$LAUNCHCTL_LOG"
    if inst "$id" 2.0.0 "$F/$id-$mode.zip"; then
      bad "install.sh $id $mode: установка прошла"
    elif ! grep -qF -- "$pattern" "$OUT/inst.log"; then
      bad "install.sh $id ${mode}: нет «${pattern}» в выводе: $(cat "$OUT/inst.log")"
    elif [ ! -f "$DEST/Contents/marker" ] || [ "$(plutil -extract CFBundleShortVersionString raw -o - "$DEST/Contents/Info.plist")" != 1.0.0 ]; then
      bad "install.sh $id ${mode}: установленная версия изменилась"
    elif [ "$(shasum -a 256 "$AGENT")" != "$AGENT_BEFORE" ] || [ -s "$LAUNCHCTL_LOG" ]; then
      bad "install.sh $id ${mode}: тронут агент или launchctl"
    elif [ -e "$DEST.new" ] || [ -e "$DEST.old" ]; then
      bad "install.sh $id ${mode}: рядом мусор"
    else
      ok "install.sh $id ${mode}: отказ, стоит 1.0.0, launchctl не вызван"
    fi
  done
  inst "$id" 2.0.0 "$F/$id-good.zip" || { cat "$OUT/inst.log"; bad "install.sh $id: хорошая 2.0.0 не поставилась"; continue; }
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$DEST/Contents/Info.plist")" = 2.0.0 ] && ok "install.sh $id: хорошая 2.0.0 встала" || bad "install.sh $id: хорошая 2.0.0 не встала"
done

[ "$fails" -eq 0 ] || { echo "Провалов: $fails"; exit 1; }
echo "Личность помощников: OK"
