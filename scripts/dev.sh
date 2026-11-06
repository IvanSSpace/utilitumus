#!/bin/bash
# Быстрая сборка для разработки: центр и только те утилиты, что менялись. Без -O, инкрементально, кэш на каждую утилиту.
#   scripts/dev.sh                        что менялось, определяется по git (от ветки main и рабочее дерево)
#   scripts/dev.sh mixer load browser     ровно эти утилиты и центр
#   scripts/dev.sh --hub                  только центр
# Центр собирается всегда: пустая пересборка стоит полсекунды. Помощники (вентиляторы, голос, Links) собираются
# один раз и лежат в кэше, пока не менялись их исходники.
# Утилиты попадают в центр штатным путём: свой каталог (catalog.json, архивы) в папке разработки и центр,
# собранный с KIT_PILOT_CATALOG. Версия пересобранной утилиты на патч выше и каталожной, и установленной, поэтому
# Стор предлагает обновление. Остальные записи каталога остаются настоящими (боевые адреса GitHub).
# В /Applications ничего не кладёт и ничего не запускает: команду для запуска печатает.
# Папка: UTILITUMUS_DEV_DIR (по умолчанию ~/Documents/projectsIvan/utilitumus-dev). Установленные утилиты читаются
# из UTILITUMUS_DEV_INSTALLED (по умолчанию /Applications/Utilitumus), только чтение версии.
# Выпуск из этой сборки невозможен: бандлы несут UtilitumusDevBuild, scripts/check-no-seam.sh их отвергает.
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."

