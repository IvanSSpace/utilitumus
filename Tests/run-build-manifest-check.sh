#!/bin/bash
# Манифест scripts/build-app.sh: разрешения, дополнительные исходники, вложенные помощники, отказы сборки.
# Подставной репозиторий с настоящими исходниками помощников; ничего не запускается, кроме `version` службы
# вентиляторов (без SMC и launchd) и install.sh <id> --dry-run. У копии Links убраны обработчики http и html:
# такая сборка не может стать браузером по умолчанию, в LaunchServices её никто не регистрирует.
# Папка стенда: BUILD_MANIFEST_CHECK_DIR, иначе $TMPDIR/build-manifest-check.noindex. Нужен сертификат «Utilitumus Signing».
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

OUT="${BUILD_MANIFEST_CHECK_DIR:-${TMPDIR:-/tmp}/build-manifest-check.noindex}"
FX="$OUT/repo"
BA="$FX/scripts/build-app.sh"
SIGN_NAME="Utilitumus Signing"
LEAF="$(grep -oE '"[0-9a-f]{40}"' Sources/Kit/KitSigning.swift | head -1 | tr -d '"')"

fails=0
ok() { echo "ok   $1"; }
bad() { echo "ПРОВАЛ: $1"; fails=$((fails + 1)); }
check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: «${2}», ждали «${3}»"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }

scripts/unlock-signing.sh
security find-identity -p codesigning | grep -q "\"$SIGN_NAME\"" || { echo "ПРОВАЛ: нет сертификата «${SIGN_NAME}»"; exit 1; }

rm -rf "$OUT"
mkdir -p "$FX/scripts" "$FX/Sources/Kit" "$FX/Sources/Apps" "$FX/Sources/Modules" "$FX/Sources/Modules/Browser"
cp scripts/build-app.sh scripts/fetch-sherpa.sh "$FX/scripts/"
cp install.sh Info.plist "$FX/"
cp Sources/Kit/KitSigning.swift "$FX/Sources/Kit/"
cp -R Sources/Shared Sources/FanHelper Sources/VoiceHelper Sources/LinkHelper "$FX/Sources/"
for file in BrowserCatalog BrowserRules BrowserPicker BrowserRouter; do
  cp "Sources/Modules/Browser/$file.swift" "$FX/Sources/Modules/Browser/"
done
ln -s "$ROOT/Vendor" "$FX/Vendor"
plutil -remove CFBundleURLTypes "$FX/Sources/LinkHelper/Info.plist"
plutil -remove CFBundleDocumentTypes "$FX/Sources/LinkHelper/Info.plist"

# app <Имя> <код main.swift>: Info.plist с меткой и пустая папка модуля, манифест пишет вызывающий.
app() {
  mkdir -p "$FX/Sources/Apps/$1" "$FX/Sources/Modules/$1"
  printf '%s\n' "$2" > "$FX/Sources/Apps/$1/main.swift"
  cat > "$FX/Sources/Apps/$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>UtilitumusSecurityEpoch</key><string>1</string>
</dict></plist>
EOF
}
entitlements() { # файл, ключ
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>$2</key><true/></dict></plist>
EOF
}
build() { # id Имя
  "$BA" "$1" "$2" 1.2.3 "$OUT/built" > "$OUT/$2.log" 2>&1 || { cat "$OUT/$2.log"; bad "$2 не собрался"; return 1; }
}
identity() { # путь, identifier
  codesign --verify -R="identifier \"$2\" and certificate leaf = H\"$LEAF\"" "$1"
}
signed_with_runtime() { [[ "$(codesign -dvv "$1" 2>&1)" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]]; }
# Проходит ли архив настоящий install.sh: launchctl и запись не задействованы.
installable() { # id Имя
  local zip="$OUT/$2.zip" catalog="$OUT/$2.json"
  ditto -c -k --keepParent "$OUT/built/$2.app" "$zip"
  printf '{"schema":1,"apps":[{"id":"%s","version":"1.2.3","minHub":"0.6.0","url":"file://%s","sha256":"%s","sizeMB":1}]}\n' \
    "$1" "$zip" "$(shasum -a 256 "$zip" | cut -d' ' -f1)" > "$catalog"
  env HOME="$OUT/home" INSTALL_DIR="$OUT/inst" CATALOG_URL="file://$catalog" bash install.sh "$1" --dry-run
}

