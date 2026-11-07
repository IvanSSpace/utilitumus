#!/bin/bash
# Автообновление утилит: настоящие установщик, zip и codesign на архивах этого стенда; подставные каталог, часы, launchctl и
# связь с утилитой. Настоящие утилиты, /Applications и настройки не трогаются: всё в папке стенда, окон на экране нет.
# Папка: AUTO_UPDATE_CHECK_DIR, иначе $TMPDIR/auto-update-check. Кэш сборки рядом, чтобы переживал очистку.
# --build-only: только собрать. --mutations: собрать сломанные варианты и показать, что проверка на них краснеет.
# Нужен сертификат «Utilitumus Signing».
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. Tests/lib/incremental.sh

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${AUTO_UPDATE_CHECK_DIR:-${TMPDIR:-/tmp}/auto-update-check}"
CACHE="$(incremental_cache auto-update "$TARGET")"
BIN="auto-update-stand"
SUITE="local.utilitumus.test.kit.autoupdate"
SIGN_NAME="Utilitumus Signing"
F="$OUT/fixtures"
EPOCH="$(sed -n 's/.*static let testPeerEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
EPOCH_KEY="$(sed -n 's/.*static let securityEpochKey = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -n "$EPOCH" ] && [ -n "$EPOCH_KEY" ] || { echo "ПРОВАЛ: нет метки выпуска стенда"; exit 1; }

same() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "ПРОВАЛ: $1"; echo "  есть: «$2»"; echo "  ждали: «$3»"; exit 1; fi; }

echo "== разбор кода"
# Пилот и дев-сборка: то самое решение из ModuleMigration.swift, собранное с флагом и без. run-pilot-build-check следит, что флаг там один.
mkdir -p "$CACHE/gate"
{
  echo 'enum Gate {'
  sed -n '/static var installsOnItsOwn: Bool {/,/^    }$/p' Sources/App/Satellites/ModuleMigration.swift | sed 's/nonisolated //'
  echo '}'
  echo 'print(Gate.installsOnItsOwn)'
} > "$CACHE/gate/main.swift"
swiftc -target "$TARGET" -o "$CACHE/gate/plain" "$CACHE/gate/main.swift"
swiftc -target "$TARGET" -D KIT_PILOT_CATALOG -o "$CACHE/gate/pilot" "$CACHE/gate/main.swift"
same "обычная сборка ставит сама" "$("$CACHE/gate/plain")" "true"
same "сборка с KIT_PILOT_CATALOG сама не ставит" "$("$CACHE/gate/pilot")" "false"
grep -qE -- '-target "\$TARGET" -D KIT_PILOT_CATALOG .*-o "\$HC/Utilitumus"' scripts/dev.sh || { echo "ПРОВАЛ: dev.sh собирает центр без флага"; exit 1; }
echo "ok   scripts/dev.sh собирает центр с KIT_PILOT_CATALOG"
grep -q 'SatelliteRegistry.installsOnItsOwn' Sources/App/Store/AutoUpdate.swift || { echo "ПРОВАЛ: автообновление не смотрит на пилот"; exit 1; }
grep -q 'guard buildAllows, timer == nil' Sources/App/Store/AutoUpdate.swift || { echo "ПРОВАЛ: start() не смотрит на сборку"; exit 1; }
echo "ok   автообновление смотрит на то же решение, запуск закрыт"
same "запускает автообновление только AppDelegate" "$(grep -rl 'AutoUpdate.shared.start()' Sources)" "Sources/App/UtilitumusApp.swift"
same "автоматический проход начинает только AutoUpdate" "$(grep -rl 'startAutomatic(' Sources | LC_ALL=C sort)" "$(printf '%s\n%s' Sources/App/Store/AutoUpdate.swift Sources/App/Store/UpdateAll.swift)"
# Один путь установки: у автообновления нет своего скачивания, проверки и установщика.
same "AutoUpdate.swift сам не качает и не ставит" "$(grep -cE 'URLSession|\.install\(|SatelliteInstaller|replaceItem|verifyApp' Sources/App/Store/AutoUpdate.swift || true)" "0"
# Каждый вызов, после которого система спрашивает человека. Новый вызов должен быть проверен глазами и дописан сюда.
same "окно пароля службы только по кнопке" \
  "$(grep -rlE 'installer\.install\(\)|FanHelperInstaller\.shared\.install\(\)' Sources | LC_ALL=C sort)" \
  "$(printf '%s\n' Sources/App/Setup/SetupStep.swift Sources/Apps/Fans/FansModule.swift Sources/Modules/Fans/FansModel.swift Sources/Modules/Fans/FansWire.swift | LC_ALL=C sort)"