fail() { echo "$1" >&2; exit 1; }
matches() { local LC_ALL=C; [[ "$1" =~ $2 ]]; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
STEPS=()
T0="$(now)"
step() { # название, начало
  STEPS+=("$(perl -e 'printf "%6.1f с  %s", $ARGV[0]-$ARGV[1], $ARGV[2]' "$(now)" "$2" "$1")")
}

DEV="${UTILITUMUS_DEV_DIR:-$HOME/Documents/projectsIvan/utilitumus-dev}"
INSTALLED_DIR="${UTILITUMUS_DEV_INSTALLED:-/Applications/Utilitumus}"
# Путь попадает в строку Swift, в JSON и в file://-адрес: без пробелов, кавычек и кириллицы.
matches "$DEV" '^/[A-Za-z0-9/._-]+$' || fail "В пути к папке разработки только латиница, цифры и . _ - /: ${DEV}"
[ -z "${UTILITUMUS_DEV_CACHE:-}" ] || fail "UTILITUMUS_DEV_CACHE задаёт сам dev.sh, снаружи его не нужно."

# id:Имя. Утилиты, которых нет в этой ветке, пропускаются.
ALL_APPS="awake:Awake sound:Sound mouse:Mouse mixer:Mixer stash:Stash load:Load voice:Voice keyboard:Keyboard clipboard:Clipboard fans:Fans browser:Browser bots:Bots"
APPS=""
for pair in $ALL_APPS; do [ -d "Sources/Apps/${pair##*:}" ] && APPS="$APPS $pair"; done
name_of() { local pair; for pair in $APPS; do [ "${pair%%:*}" = "$1" ] && { echo "${pair##*:}"; return; }; done; return 1; }
id_of_name() { local pair; for pair in $APPS; do [ "${pair##*:}" = "$1" ] && { echo "${pair%%:*}"; return; }; done; return 1; }

# --- Что собирать
PICK=()
if [ $# -eq 1 ] && [ "$1" = "--hub" ]; then
  echo "Выбрано: только центр (--hub)."
elif [ $# -gt 0 ]; then
  for id in "$@"; do
    name_of "$id" >/dev/null || fail "Нет такой утилиты: ${id}. Есть:$(for p in $APPS; do printf ' %s' "${p%%:*}"; done)"
    PICK+=("$id")
  done
  echo "Выбрано по аргументам: ${PICK[*]}"
else
  BASE="$(/usr/bin/git merge-base HEAD main 2>/dev/null || echo HEAD)"
  CHANGED="$({ /usr/bin/git diff --name-only "$BASE"; /usr/bin/git ls-files -o --exclude-standard; } | sort -u)"
  KIT=""
  while IFS= read -r file; do
    case "$file" in
      Sources/Apps/*/* | Sources/Modules/*/*) id="$(id_of_name "$(echo "$file" | cut -d/ -f3)")" || continue ;;
      Sources/VoiceHelper/*) id=voice ;;
      Sources/Kit/*) KIT=1; continue ;;
      *) continue ;;
    esac
    case " ${PICK[*]:-} " in *" $id "*) ;; *) PICK+=("$id") ;; esac
  done <<<"$CHANGED"
  echo "Выбрано по git (от $(echo "$BASE" | cut -c1-7), с рабочим деревом): ${PICK[*]:-ничего, только центр}"
  if [ -n "$KIT" ]; then
    echo "Менялся Sources/Kit: затрагивает все утилиты ($(for p in $APPS; do printf '%s ' "${p%%:*}"; done)); автоматически не пересобираю, назови нужные: scripts/dev.sh <id> ..."
  fi
fi

# --- Подпись и версии
EPOCH="$(sed -n 's/.*static let securityEpoch = "\(.*\)".*/\1/p' Sources/Kit/KitSigning.swift)"
[ -n "$EPOCH" ] || fail "Нет securityEpoch в Sources/Kit/KitSigning.swift"
LEAF="$(grep -oE '"[0-9a-f]{40}"' Sources/Kit/KitSigning.swift | head -1 | tr -d '"')"
MIN_HUB="0.6.0"
HUB_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Info.plist)"
if [ "$(printf '%s\n%s\n' "$MIN_HUB" "$HUB_VERSION" | sort -V | head -1)" != "$MIN_HUB" ]; then
  fail "Центр ${HUB_VERSION} старше ${MIN_HUB}: каталог его не примет."
fi
TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"

SIGN_NAME="Utilitumus Signing"
scripts/unlock-signing.sh
if [[ "$(security find-identity -p codesigning)" == *"\"$SIGN_NAME\""* ]]; then
  SIGN_ID="$SIGN_NAME"
else
  fail "Нет сертификата «${SIGN_NAME}»: утилиты проверяют подпись центра, с ad-hoc подписью dev-сборка не заработает."
fi
signed_by_author() {
  codesign --verify --deep --strict -R="identifier \"$2\" and certificate leaf = H\"$LEAF\"" "$1" 2>/dev/null \
    || fail "$1 не подписан сертификатом «Utilitumus Signing»."
}

mkdir -p "$DEV/cache" "$DEV/log" "$DEV/dist" "$DEV/app"
CATALOG="$DEV/catalog.json"
if [ ! -f "$CATALOG" ]; then
  cp Catalog/catalog.json "$CATALOG"
  echo "Каталог разработки создан из Catalog/catalog.json (адреса GitHub)."
fi

# --- Утилиты: параллельно, у каждой свой кэш
BUILT=()
if [ ${#PICK[@]} -gt 0 ]; then
  T="$(now)"
  VERSIONS="$(APPS="$APPS" /usr/bin/python3 -I - "$CATALOG" "$INSTALLED_DIR" "${PICK[@]}" <<'PY'
import json, os, plistlib, sys
catalog = {a["id"]: a["version"] for a in json.load(open(sys.argv[1]))["apps"]}
installed_dir = sys.argv[2]
names = dict(p.split(":") for p in os.environ["APPS"].split())
def key(v): return tuple(int(x) for x in v.split("."))
for id in sys.argv[3:]:
    seen = [catalog.get(id, "1.0.0")]
    try:
        with open(f"{installed_dir}/{names[id]}.app/Contents/Info.plist", "rb") as f:
            seen.append(plistlib.load(f)["CFBundleShortVersionString"])
    except Exception:
        pass
    top = max(seen, key=key)
    parts = list(key(top)) + [0] * (3 - len(key(top)))
    parts[-1] += 1
    print(id, ".".join(map(str, parts)))
PY
)"
  while read -r id version; do
    name="$(name_of "$id")"
    (
      s="$(now)"
      if UTILITUMUS_DEV_CACHE="$DEV/cache/$id" scripts/build-app.sh "$id" "$name" "$version" "$DEV/app" > "$DEV/log/$id.log" 2>&1; then
        echo "ok $(perl -e 'printf "%.1f", $ARGV[0]-$ARGV[1]' "$(now)" "$s")" > "$DEV/log/$id.rc"
      else
        echo "fail $(perl -e 'printf "%.1f", $ARGV[0]-$ARGV[1]' "$(now)" "$s")" > "$DEV/log/$id.rc"
      fi
    ) &
    BUILT+=("$id:$name:$version")
  done <<<"$VERSIONS"
  wait
  for entry in ${BUILT[@]+"${BUILT[@]}"}; do
    IFS=: read -r id name version <<<"$entry"
    read -r result secs < "$DEV/log/$id.rc"
    if [ "$result" != ok ]; then tail -20 "$DEV/log/$id.log" >&2; fail "${name}: сборка упала (полный лог: $DEV/log/$id.log)"; fi
    STEPS+=("$(printf '%6s с    утилита %s %s' "$secs" "$name" "$version")")
  done
  step "утилиты параллельно, всего" "$T"

  # Архивы и каталог: записи пересобранных утилит заменяются, остальные не трогаются.
  T="$(now)"
  ENTRIES=""
  for entry in ${BUILT[@]+"${BUILT[@]}"}; do
    IFS=: read -r id name version <<<"$entry"
    signed_by_author "$DEV/app/$name.app" "local.utilitumus.app.$id"
    ZIP="$DEV/dist/$name-$version.zip"
    rm -f -- "$DEV/dist/$name-"*.zip
    ditto -c -k --keepParent "$DEV/app/$name.app" "$ZIP"
    SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    SIZE_MB="$(( ($(stat -f %z "$ZIP") + 999999) / 1000000 ))"
    ENTRIES="${ENTRIES:+$ENTRIES,}{\"id\":\"$id\",\"version\":\"$version\",\"minHub\":\"$MIN_HUB\",\"url\":\"file://$ZIP\",\"sha256\":\"$SHA\",\"sizeMB\":$SIZE_MB,\"notes\":[\"Сборка для разработки\"]}"
  done
  ENTRIES="$ENTRIES" /usr/bin/python3 -I - "$CATALOG" <<'PY'
import json, os, sys
path = sys.argv[1]
catalog = json.load(open(path))
fresh = {a["id"]: a for a in json.loads("[" + os.environ["ENTRIES"] + "]")}
catalog["apps"] = [fresh.pop(a["id"], a) for a in catalog["apps"]] + list(fresh.values())
json.dump(catalog, open(path + ".tmp", "w"), ensure_ascii=False)
os.replace(path + ".tmp", path)
PY
  step "архивы и каталог" "$T"
fi

# --- Центр: всегда
T="$(now)"
HC="$DEV/cache/hub"
mkdir -p "$HC"
SOURCE="$DEV/PilotCatalog.swift"
WANT="enum KitPilotCatalog {
    static let path = \"$CATALOG\"
}"
[ "$(cat "$SOURCE" 2>/dev/null || true)" = "$WANT" ] || printf '%s\n' "$WANT" > "$SOURCE"

scripts/fetch-sherpa.sh >/dev/null
SHERPA="Vendor/sherpa-onnx"
SHERPA_LIBS=(libsherpa-onnx-c-api libsherpa-onnx-core libonnxruntime libkaldi-decoder-core libkaldi-native-fbank-core libkissfft-float libsherpa-onnx-fst libsherpa-onnx-fstfar libsherpa-onnx-kaldifst-core libssentencepiece_core libutf8proc)

# Помощник пересобирается, только если изменился отпечаток его исходников, цели или подписи.
helper_stamp() { # имя, файлы...
  local name="$1" f; shift
  { printf '%s\n' "$TARGET" "$SIGN_ID" "$name"; for f in "$@"; do case "$f" in *.a) stat -f '%N %z %m' "$f" ;; *) cat "$f" ;; esac; done; } | shasum -a 256
}
helper_fresh() { [ -e "$HC/$1" ] && [ -f "$HC/$1.stamp" ] && [ "$(<"$HC/$1.stamp")" = "$2" ]; }