echo "== Микшер: разрешение, фреймворки в манифесте"
AUDIO_CODE='import CoreAudio
import AudioToolbox
import IOKit
print(AudioObjectIsPropertySettable as Any, AudioComponentCount as Any, IOServiceMatching("x") != nil)'
app Mixer "$AUDIO_CODE"
entitlements "$FX/Sources/Apps/Mixer/Mixer.entitlements" com.apple.security.device.audio-input
cat > "$FX/Sources/Apps/Mixer/manifest.json" <<'EOF'
{"frameworks":["CoreAudio","AudioToolbox","IOKit"],"linkerFlags":["-dead_strip"],"entitlements":"Sources/Apps/Mixer/Mixer.entitlements"}
EOF
if build mixer Mixer; then
  APP="$OUT/built/Mixer.app"
  check "Микшер: подпись и hardened runtime" signed_with_runtime "$APP"
  check "Микшер: подпись цела" codesign --verify --deep --strict "$APP"
  has "$(codesign -d --entitlements - "$APP" 2>&1)" com.apple.security.device.audio-input \
    && ok "Микшер: audio-input в подписи" || bad "Микшер: audio-input в подписи"
  for framework in CoreAudio AudioToolbox IOKit; do
    has "$(otool -L "$APP/Contents/MacOS/Mixer")" "$framework.framework" && ok "Микшер: $framework в бинарнике" || bad "Микшер: $framework в бинарнике"
  done
fi

echo "== Фреймворки без упоминания в манифесте"
# build.sh перечисляет их явно, build-app.sh нет. Этот случай показывает, нужно ли это.
app Autolink "$AUDIO_CODE"
echo '{}' > "$FX/Sources/Apps/Autolink/manifest.json"
if build autolink Autolink; then
  for framework in CoreAudio AudioToolbox IOKit; do
    has "$(otool -L "$OUT/built/Autolink.app/Contents/MacOS/Autolink")" "$framework.framework" \
      && ok "по import: $framework подвязан сам" || bad "по import: $framework не подвязан"
  done
fi
# Без entitlements в манифесте их нет и в подписи.
has "$(codesign -d --entitlements - "$OUT/built/Autolink.app" 2>&1)" com.apple.security \
  && bad "без манифеста появились разрешения" || ok "без разрешений в манифесте их нет и в подписи"

echo "== Вентиляторы: Shared, служба, apple-events"
app Fans 'print(FanLink.helperVersion)'
entitlements "$FX/Sources/Apps/Fans/Fans.entitlements" com.apple.security.automation.apple-events
cat > "$FX/Sources/Apps/Fans/manifest.json" <<'EOF'
{
  "sources": ["Sources/Shared"],
  "frameworks": ["IOKit"],
  "entitlements": "Sources/Apps/Fans/Fans.entitlements",
  "helpers": [{
    "kind": "swift-tool",
    "path": "Contents/MacOS/utilitumus-fan",
    "identifier": "local.utilitumus.fan",
    "sources": ["Sources/Shared/SMC.swift", "Sources/Shared/FanLink.swift", "Sources/Kit/KitSigning.swift", "Sources/FanHelper/main.swift"],
    "frameworks": ["IOKit"]
  }]
}
EOF
if build fans Fans; then
  APP="$OUT/built/Fans.app"
  HELPER="$APP/Contents/MacOS/utilitumus-fan"
  same "Вентиляторы: Shared собран в утилиту" "$("$APP/Contents/MacOS/Fans")" "$(sed -n 's/.*static let helperVersion = "\(.*\)".*/\1/p' Sources/Shared/FanLink.swift)"
  check "служба: свой identifier и наш сертификат" identity "$HELPER" local.utilitumus.fan
  check "служба: hardened runtime" signed_with_runtime "$HELPER"
  same "служба: version" "$("$HELPER" version)" "$("$APP/Contents/MacOS/Fans")"
  grep -qE 'SwiftUI|AppKit' <<<"$(otool -L "$HELPER")" && bad "в службе SwiftUI или AppKit" || ok "в службе нет SwiftUI и AppKit"
  check "внешняя подпись запечатала службу" codesign --verify --deep --strict "$APP"
  has "$(codesign -d --entitlements - "$APP" 2>&1)" com.apple.security.automation.apple-events \
    && ok "Вентиляторы: apple-events в подписи" || bad "Вентиляторы: apple-events в подписи"
  has "$(codesign -d --entitlements - "$HELPER" 2>&1)" com.apple.security && bad "у службы появились разрешения" || ok "у службы нет разрешений"
  check "настоящий install.sh fans принимает сборку" installable fans Fans