# Второго списка нет: и центр, и утилита читают один (самой утилите проверка в run-satellite-role-check).
same "в автообновлении нет своего списка «только по кнопке»" "$(grep -cE 'personOnly[^=]*=.*\.(fans|clipboard)|\[\.fans' Sources/App/Store/AutoUpdate.swift || true)" "0"
grep -q 'static let personOnly = Set(Module.allCases.filter { SatelliteCatalog.personOnly' Sources/App/Store/AutoUpdate.swift || { echo "ПРОВАЛ: автообновление берёт список не из каталога"; exit 1; }
echo "ok   список «только по кнопке» берётся из SatelliteCatalog"
same "браузер по умолчанию меняют только кнопка и удаление" \
  "$(grep -rlE '\.setDefault\(|setDefaultApplication' Sources | LC_ALL=C sort)" \
  "$(printf '%s\n' Sources/App/Setup/SetupStep.swift Sources/Apps/Browser/BrowserModule.swift Sources/Modules/Browser/BrowserLinkHandler.swift Sources/Modules/Browser/BrowserView.swift | LC_ALL=C sort)"
same "установка и очередь ничего системного не просят" \
  "$(grep -lE 'FanHelperInstaller\.shared\.install|setDefaultApplication|AXIsProcessTrustedWithOptions|requestAccess|CGRequest|SecItem' Sources/App/Satellites/SatelliteInstaller.swift Sources/App/Satellites/SatelliteRegistry.swift Sources/App/Store/UpdateAll.swift Sources/App/Store/AutoUpdate.swift || true)" ""

rm -rf "$F"
mkdir -p "$F/v1" "$CACHE/src"

scripts/unlock-signing.sh
if ! security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then echo "ПРОВАЛ: нет сертификата «$SIGN_NAME»"; exit 1; fi

echo 'int main(void) { return 0; }' | clang -x c -target "$TARGET" -o "$F/exe" -

plist() { # id имя версия [метка: no-epoch — без неё] [ещё ключ]
  echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
  echo "<key>CFBundleIdentifier</key><string>$1</string>"
  echo "<key>CFBundleExecutable</key><string>$2</string>"
  echo "<key>CFBundleShortVersionString</key><string>$3</string>"
  if [ "${4:-}" != no-epoch ]; then echo "<key>$EPOCH_KEY</key><string>$EPOCH</string>"; fi
  if [ -n "${5:-}" ]; then echo "<key>$5</key><string>нужно</string>"; fi
  echo '</dict></plist>'
}

# make_app id Имя версия папка [подпись] [ключ Info.plist] [файл прав] [no-epoch]: подписанный бандл утилиты, как у выпуска.
make_app() {
  local app="$4/$2.app" sign="${5:-$SIGN_NAME}"
  mkdir -p "$app/Contents/MacOS"
  cp "$F/exe" "$app/Contents/MacOS/$2"
  plist "local.utilitumus.app.$1" "$2" "$3" "${8:-}" "${6:-}" > "$app/Contents/Info.plist"
  # Помощники, которых ждёт `KitSigning.helpers`.
  case "$1" in
    fans)
      cp "$F/exe" "$app/Contents/MacOS/utilitumus-fan"
      codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus.fan "$app/Contents/MacOS/utilitumus-fan" 2>/dev/null ;;
    browser)
      local helper="$app/Contents/Helpers/Utilitumus Links.app"
      mkdir -p "$helper/Contents/MacOS"
      cp "$F/exe" "$helper/Contents/MacOS/Links"
      plist local.utilitumus.links Links "$3" > "$helper/Contents/Info.plist"
      codesign --force --options runtime --sign "$SIGN_NAME" --identifier local.utilitumus.links "$helper" 2>/dev/null ;;
  esac
  if [ -n "${7:-}" ]; then
    codesign --force --options runtime --sign "$sign" --identifier "local.utilitumus.app.$1" --entitlements "$7" "$app" 2>/dev/null
  else
    codesign --force --options runtime --sign "$sign" --identifier "local.utilitumus.app.$1" "$app" 2>/dev/null
  fi
}

zip_app() { # файл папка имя
  ditto -c -k --keepParent "$2/$3.app" "$F/$1.zip"
}

for pair in sound:Sound load:Load mixer:Mixer mouse:Mouse clipboard:Clipboard keyboard:Keyboard awake:Awake bots:Bots stash:Stash fans:Fans browser:Browser voice:Voice; do
  id="${pair%%:*}"; name="${pair##*:}"
  mkdir -p "$F/$id"
  make_app "$id" "$name" 2.0.0 "$F/$id"
  zip_app "$id-2.0.0" "$F/$id" "$name"
  if [ "$id" != stash ]; then make_app "$id" "$name" 1.0.0 "$F/v1"; fi
