#!/bin/bash
# Лаунчер как оболочка: собирается из своего списка без логики модулей, не несёт помощников утилит и не просит их разрешений.
#   Tests/run-hub-shell-check.sh [бандл]   бандл: сверить ещё и готовую сборку build.sh, кроме сборки scripts/dev.sh
# Ничего не запускает и не ставит. Кэши между запусками вне папки проверки. Папка: HUB_SHELL_CHECK_DIR, иначе $TMPDIR/hub-shell-check.
source "$(dirname "$0")/lib/check-limit.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
OUT="${HUB_SHELL_CHECK_DIR:-${TMPDIR:-/tmp}/hub-shell-check}"
. Tests/lib/incremental.sh
rm -rf "$OUT"
mkdir -p "$OUT"

FAILED=0
ok() { echo "ok: $1"; }
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

echo "== Список лаунчера"
HUB_LIST="$(scripts/hub-sources.sh)"
HUB_FILES=()
while IFS= read -r f; do HUB_FILES+=("$f"); done <<<"$HUB_LIST"
EXTRA="$(/usr/bin/grep -vE '^Sources/(App|Kit)/|^Sources/Modules/[^/]+/UI/|^Sources/Shared/FanLink\.swift$' <<<"$HUB_LIST" || true)"
[ -z "$EXTRA" ] && ok "в списке только App, Kit, FanLink и папки UI (${#HUB_FILES[@]} файлов)" || { bad "в списке лишнее:"; echo "$EXTRA"; }
for module in Sources/Modules/*; do
  [ -d "$module/UI" ] || bad "у $module нет папки UI"
done

echo "== Имена логики"
none "в Sources/App и папках UI нет имён логики" \
  '[A-Z][a-z]+Controller|LoadStore|StashStore|BotsStore|AudioMonitor|VoiceModelStore|FanHelperInstaller' \
  Sources/App Sources/Modules/*/UI

echo "== Сборочные скрипты"
none "build.sh и dev.sh не собирают помощников утилит и не передают им разрешения" \
  'utilitumus-fan|utilitumus-voice|fetch-sherpa|--entitlements|-framework (AudioToolbox|IOKit)' build.sh scripts/dev.sh
none "в Info.plist нет описаний разрешений" 'UsageDescription' Info.plist
[ ! -e Utilitumus.entitlements ] && ok "у лаунчера нет файла entitlements" || bad "файл Utilitumus.entitlements снова на месте"
# Сверяем с настоящим бандлом, поэтому обещание build.sh должно касаться того же Info.plist.
/usr/bin/grep -q '^cp Info.plist "$APP_BUNDLE/Contents/Info.plist"$' build.sh && ok "build.sh кладёт корневой Info.plist" || bad "build.sh кладёт другой Info.plist"

echo "== Компиляция из списка"
build_hub() { # имя, флаги -D...
  local name="$1" cache
  shift
  cache="$(incremental_cache "hub-shell-$name" "$TARGET" "$@")"
  incremental_flags "$cache" "${HUB_FILES[@]}"
  if swiftc ${INC_FLAGS[@]+"${INC_FLAGS[@]}"} -parse-as-library -target "$TARGET" "$@" -module-name Utilitumus -o "$OUT/$name" \
    "${HUB_FILES[@]}" -framework SwiftUI -framework AppKit -framework CoreAudio > "$OUT/$name.log" 2>&1; then
    ok "лаунчер компилируется и связывается: ${*:-без флагов}"
  else
    bad "лаунчер не собрался: ${*:-без флагов}"
    /usr/bin/grep -E 'error:' "$OUT/$name.log" | /usr/bin/sort -u | /usr/bin/head -20 || true
  fi
}
build_hub plain
build_hub seam -D KIT_TEST_DEFAULTS