fi

echo "== Голос: C-помощник и статический sherpa"
app Voice 'print("voice")'
python3 -I - "$FX/Sources/Apps/Voice/manifest.json" <<'PY'
import json, sys
lib = "Vendor/sherpa-onnx/lib/lib%s.a"
names = ["sherpa-onnx-c-api", "sherpa-onnx-core", "onnxruntime", "kaldi-decoder-core", "kaldi-native-fbank-core", "kissfft-float",
         "sherpa-onnx-fst", "sherpa-onnx-fstfar", "sherpa-onnx-kaldifst-core", "ssentencepiece_core", "utf8proc"]
json.dump({"helpers": [{
    "kind": "c-tool",
    "path": "Contents/MacOS/utilitumus-voice",
    "identifier": "local.utilitumus.voice",
    "prepare": "scripts/fetch-sherpa.sh",
    "includes": ["Vendor/sherpa-onnx/include"],
    "sources": ["Sources/VoiceHelper/main.c"] + [lib % n for n in names],
    "frameworks": ["Foundation", "Accelerate"],
    "linkerFlags": ["-lc++", "-dead_strip"],
}]}, open(sys.argv[1], "w"), indent=2)
PY
if build voice Voice; then
  APP="$OUT/built/Voice.app"
  HELPER="$APP/Contents/MacOS/utilitumus-voice"
  check "голос: свой identifier и наш сертификат" identity "$HELPER" local.utilitumus.voice
  check "голос: hardened runtime" signed_with_runtime "$HELPER"
  grep -qiE 'sherpa|onnx' <<<"$(otool -L "$HELPER")" && bad "sherpa подвязан динамически" || ok "sherpa внутри бинарника: в otool -L его нет"
  SIZE="$(stat -f %z "$HELPER")"
  if [ "$SIZE" -gt 5000000 ]; then ok "голос: размер $SIZE байт"; else bad "голос: размер $SIZE байт, sherpa не влинкован"; fi
  has "$(codesign -d --entitlements - "$HELPER" 2>&1)" com.apple.security && bad "у голоса появились разрешения" || ok "у голоса нет разрешений"
  check "внешняя подпись запечатала голос" codesign --verify --deep --strict "$APP"
  check "настоящий install.sh voice принимает сборку" installable voice Voice
fi