HELPER_NOTE=""
FAN_FILES=(Sources/Shared/SMC.swift Sources/Shared/FanLink.swift Sources/Kit/KitSigning.swift Sources/FanHelper/main.swift)
STAMP="$(helper_stamp fan "${FAN_FILES[@]}")"
if ! helper_fresh utilitumus-fan "$STAMP"; then
  swiftc -O -wmo -target "$TARGET" -o "$HC/utilitumus-fan" "${FAN_FILES[@]}" -framework IOKit
  codesign --force --options runtime --sign "$SIGN_ID" --identifier local.utilitumus.fan "$HC/utilitumus-fan"
  echo "$STAMP" > "$HC/utilitumus-fan.stamp"; HELPER_NOTE="$HELPER_NOTE fan"
fi

VOICE_FILES=(Sources/VoiceHelper/main.c)
for lib in "${SHERPA_LIBS[@]}"; do VOICE_FILES+=("$SHERPA/lib/$lib.a"); done
STAMP="$(helper_stamp voice "${VOICE_FILES[@]}")"
if ! helper_fresh utilitumus-voice "$STAMP"; then
  clang -O2 -Wall -target "$TARGET" -I "$SHERPA/include" -o "$HC/utilitumus-voice" "${VOICE_FILES[@]}" \
    -lc++ -framework Foundation -framework Accelerate -Wl,-dead_strip
  codesign --force --options runtime --sign "$SIGN_ID" --identifier local.utilitumus.voice "$HC/utilitumus-voice"
  echo "$STAMP" > "$HC/utilitumus-voice.stamp"; HELPER_NOTE="$HELPER_NOTE voice"