echo "== Экран каждого модуля без других модулей"
ui_alone() { # папка UI
  local name files=() f
  name="$(basename "$(dirname "$1")")"
  while IFS= read -r f; do files+=("$f"); done < <(/usr/bin/find "$1" Sources/Kit -name '*.swift' | LC_ALL=C sort)
  # Только порогам вентиляторов нужен FanLink, остальным он не положен.
  [ "$name" != Fans ] || files+=(Sources/Shared/FanLink.swift)
  swiftc -typecheck -parse-as-library -target "$TARGET" -module-name "UI$name" "${files[@]}" > "$OUT/ui-$name.log" 2>&1
}
UI_PIDS=()
UI_NAMES=()
UI_DONE=0
ui_collect() {
  local name
  while [ "$UI_DONE" -lt "${#UI_PIDS[@]}" ]; do
    name="${UI_NAMES[$UI_DONE]}"
    if wait "${UI_PIDS[$UI_DONE]}"; then ok "$name: UI с Kit"; else
      bad "$name: UI с Kit не собирается"; /usr/bin/grep -E 'error:' "$OUT/ui-$name.log" | /usr/bin/sort -u | /usr/bin/head -8 || true
    fi
    UI_DONE=$(( UI_DONE + 1 ))
  done
}
for dir in Sources/Modules/*/UI; do
  ui_alone "$dir" &
  UI_PIDS+=("$!")
  UI_NAMES+=("$(basename "$(dirname "$dir")")")
  # Не больше четырёх разом: bash 3.2 не умеет wait -n, поэтому пачками.
  [ $(( ${#UI_PIDS[@]} % 4 )) != 0 ] || ui_collect
done
ui_collect

check_bundle() { # бандл
  local app="$1" helper right lib symbol entitlements plist bin symbols libs
  if ! codesign --verify --deep --strict "$app" 2>/dev/null; then bad "$app: подпись не сходится"; return; fi
  ok "$app: подпись цела"
  for helper in utilitumus-fan utilitumus-voice; do
    [ ! -e "$app/Contents/MacOS/$helper" ] && [ ! -L "$app/Contents/MacOS/$helper" ] && ok "нет $helper" || bad "в бандле есть $helper"
  done
  # Решение автора: помощник ссылок остаётся, он браузер по умолчанию.
  [ -d "$app/Contents/Helpers/Utilitumus Links.app" ] && ok "помощник ссылок на месте" || bad "нет помощника ссылок"

  # --verify выше уже доказал, что подпись читается: пустой вывод здесь значит «нет прав», а не «не смогли прочитать».
  entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null)"
  for right in com.apple.security.device.audio-input com.apple.security.automation.apple-events; do
    [[ "$entitlements" != *"$right"* ]] && ok "в подписи нет $right" || bad "в подписи есть $right"
  done
  plist="$(plutil -convert xml1 -o - "$app/Contents/Info.plist")"
  [[ "$plist" != *UsageDescription* ]] && ok "в Info.plist бандла нет описаний разрешений" || bad "в Info.plist бандла есть описания разрешений"

  bin="$app/Contents/MacOS/Utilitumus"
  libs="$(otool -L "$bin")"
  for lib in AVFoundation AVFAudio AudioToolbox IOKit; do
    [[ "$libs" != *"/$lib.framework/"* ]] && ok "не связан с $lib" || bad "связан с $lib"
  done
  # Запрос разрешения идёт только через такие вызовы. Без них macOS не покажет окна от имени лаунчера, что бы ни писал код выше.
  symbols="$(nm -u "$bin")"
  for symbol in _AXIsProcessTrustedWithOptions _CGRequestListenEventAccess _CGRequestPostEventAccess _CGRequestScreenCaptureAccess \
    _CGPreflightListenEventAccess _IOHIDRequestAccess _CGEventTapCreate _AudioHardwareCreateProcessTap _AudioDeviceCreateIOProcID \
    '_OBJC_CLASS_$_AVCaptureDevice' '_OBJC_CLASS_$_AVAudioEngine' '_OBJC_CLASS_$_NSAppleScript'; do
    if /usr/bin/grep -qxF "$symbol" <<<"$symbols"; then bad "лаунчер зовёт $symbol"; else ok "не зовёт $symbol"; fi
  done
}

echo "== Бандл scripts/dev.sh"
# Папка из кэша, а не из OUT: иначе dev.sh каждый раз компилировал бы центр с нуля.
DEV="$(incremental_cache hub-shell-dev "$TARGET")"
if UTILITUMUS_DEV_DIR="$DEV" scripts/dev.sh --hub > "$OUT/dev.log" 2>&1; then
  check_bundle "$DEV/hub/Utilitumus.app"
else
  bad "scripts/dev.sh --hub упал"; /usr/bin/tail -20 "$OUT/dev.log"
fi

if [ $# -gt 0 ]; then
  echo "== Готовый бандл: $1"
  check_bundle "$1"
fi

if [ "$FAILED" != 0 ]; then echo "ПРОВАЛ: есть замечания выше"; exit 1; fi
echo "ГОТОВО: лаунчер собирается оболочкой"