echo "== Браузер: вложенный Utilitumus Links.app"
app Browser 'print("browser")'
cat > "$FX/Sources/Apps/Browser/manifest.json" <<'EOF'
{"helpers":[{
  "kind": "swift-app",
  "path": "Contents/Helpers/Utilitumus Links.app",
  "identifier": "local.utilitumus.links",
  "executable": "UtilitumusLinks",
  "info": "Sources/LinkHelper/Info.plist",
  "sources": ["Sources/LinkHelper/main.swift", "Sources/Modules/Browser/BrowserCatalog.swift", "Sources/Modules/Browser/BrowserRules.swift", "Sources/Modules/Browser/BrowserPicker.swift", "Sources/Modules/Browser/BrowserRouter.swift"]
}]}
EOF
if build browser Browser; then
  APP="$OUT/built/Browser.app"
  LINKS="$APP/Contents/Helpers/Utilitumus Links.app"
  check "Links: свой identifier и наш сертификат" identity "$LINKS" local.utilitumus.links
  check "Links: hardened runtime" signed_with_runtime "$LINKS"
  check "Links: бинарник на месте" test -x "$LINKS/Contents/MacOS/UtilitumusLinks"
  same "Links: версия из сборки" "$(plutil -extract CFBundleShortVersionString raw -o - "$LINKS/Contents/Info.plist")" 1.2.3
  same "Links: метка выпуска" "$(plutil -extract UtilitumusSecurityEpoch raw -o - "$LINKS/Contents/Info.plist")" 1
  check "внешняя подпись запечатала Links" codesign --verify --deep --strict "$APP"
  check "настоящий install.sh browser принимает сборку" installable browser Browser
fi

echo "== Отказы сборки"
refused() { # описание, шаблон в выводе, Имя, id
  local output status=0
  output="$("$BA" "$4" "$3" 1.2.3 "$OUT/refused" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    bad "${1}: сборка прошла"
  elif ! grep -qF -- "$2" <<<"$output"; then
    bad "${1}: нет «${2}» в выводе: ${output}"
  elif [ -e "$OUT/refused/$3.app" ]; then
    bad "${1}: бандл появился"
  else
    ok "$1"
  fi
}
# Заготовка для отказов: компилировать она не успевает, поэтому main.swift пустой.
bad_app() { app Bad '' ; echo "$1" > "$FX/Sources/Apps/Bad/manifest.json"; }

bad_app '{}'
plutil -remove UtilitumusSecurityEpoch "$FX/Sources/Apps/Bad/Info.plist"
refused "Info.plist без метки" UtilitumusSecurityEpoch Bad bad
bad_app '{}'
plutil -replace UtilitumusSecurityEpoch -string 0 "$FX/Sources/Apps/Bad/Info.plist"
refused "Info.plist со старой меткой" UtilitumusSecurityEpoch Bad bad
bad_app '{}'
plutil -replace UtilitumusSecurityEpoch -integer 1 "$FX/Sources/Apps/Bad/Info.plist"
refused "метка числом: требование ждёт строку" UtilitumusSecurityEpoch Bad bad

bad_app '{не json'
refused "манифест не JSON" "не JSON" Bad bad
bad_app '["Sources/Shared"]'
refused "сверху список" "не JSON" Bad bad
bad_app '{"source":["Sources/Shared"]}'
refused "опечатка в ключе" "неизвестный ключ" Bad bad
bad_app '{"sources":"Sources/Shared"}'
refused "sources не список" "не список" Bad bad
bad_app '{"sources":["../secret"]}'
refused "путь за пределы репозитория" "недопустимый путь" Bad bad
bad_app '{"sources":["Sources/../../secret"]}'
refused "путь через .. внутри" "недопустимый путь" Bad bad
bad_app '{"sources":["/etc/hosts"]}'
refused "абсолютный путь" "недопустимый путь" Bad bad
bad_app '{"sources":["Sources/Nope.swift"]}'
refused "нет файла" "нет «Sources/Nope.swift»" Bad bad
bad_app '{"frameworks":["Core Audio"]}'
refused "имя фреймворка с пробелом" "недопустимый фреймворк" Bad bad

for key in com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-dyld-environment-variables com.apple.security.get-task-allow; do
  bad_app '{"entitlements":"Sources/Apps/Bad/Bad.entitlements"}'
  entitlements "$FX/Sources/Apps/Bad/Bad.entitlements" "$key"
  refused "разрешение $key" "снимает защиту" Bad bad
done