done

# Подделки и особые выпуски: подмена файла при «честном» каталоге.
mkdir -p "$F/x"
make_app sound Sound 2.0.0 "$F/x" -; zip_app sound-adhoc-2.0.0 "$F/x" Sound; rm -rf "$F/x/Sound.app"
make_app sound Sound 2.0.0 "$F/x" "$SIGN_NAME" "" "" no-epoch; zip_app sound-noepoch-2.0.0 "$F/x" Sound; rm -rf "$F/x/Sound.app"
make_app sound Sound 2.0.0 "$F/x" "$SIGN_NAME" NSMicrophoneUsageDescription; zip_app sound-mic-2.0.0 "$F/x" Sound; rm -rf "$F/x/Sound.app"
cat > "$F/x/audio.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
make_app mixer Mixer 2.0.0 "$F/x" "$SIGN_NAME" "" "$F/x/audio.entitlements"; zip_app mixer-ent-2.0.0 "$F/x" Mixer; rm -rf "$F/x/Mixer.app"
# На диске уже новее, чем думает реестр.
make_app sound Sound 3.0.0 "$F/x"

update_if_changed() { if ! cmp -s "$1" "$2"; then cp "$1" "$2"; fi; }
sed 's/^@main$//' Sources/App/UtilitumusApp.swift > "$CACHE/UtilitumusApp.swift.new"
update_if_changed "$CACHE/UtilitumusApp.swift.new" "$CACHE/src/UtilitumusApp.swift"
update_if_changed Tests/AutoUpdateCheck.swift "$CACHE/src/main.swift"

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' \
  -not -path 'Sources/Apps/*' -not -name UtilitumusApp.swift | LC_ALL=C sort)

# build <кэш> <выход> [замены файлов: путь=путь]
build() {
  local cache="$1" exe="$2"; shift 2
  local files=("$cache/src/main.swift" "$cache/src/UtilitumusApp.swift" "${SOURCES[@]}")
  local pair i
  for pair in ${1+"$@"}; do
    for i in "${!files[@]}"; do if [ "${files[$i]}" = "${pair%%=*}" ]; then files[i]="${pair##*=}"; fi; done
  done
  incremental_flags "$cache" "${files[@]}"
  swiftc -Onone "${INC_FLAGS[@]}" -target "$TARGET" -D KIT_TEST_DEFAULTS -module-name AutoUpdateStand -o "$exe" "${files[@]}" \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit
}

clean_defaults() {
  defaults delete "$BIN" >/dev/null 2>&1 || true
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist" "$HOME/Library/Preferences/$BIN.plist"
}
# Код выхода сохраняется: иначе ошибка скрипта выглядела бы успехом по коду последней команды ловушки.
trap 'rc=$?; clean_defaults; exit $rc' EXIT

run_stand() { # exe журнал
  rm -rf "$OUT/work" "$OUT/png"
  mkdir -p "$OUT/work" "$OUT/png"
  clean_defaults
  ( cd "$OUT" && KIT_TEST_SUITE="$SUITE" "$1" "$F" "$OUT/work" "$OUT/png" ) > "$2" 2>&1
}

if [ "${1:-}" != --mutations ]; then
  echo "== сборка"
  build "$CACHE" "$CACHE/$BIN"
  # Сборке хватает обычной очереди, стенду нужна своя.
  if [ "${1:-}" = --build-only ]; then exit 0; fi
  echo "== сценарии"
  status=0
  run_stand "$CACHE/$BIN" "$OUT/run.log" || status=$?
  /usr/bin/grep -E '^(ok   |FAIL |ВСЁ ОК|ПРОВАЛОВ)' "$OUT/run.log" || true
  if [ "$status" != 0 ]; then echo "ПРОВАЛ: стенд завершился с кодом $status, журнал $OUT/run.log"; /usr/bin/tail -5 "$OUT/run.log"; exit 1; fi
  /usr/bin/grep -q '^ВСЁ ОК$' "$OUT/run.log" || { echo "ПРОВАЛ: стенд не дошёл до конца"; exit 1; }
  exit 0
fi

# mutate <имя> <файл> <было> <стало> <какая проверка должна покраснеть>: поломка в копии, настоящие исходники не меняются.
# Кэш один на поломки: map.json перестраивается, пересобирается только изменённое.
MUT="$OUT-mut"
mutate() {
  local name="$1" file="$2" old="$3" new="$4" expect="$5"
  mkdir -p "$MUT/src"
  cp -p "$CACHE/src/main.swift" "$MUT/src/main.swift"
  local target="$MUT/src/$(basename "$file")"
  if [ "$file" = Sources/App/UtilitumusApp.swift ]; then
    source_file="$CACHE/src/UtilitumusApp.swift"
    replace_arg=()
  else
    source_file="$ROOT/$file"
    cp -p "$CACHE/src/UtilitumusApp.swift" "$MUT/src/UtilitumusApp.swift"
    replace_arg=("$file=$target")
  fi
  /usr/bin/python3 -I - "$source_file" "$target" "$old" "$new" <<'PY'
import sys
source, target, old, new = sys.argv[1:]
text = open(source, encoding="utf-8").read()
assert old in text, "нет места для поломки: " + old
open(target, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  build "$MUT" "$MUT/stand" ${replace_arg[@]+"${replace_arg[@]}"} 2>"$MUT/build.log" || { echo "ПРОВАЛ: поломка «${name}» не собралась, $MUT/build.log"; /usr/bin/tail -5 "$MUT/build.log"; exit 1; }
  local status=0
  run_stand "$MUT/stand" "$MUT/run.log" || status=$?
  if [ "$status" = 0 ]; then echo "ПРОВАЛ: поломка «${name}» не замечена"; exit 1; fi
  /usr/bin/grep -F "FAIL" "$MUT/run.log" | /usr/bin/grep -F "$expect" | head -3 > "$MUT/hits" || true
  if [ ! -s "$MUT/hits" ]; then echo "ПРОВАЛ: поломка «${name}»: ждали красную «${expect}»"; /usr/bin/grep -F FAIL "$MUT/run.log" | head -5; /usr/bin/tail -3 "$MUT/run.log"; exit 1; fi
  echo "ok   поломка «${name}» краснеет:"; sed 's/^/       /' "$MUT/hits"
}

mutate "без пропуска занятых" Sources/App/Satellites/SatelliteRegistry.swift \
  'guard let state = try? await environment.commands.moduleState(module.rawValue) else { return nil }' \
  'if module.rawValue != "" { return nil }; guard let state = try? await environment.commands.moduleState(module.rawValue) else { return nil }' \
  "занятые"
mutate "перезапуск при непонятном состоянии" Sources/App/Store/UpdateAll.swift \
  'if automatic, await satellites.stateUnreadable(module) {' \
  'if automatic, module.rawValue == "", await satellites.stateUnreadable(module) {' \
  "непонятное состояние"
mutate "без защиты от пароля" Sources/Kit/SatelliteCatalog.swift \
  'static let personOnly: Set<String> = ["fans", "clipboard"]' \
  'static let personOnly: Set<String> = ["clipboard"]' \
  "только по кнопке"
mutate "автообновление не смотрит на общий список" Sources/App/Store/AutoUpdate.swift \
  'static let personOnly = Set(Module.allCases.filter { SatelliteCatalog.personOnly.contains($0.rawValue) })' \
  'static let personOnly: Set<Module> = [.clipboard]' \
  "только по кнопке"
mutate "с понижением версии" Sources/App/Satellites/SatelliteRegistry.swift \
  'return Kit.isNewer(app.version, than: installed)' \
  'return app.version != installed' \
  "понижение"
mutate "без проверки версии на диске" Sources/App/Store/AutoUpdate.swift \
  'guard let new = version(staged), let old = version(installed), Kit.isNewer(new, than: old) else {' \
  'guard version(staged) != nil, version(installed) != nil else {' \
  "понижение"
mutate "без проверки хэша" Sources/App/Satellites/SatelliteInstaller.swift \
  'guard try Self.sha256(of: archive) == app.sha256.lowercased() else { throw SatelliteInstallError.checksum }' \
  '_ = try Self.sha256(of: archive)' \
  "подмена (хэш)"
mutate "без проверки подписи" Sources/Kit/KitSigning.swift \
  'try verifySignature(of: app, identifier: identifier, strict: true)' \
  '_ = identifier' \
  "подмена (подпись)"
mutate "без проверки новых разрешений" Sources/App/Store/AutoUpdate.swift \
  'guard added.isEmpty else { throw AutoUpdateRefusal.newPermissions(added.sorted()) }' \
  '_ = added' \
  "новое разрешение"
mutate "без паузы после сбоя" Sources/App/Store/AutoUpdate.swift \
  'now().timeIntervalSince1970 < defaults.double(forKey: AutoUpdatePolicy.retryAfterKey(id)) { return false }' \
  'now().timeIntervalSince1970 < 0 { return false }' \
  "пауза"
mutate "выход без ожидания" Sources/App/UtilitumusApp.swift \
  'guard UpdateAll.shared.installing else { return .terminateNow }' \
  'if UpdateAll.shared.installing { return .terminateNow }' \
  "выход"
echo "ВСЕ ПОЛОМКИ ЗАМЕЧЕНЫ"