fi

LINKS_FILES=(Sources/LinkHelper/main.swift Sources/Modules/Browser/BrowserCatalog.swift Sources/Modules/Browser/BrowserRules.swift
  Sources/Modules/Browser/BrowserPicker.swift Sources/Modules/Browser/BrowserRouter.swift Sources/LinkHelper/Info.plist Info.plist)
[ ! -f Resources/AppIcon.icns ] || LINKS_FILES+=(Resources/AppIcon.icns)
STAMP="$(helper_stamp links "${LINKS_FILES[@]}")"
if ! helper_fresh "Utilitumus Links.app" "$STAMP"; then
  L="$HC/Utilitumus Links.app"
  rm -rf "$L"; mkdir -p "$L/Contents/MacOS" "$L/Contents/Resources"
  swiftc -O -target "$TARGET" -o "$L/Contents/MacOS/UtilitumusLinks" "${LINKS_FILES[@]:0:5}" -framework SwiftUI -framework AppKit
  cp Sources/LinkHelper/Info.plist "$L/Contents/Info.plist"
  for key in CFBundleShortVersionString CFBundleVersion; do
    /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" Info.plist)" "$L/Contents/Info.plist"
  done
  [ ! -f Resources/AppIcon.icns ] || cp Resources/AppIcon.icns "$L/Contents/Resources/"
  codesign --force --options runtime --sign "$SIGN_ID" --identifier local.utilitumus.links "$L"
  echo "$STAMP" > "$HC/Utilitumus Links.app.stamp"; HELPER_NOTE="$HELPER_NOTE links"
fi
step "помощники центра (пересобрано:${HELPER_NOTE:- ничего})" "$T"

# Инкрементальная компиляция центра. Карта объектов по хэшу пути, как у утилит (scripts/build-app.sh).
T="$(now)"
HUB_FILES=()
while IFS= read -r f; do HUB_FILES+=("$f"); done < <(find Sources -name '*.swift' -not -path 'Sources/FanHelper/*' -not -path 'Sources/LinkHelper/*' -not -path 'Sources/Apps/*' | sort)
HUB_FILES+=("$SOURCE")
/usr/bin/python3 -I - "$HC" "${HUB_FILES[@]}" <<'PY'
import hashlib, json, sys
cache = sys.argv[1]
out = {"": {"swift-dependencies": cache + "/master.swiftdeps"}}
for f in sys.argv[2:]:
    b = cache + "/o" + hashlib.md5(f.encode()).hexdigest()[:12]
    out[f] = {"object": b + ".o", "swift-dependencies": b + ".swiftdeps", "dependencies": b + ".d"}