helper() { # остаток записи помощника
  bad_app "{\"helpers\":[{\"kind\":\"swift-tool\",\"path\":\"Contents/MacOS/x\",\"identifier\":\"local.utilitumus.x\",\"sources\":[\"Sources/Shared/FanLink.swift\"]$1}]}"
}
helper ',"entitlements":"x"'
refused "неизвестный ключ помощника" "неизвестный ключ" Bad bad
helper ',"includes":["Sources"]'
refused "includes у Swift-помощника" "неизвестный ключ" Bad bad
bad_app '{"helpers":[{"kind":"shell","path":"Contents/MacOS/x","identifier":"local.utilitumus.x","sources":["Sources/Shared/FanLink.swift"]}]}'
refused "неизвестный kind" "неизвестный kind" Bad bad
bad_app '{"helpers":[{"kind":"swift-tool","path":"../x","identifier":"local.utilitumus.x","sources":["Sources/Shared/FanLink.swift"]}]}'
refused "путь помощника вне бандла" "недопустимый path" Bad bad
bad_app '{"helpers":[{"kind":"swift-tool","path":"Contents/MacOS/Bad","identifier":"local.utilitumus.x","sources":["Sources/Shared/FanLink.swift"]}]}'
refused "помощник на месте самой утилиты" "это сама утилита" Bad bad
bad_app '{"helpers":[{"kind":"swift-tool","path":"Contents/MacOS/x","identifier":"other.x","sources":["Sources/Shared/FanLink.swift"]}]}'
refused "чужой identifier" "недопустимый identifier" Bad bad
bad_app '{"helpers":[{"kind":"swift-tool","path":"Contents/MacOS/x","identifier":"local.utilitumus.x"}]}'
refused "помощник без исходников" "нет sources" Bad bad

# Помощник, о котором не знает установщик, ушёл бы без проверки подписанта.
helper ''
refused "помощник не описан в install.sh" "расходятся с установщиком" Bad bad
# Без помощника из таблицы сборку отвергли бы все установщики.
bad_app '{}'
refused "из манифеста убран помощник таблицы" "расходятся с установщиком" Bad fans
# Identifier другой, путь тот же.
bad_app '{"helpers":[{"kind":"swift-tool","path":"Contents/MacOS/utilitumus-fan","identifier":"local.utilitumus.fan2","sources":["Sources/Shared/FanLink.swift"]}]}'
refused "identifier не как в install.sh" "расходятся с установщиком" Bad fans

# Links без метки: установщик отверг бы такую сборку.
cp "$FX/Sources/LinkHelper/Info.plist" "$OUT/links.plist"
plutil -remove UtilitumusSecurityEpoch "$OUT/links.plist"
mkdir -p "$FX/Fixture"; cp "$OUT/links.plist" "$FX/Fixture/links.plist"
bad_app '{"helpers":[{"kind":"swift-app","path":"Contents/Helpers/Utilitumus Links.app","identifier":"local.utilitumus.links","executable":"UtilitumusLinks","info":"Fixture/links.plist","sources":["Sources/LinkHelper/main.swift"]}]}'
refused "Info.plist вложенного бандла без метки" UtilitumusSecurityEpoch Bad browser

# Тестовый id установщику не известен, поэтому сборка со швом таблицу не сверяет.
mkdir -p "$FX/Sources/Apps/Seam" "$FX/Sources/Modules/Seam"
app Seam 'print(1)'
cat > "$FX/Sources/Apps/Seam/manifest.json" <<'EOF'
{"helpers":[{"kind":"swift-tool","path":"Contents/MacOS/x","identifier":"local.utilitumus.x","sources":["Sources/Shared/FanLink.swift","Sources/Kit/KitSigning.swift","Sources/Apps/Seam/main.swift"]}]}
EOF
if "$BA" test.seam Seam 1.2.3 "$OUT/seam" --test-seam > "$OUT/seam.log" 2>&1; then
  ok "сборка с тестовым швом не сверяет таблицу помощников"
else
  cat "$OUT/seam.log"
  bad "сборка с тестовым швом не собралась"
fi

if [ "$fails" -ne 0 ]; then
  echo "Провалов: $fails"
  exit 1
fi
rm -rf "$OUT"
echo "Манифест сборки: OK"