new = json.dumps(out)
try:
    same = open(cache + "/map.json").read() == new
except OSError:
    same = False
if not same:
    open(cache + "/map.json", "w").write(new)
PY
if ! swiftc -Onone -incremental -enable-batch-mode -j8 -output-file-map "$HC/map.json" -module-name Utilitumus \
  -parse-as-library -target "$TARGET" -D KIT_PILOT_CATALOG -o "$HC/Utilitumus" "${HUB_FILES[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework IOKit > "$HC/compile.log" 2>&1; then
  grep -E 'error:' "$HC/compile.log" | head -20 >&2 || tail -20 "$HC/compile.log" >&2
  fail "Центр не собрался (полный лог: $HC/compile.log)"
fi
step "центр: компиляция и линковка" "$T"

# Бандл пересобирается и подписывается, только когда изменился бинарник, помощники, plist или ресурсы.
T="$(now)"
APP="$DEV/hub/Utilitumus.app"
BUNDLE_STAMP="$({
  shasum -a 256 "$HC/Utilitumus" Info.plist Utilitumus.entitlements Resources/WhatsNew.json $( [ -f Resources/AppIcon.icns ] && echo Resources/AppIcon.icns )
  cat "$HC"/*.stamp; echo "$SIGN_ID"
} | shasum -a 256)"
SIGNED="no"
if [ ! -d "$APP" ] || [ ! -f "$DEV/hub/stamp" ] || [ "$(<"$DEV/hub/stamp")" != "$BUNDLE_STAMP" ]; then
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
  cp "$HC/Utilitumus" "$HC/utilitumus-fan" "$HC/utilitumus-voice" "$APP/Contents/MacOS/"
  cp -R "$HC/Utilitumus Links.app" "$APP/Contents/Helpers/"
  cp Info.plist "$APP/Contents/Info.plist"
  plutil -replace UtilitumusDevBuild -bool true "$APP/Contents/Info.plist"
  [ ! -f Resources/AppIcon.icns ] || cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  cp Resources/WhatsNew.json "$APP/Contents/Resources/"
  codesign --force --options runtime --entitlements Utilitumus.entitlements --sign "$SIGN_ID" "$APP"
  echo "$BUNDLE_STAMP" > "$DEV/hub/stamp"
  SIGNED="yes"
fi
step "центр: бандл и подпись (подписывал: $SIGNED)" "$T"

# --- Проверки готового
T="$(now)"
codesign --verify --deep --strict "$APP" || fail "Подпись центра не сходится."
signed_by_author "$APP" local.utilitumus
[ "$(plutil -extract UtilitumusSecurityEpoch raw -o - "$APP/Contents/Info.plist")" = "$EPOCH" ] || fail "В Info.plist центра метка выпуска не ${EPOCH}."
[[ "$(strings -a "$APP/Contents/MacOS/Utilitumus")" == *"$CATALOG"* ]] || fail "В центре нет пути к каталогу разработки."
step "проверки (подпись, метка выпуска, каталог)" "$T"

echo
echo "Собрано для разработки, ничего не установлено и не запущено (всего $(perl -e 'printf "%.1f", $ARGV[0]-$ARGV[1]' "$(now)" "$T0") с)."
for s in "${STEPS[@]}"; do echo "  $s"; done
echo "  Центр $HUB_VERSION: $APP"
echo "  Каталог: $CATALOG"
if [ ${#BUILT[@]} -gt 0 ]; then
  echo "  Утилиты (Стор предложит обновление):"
  for entry in ${BUILT[@]+"${BUILT[@]}"}; do IFS=: read -r id name version <<<"$entry"; echo "    $name $version"; done
fi
echo
echo "Запуск (сначала закрой запущенный центр):"
echo "  open \"$APP\""
